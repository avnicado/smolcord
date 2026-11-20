//
//  Gateway.swift
//
//  The gateway state machine.
//
//    connect -> HELLO -> IDENTIFY -> READY -> op 37 unsubscribe -> steady state
//
//  Reconnect policy, from Discord's rules:
//
//    * Closing with 1000 or 1001 invalidates the session. We never send those
//      when we intend to come back, because RESUME is cheaper than IDENTIFY by
//      the entire size of READY.
//    * op 7 RECONNECT, an allowed close code, or no close code at all -> RESUME
//      against `resume_gateway_url`.
//    * op 9 INVALID_SESSION with d == true -> RESUME. With d == false -> wait,
//      then IDENTIFY afresh.
//    * A missing op 11 ACK before the next heartbeat means a zombied socket.
//      Close with a non-1000 code and resume.
//
//  iOS 12: no async/await, no Combine. Everything runs on one serial queue and
//  reports out through closures.
//

import Foundation

public final class Gateway {

    // MARK: - Types

    public enum Status: Equatable {
        case offline
        case connecting
        case identifying
        case resuming
        case ready
        /// Will retry after the given delay.
        case backoff(TimeInterval)
        /// Unrecoverable. The message is for the user.
        case fatal(String)

        public var terminalLabel: String {
            switch self {
            case .offline:      return "off"
            case .connecting:   return "conn"
            case .identifying:  return "auth"
            case .resuming:     return "resum"
            case .ready:        return "ok"
            case .backoff:      return "retry"
            case .fatal:        return "dead"
            }
        }
    }

    /// Persisted between launches. Lever 3 lives here.
    public struct SessionCache {
        public var sessionID: String?
        public var sequence: Int?
        public var resumeGatewayURL: String?
        public var guildVersions: [String: Int]

        /// Every guild id we have seen on this account.
        ///
        /// Deliberately separate from `guildVersions`. A guild only lands in
        /// that dictionary if its payload carried a `version` field, and guilds
        /// arriving later via GUILD_CREATE never do. Using its keys as the
        /// guild list would silently leave those guilds subscribed after a
        /// RESUME, which is exactly the expensive case this all exists to
        /// prevent.
        public var knownGuildIDs: Set<String>

        public init(sessionID: String? = nil,
                    sequence: Int? = nil,
                    resumeGatewayURL: String? = nil,
                    guildVersions: [String: Int] = [:],
                    knownGuildIDs: Set<String> = []) {
            self.sessionID = sessionID
            self.sequence = sequence
            self.resumeGatewayURL = resumeGatewayURL
            self.guildVersions = guildVersions
            self.knownGuildIDs = knownGuildIDs
        }
    }

    /// Lever 4: zlib-stream transport compression, set on the URL.
    public static let defaultURL =
        "wss://gateway.discord.gg/?v=10&encoding=json&compress=zlib-stream"

    /// Headers that make the upgrade look like the iOS client.
    private static let upgradeHeaders = [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 12_5_7 like Mac OS X) "
                    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        "Origin": "https://discord.com",
        "Accept-Language": "en-US,en;q=0.9",
    ]

    // MARK: - Callbacks

    public var onEvent: ((GatewayEvent) -> Void)?
    public var onStatus: ((Status) -> Void)?
    /// Fired whenever the session cache changes, so the caller can persist it.
    public var onSessionCache: ((SessionCache) -> Void)?

    // MARK: - Stored

    private let token: String
    private let meter: ByteMeter
    private let queue = DispatchQueue(label: "smolcord.gateway")
    private var socket: WebSocketClient?
    private var inflater: ZlibInflater?

    private var cache: SessionCache
    private var status: Status = .offline {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    private var heartbeatInterval: TimeInterval = 41.25
    private var heartbeatTimer: DispatchSourceTimer?
    private var awaitingACK = false
    private var sequence: Int?
    private var sessionID: String?
    private var resumeURL: String?

    /// Identifies the current connection attempt.
    ///
    /// `WebSocketClient.close` keeps the old client alive for about a second so
    /// the peer can echo the close frame. During that second its callbacks are
    /// still live, and without this check an old socket can:
    ///
    ///   * feed frames into the *new* ZlibInflater, corrupting a shared zlib
    ///     context that the new connection depends on;
    ///   * fire onClose, so handleClose stops the *new* socket's heartbeat and
    ///     Discord drops it as a zombie 41 seconds later;
    ///   * call scheduleRetry again and open a third socket.
    ///
    /// Each spurious connection costs about 5.4KB of TLS plus a RESUME or a
    /// whole READY, so this is a data-budget bug as much as a correctness one.
    /// Every callback captures the generation it was made in and returns early
    /// once it no longer matches. All mutation happens on `queue`.
    private var generation = 0

    private var wantResume = false
    private var retryAttempt = 0
    private var retryTimer: DispatchSourceTimer?
    private var closedByUs = false

    /// Guild ids from the last READY, kept only long enough to unsubscribe.
    private var pendingUnsubscribeGuilds: [String] = []

    /// Guilds we have already unsubscribed from on this connection. Prevents
    /// re-sending op 37 for a guild that merely updated, and is cleared on
    /// reconnect because subscriptions are per session.
    private var unsubscribedGuilds = Set<String>()

    public init(token: String, meter: ByteMeter, cache: SessionCache = SessionCache()) {
        self.token = token
        self.meter = meter
        self.cache = cache
        self.sessionID = cache.sessionID
        self.sequence = cache.sequence
        self.resumeURL = cache.resumeGatewayURL
    }

    // MARK: - Lifecycle

    public func start() {
        queue.async {
            self.closedByUs = false
            // A stored session means we can try the cheap path first.
            self.wantResume = (self.sessionID != nil && self.sequence != nil)
            self.openSocket()
        }
    }

    /// Close the socket but keep the session, so the next `start()` can RESUME.
    ///
    /// Use this when backgrounding. `stop()` throws the session away, which
    /// costs the whole of READY on the way back; a RESUME costs one small
    /// message. Closing with 4000 rather than 1000 is what preserves the
    /// session: Discord invalidates it on 1000 and 1001.
    public func pause() {
        queue.async {
            self.closedByUs = true
            self.generation += 1   // retire the socket we are closing
            self.retryTimer?.cancel(); self.retryTimer = nil
            self.stopHeartbeat()
            self.socket?.close(code: GatewayCloseCode.unknownError)
            self.socket = nil
            self.cache.sequence = self.sequence
            self.cache.sessionID = self.sessionID
            self.persistCache()
            self.status = .offline
        }
    }

    /// Close and discard the session. For signing out, not for backgrounding.
    public func stop() {
        queue.async {
            self.closedByUs = true
            self.generation += 1   // retire the socket we are closing
            self.retryTimer?.cancel(); self.retryTimer = nil
            self.stopHeartbeat()
            // 1000 deliberately invalidates the session: the user is leaving,
            // and a stale session id would only waste a round trip later.
            self.socket?.close(code: 1000)
            self.socket = nil
            self.sessionID = nil
            self.sequence = nil
            self.persistCache()
            self.status = .offline
        }
    }

    private func openSocket() {
        guard !closedByUs else { return }
        // Subscriptions live on the session, not the account, so a new socket
        // starts subscribed again and must repeat op 37.
        unsubscribedGuilds.removeAll()
        status = wantResume ? .resuming : .connecting

        // RESUME must go to resume_gateway_url when we have one.
        let urlString: String
        if wantResume, let resume = resumeURL, !resume.isEmpty {
            urlString = resume.contains("?")
                ? resume
                : resume + "/?v=10&encoding=json&compress=zlib-stream"
        } else {
            urlString = Gateway.defaultURL
        }

        generation += 1
        let gen = generation

        do {
            inflater = try ZlibInflater()
            let ws = try WebSocketClient(url: urlString,
                                         headers: Gateway.upgradeHeaders,
                                         meter: meter,
                                         queue: queue)
            ws.onOpen = { [weak self] in
                guard let self = self, gen == self.generation else { return }
                self.handleOpen()
            }
            ws.onMessage = { [weak self] _, data in
                guard let self = self, gen == self.generation else { return }
                self.handleFrame(data)
            }
            ws.onClose = { [weak self] code, reason in
                guard let self = self, gen == self.generation else { return }
                self.handleClose(code, reason)
            }
            ws.onError = { [weak self] err in
                guard let self = self, gen == self.generation else { return }
                self.handleError(err)
            }
            socket = ws
            ws.connect()
        } catch {
            scheduleRetry(reason: "setup failed: \(error)")
        }
    }

    private func handleOpen() {
        // Nothing to send yet. The gateway speaks first, with HELLO.
    }

    // MARK: - Inbound

    private func handleFrame(_ data: Data) {
        guard let inflater = inflater else { return }
        do {
            guard let message = try inflater.feed(data) else {
                return  // gateway message still arriving
            }
            guard let obj = try? JSONSerialization.jsonObject(with: message.data, options: []),
                  let payload = obj as? [String: Any] else {
                return
            }
            // The transport already billed these bytes to the hourly rate,
            // because it cannot see inside a frame. If this turns out to be a
            // one-time payload, move them to connect cost before the status
            // line reads a 119KB READY as 7MB/hr.
            if let name = payload["t"] as? String,
               name == "READY" || name == "READY_SUPPLEMENTAL" || name == "GUILD_CREATE" {
                meter.reclassifyAsConnect(bytes: message.compressedLength,
                                          isColdStart: name == "READY")
            }
            dispatch(payload, inflatedBytes: message.data.count)
        } catch {
            // A corrupt stream cannot be recovered in place: the inflate
            // context is shared, so one bad message poisons the rest.
            // Drop the connection and resume.
            reconnect(resume: true, reason: "inflate failed: \(error)")
        }
    }

    private func dispatch(_ payload: [String: Any], inflatedBytes: Int) {
        if let s = payload["s"] as? Int {
            sequence = s
        }
        guard let rawOp = payload["op"] as? Int,
              let op = GatewayOpcode(rawValue: rawOp) else {
            return
        }

        switch op {
        case .hello:
            guard let d = payload["d"] as? [String: Any],
                  let ms = d["heartbeat_interval"] as? Int else { return }
            heartbeatInterval = Double(ms) / 1000.0
            startHeartbeat()
            if wantResume, let sid = sessionID, let seq = sequence {
                status = .resuming
                send(Identify.resumePayload(token: token, sessionID: sid, sequence: seq))
            } else {
                status = .identifying
                send(Identify.payload(token: token, guildVersions: cache.guildVersions))
            }

        case .heartbeatACK:
            awaitingACK = false

        case .heartbeat:
            // The gateway asked. Answer at once.
            send(["op": GatewayOpcode.heartbeat.rawValue,
                  "d": sequence as Any])

        case .reconnect:
            reconnect(resume: true, reason: "gateway asked us to reconnect")

        case .invalidSession:
            let resumable = (payload["d"] as? Bool) ?? false
            if resumable {
                reconnect(resume: true, reason: "invalid session, resumable")
            } else {
                sessionID = nil
                sequence = nil
                // Discord asks for a short randomised wait before a fresh
                // IDENTIFY, to avoid a thundering herd.
                let wait = Double.random(in: 1.0...5.0)
                reconnect(resume: false, reason: "invalid session", after: wait)
            }

        case .dispatch:
            handleDispatch(payload, inflatedBytes: inflatedBytes)

        default:
            break
        }
    }

    private func handleDispatch(_ payload: [String: Any], inflatedBytes: Int) {
        guard let name = payload["t"] as? String else { return }

        // A successful RESUME replays missed events but never re-sends READY,
        // so the op 37 unsubscribe that normally follows READY never happens on
        // this socket. Whether subscriptions are bound to the session or to the
        // socket is not documented, and the probe's scope check does not answer
        // it either. Re-sending costs about 4KB once and is idempotent, so we
        // re-send rather than assume, using the full known-guild list.
        if name == "RESUMED" {
            retryAttempt = 0
            status = .ready
            // A resume skips READY entirely. On the measured account that is
            // 131KB saved per app open.
            meter.recordResume()
            unsubscribedGuilds.removeAll()
            pendingUnsubscribeGuilds = Array(cache.knownGuildIDs)
            unsubscribeGuildsIfNeeded()
            return
        }

        guard let event = GatewayEvent.decode(name: name, d: payload["d"]) else { return }

        switch event {
        case .ready(let ready):
            retryAttempt = 0
            sessionID = ready.sessionID
            resumeURL = ready.resumeGatewayURL
            cache.sessionID = ready.sessionID
            cache.sequence = sequence
            cache.resumeGatewayURL = ready.resumeGatewayURL
            // Lever 3: keep the versions so the next IDENTIFY can skip
            // unchanged guild data. The guild content itself is discarded.
            cache.guildVersions = ready.guildVersions
            // The full id list, including guilds that carried no version.
            cache.knownGuildIDs = Set(ready.guildIDs)
            persistCache()

            // Lever 2, immediately. Measured effect: guild presence stops,
            // guild messages do not. Worth about 75KB/hr for one 2KB message.
            unsubscribedGuilds.removeAll()
            pendingUnsubscribeGuilds = ready.guildIDs
            unsubscribeGuildsIfNeeded()

            status = .ready
            onEvent?(event)

        case .guildCreate(let guildID):
            // A guild that arrived after READY. Unsubscribe from it or it keeps
            // sending message, typing and presence events for the whole
            // session. Not forwarded to the UI: smolcord has no guild surface.
            guard !unsubscribedGuilds.contains(guildID) else { return }
            if cache.knownGuildIDs.insert(guildID).inserted {
                persistCache()
            }
            pendingUnsubscribeGuilds = [guildID]
            unsubscribeGuildsIfNeeded()

        case .readySupplemental:
            // Discarded, but READY_SUPPLEMENTAL can be the point at which the
            // session is fully established, so settle the status here too.
            if status != .ready { status = .ready }

        case .ignored:
            // Counted by ByteMeter already. No further work, by design.
            break

        default:
            onEvent?(event)
        }
    }

    private func unsubscribeGuildsIfNeeded() {
        guard !pendingUnsubscribeGuilds.isEmpty else { return }
        let ids = pendingUnsubscribeGuilds.filter { !unsubscribedGuilds.contains($0) }
        pendingUnsubscribeGuilds = []
        guard !ids.isEmpty else { return }
        for id in ids { unsubscribedGuilds.insert(id) }
        send(Identify.unsubscribeAllGuildsPayload(guildIDs: ids))
    }

    // MARK: - Outbound

    private func send(_ payload: [String: Any]) {
        guard let text = Identify.encode(payload) else { return }
        socket?.send(text: text)
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        stopHeartbeat()
        awaitingACK = false
        // Required initial jitter: interval * random(0..1). Without it, every
        // client that reconnects after an outage heartbeats in lockstep.
        let firstDelay = heartbeatInterval * Double.random(in: 0...1)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + firstDelay,
                       repeating: heartbeatInterval,
                       leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.beat() }
        timer.resume()
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func beat() {
        if awaitingACK {
            // No ACK since the last beat. The socket is a zombie: TCP thinks it
            // is fine and nothing is arriving. Close with a code that keeps the
            // session alive, then resume.
            reconnect(resume: true, reason: "heartbeat not acknowledged")
            return
        }
        awaitingACK = true
        send(["op": GatewayOpcode.heartbeat.rawValue, "d": sequence as Any])
        cache.sequence = sequence
    }

    // MARK: - Close and retry

    private func handleClose(_ code: UInt16, _ reason: String) {
        stopHeartbeat()
        guard !closedByUs else {
            status = .offline
            return
        }
        if GatewayCloseCode.fatal.contains(code) {
            status = .fatal(GatewayCloseCode.describe(code))
            return
        }
        if GatewayCloseCode.reidentify.contains(code) {
            sessionID = nil
            sequence = nil
            scheduleRetry(reason: GatewayCloseCode.describe(code), resume: false)
            return
        }
        // Anything else, including no close frame, is resumable.
        scheduleRetry(reason: GatewayCloseCode.describe(code), resume: true)
    }

    private func handleError(_ error: WebSocketClient.WSError) {
        stopHeartbeat()
        guard !closedByUs else { return }
        scheduleRetry(reason: error.description, resume: sessionID != nil)
    }

    private func reconnect(resume: Bool, reason: String, after delay: TimeInterval = 0) {
        stopHeartbeat()
        // Retire the outgoing socket before closing it, so its final callbacks
        // cannot reach the connection we are about to open.
        generation += 1
        // 4000 is deliberate: 1000/1001 would invalidate the session and force
        // a full IDENTIFY, which costs the whole of READY again.
        socket?.close(code: GatewayCloseCode.unknownError)
        socket = nil
        scheduleRetry(reason: reason, resume: resume, minimumDelay: delay)
    }

    private func scheduleRetry(reason: String,
                               resume: Bool = true,
                               minimumDelay: TimeInterval = 0) {
        guard !closedByUs else { return }
        retryTimer?.cancel()

        retryAttempt += 1
        // Exponential backoff with jitter, capped at 60s. Reconnect storms cost
        // data: each failed attempt is a TLS handshake, about 5.4 KB.
        let base = min(60.0, pow(2.0, Double(min(retryAttempt, 6))))
        let delay = max(minimumDelay, base * Double.random(in: 0.5...1.0))

        wantResume = resume && sessionID != nil && sequence != nil
        status = .backoff(delay)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.retryTimer = nil
            self?.openSocket()
        }
        timer.resume()
        retryTimer = timer
    }

    private func persistCache() {
        onSessionCache?(cache)
    }

    // MARK: - Introspection

    public var currentStatus: Status {
        var s: Status = .offline
        queue.sync { s = self.status }
        return s
    }
}
