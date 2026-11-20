//
//  DMStore.swift
//
//  The single source of truth for the UI.
//
//  The UI never talks to Gateway, REST or Persistence. It talks here. That
//  boundary is deliberate: it is the entire migration path if the direct
//  connection ever has to move behind a relay. Swap what feeds DMStore and
//  nothing above it changes.
//
//  iOS 12: no Combine. Observers are closures, fired on the main queue.
//

import Foundation

public final class DMStore {

    // MARK: - View models

    public struct Conversation {
        public let id: String
        /// What the terminal shows: a display name, or a comma list for a group.
        public let title: String
        public let isGroup: Bool
        public var unreadCount: Int
        public var lastMessagePreview: String
        public var lastMessageID: String?
        public var typingUserNames: [String]
        public var isOnline: Bool
    }

    public struct Line {
        public let messageID: String
        public let authorName: String
        public let content: String
        /// e.g. ["[png 240K]"]
        public let attachmentMarkers: [String]
        public let attachmentURLs: [String]
        public let embedCount: Int
        public let isFromSelf: Bool
        public let isPending: Bool
        public let timeText: String
    }

    // MARK: - Observers

    /// Observers are single closures, not lists, because there are at most two
    /// screens and both are on one navigation stack. The rule is that whichever
    /// screen is visible owns them, and sets them in viewWillAppear rather than
    /// viewDidLoad. A screen that only clears them on the way out leaves the
    /// other screen's status line frozen.
    public var onConversationsChanged: (() -> Void)?
    public var onMessages: ((String) -> Void)?
    public var onStatusChanged: ((Gateway.Status) -> Void)?

    /// A failed send, scoped to the channel it was typed in. Separate from
    /// `onFatal` so it can be shown inline, in the conversation the user is
    /// looking at, instead of in an alert presented from an off-screen view.
    public var onSendFailed: ((String, String) -> Void)?

    /// The connection is unrecoverable: a dead token, a fatal close code.
    public var onFatal: ((String) -> Void)?

    /// The last known status.
    ///
    /// Gateway only fires on a *change*, so a screen created while already
    /// connected would otherwise show `off` until the next transition. Every
    /// new StatusLine seeds itself from this.
    public private(set) var status: Gateway.Status = .offline

    // MARK: - Dependencies

    private let persistence: Persistence
    private let meter: ByteMeter
    private var gateway: Gateway?
    private var rest: REST?
    private var token: String?

    // MARK: - State

    private var channels: [String: Persistence.StoredChannel] = [:]
    private var users: [String: Persistence.StoredUser] = [:]
    private var messages: [String: [Persistence.StoredMessage]] = [:]
    private var readStates: [String: String] = [:]
    private var selfUserID: String?
    private var presence: [String: String] = [:]
    /// channel id -> (user id -> expiry). Discord typing lasts 10 seconds.
    private var typing: [String: [String: Date]] = [:]
    private var pendingSends: [String: [Persistence.StoredMessage]] = [:]
    /// Channels whose history we already fetched this session.
    private var historyFetched = Set<String>()

    /// Messages kept per channel in memory. Disk keeps fewer.
    private static let messagesInMemory = 200

    public init(persistence: Persistence, meter: ByteMeter) {
        self.persistence = persistence
        self.meter = meter
        restoreFromDisk()
    }

    private func restoreFromDisk() {
        let snap = persistence.snapshot
        for c in snap.channels { channels[c.id] = c }
        users = snap.users
        messages = snap.messages
        readStates = snap.readStates
        selfUserID = snap.selfUserID
    }

    // MARK: - Session

    public var isSignedIn: Bool { return Keychain.loadToken() != nil }

    public func signIn(token: String) {
        try? Keychain.saveToken(token)
        self.token = token
        connect()
    }

    public func signOut() {
        gateway?.stop()
        gateway = nil
        rest = nil
        token = nil
        Keychain.deleteToken()
        persistence.wipe()
        channels.removeAll(); users.removeAll(); messages.removeAll()
        readStates.removeAll(); presence.removeAll(); typing.removeAll()
        historyFetched.removeAll()
        status = .offline
        meter.reset()
        emitConversations()
    }

    public func connect() {
        guard let token = token ?? Keychain.loadToken() else { return }
        self.token = token
        if rest == nil { rest = REST(token: token, meter: meter) }

        // Reuse the existing gateway after a pause. It still holds the live
        // session id and sequence, so start() takes the RESUME path instead of
        // paying for READY again.
        if let existing = gateway {
            existing.start()
            return
        }

        let snap = persistence.snapshot
        let cache = Gateway.SessionCache(
            sessionID: snap.sessionID,
            sequence: snap.sequence,
            resumeGatewayURL: snap.resumeGatewayURL,
            guildVersions: snap.guildVersions,
            knownGuildIDs: snap.knownGuildIDs)

        let gw = Gateway(token: token, meter: meter, cache: cache)
        gw.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.status = status
                self.onStatusChanged?(status)
                if case .fatal(let message) = status {
                    self.onFatal?(message)
                }
            }
        }
        gw.onSessionCache = { [weak self] cache in
            // This fires on the gateway queue, but persistToDisk runs on main.
            // Persistence.snapshot and its coalescing work item are plain
            // stored properties, so mutating them from both is a data race.
            // Everything that touches Persistence goes through main.
            DispatchQueue.main.async {
                self?.persistence.update { snap in
                    snap.sessionID = cache.sessionID
                    snap.sequence = cache.sequence
                    snap.resumeGatewayURL = cache.resumeGatewayURL
                    snap.guildVersions = cache.guildVersions
                    snap.knownGuildIDs = cache.knownGuildIDs
                }
            }
        }
        gw.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.apply(event) }
        }
        gateway = gw
        gw.start()
    }

    /// Backgrounding. Keeps the session so returning can RESUME.
    public func pause() {
        gateway?.pause()
        persistence.flush()
    }

    /// Signing out, or tearing down for good.
    public func disconnect() {
        gateway?.stop()
        gateway = nil
        persistence.flush()
    }

    // MARK: - Event application

    /// Internal rather than private so the tests can drive the store with
    /// synthetic events and no network.
    func apply(_ event: GatewayEvent) {
        switch event {
        case .ready(let ready):
            selfUserID = ready.selfUser.id
            for (id, u) in ready.users {
                users[id] = Persistence.StoredUser(
                    id: u.id, username: u.username, displayName: u.displayName)
            }
            users[ready.selfUser.id] = Persistence.StoredUser(
                id: ready.selfUser.id,
                username: ready.selfUser.username,
                displayName: ready.selfUser.displayName)
            for c in ready.dmChannels {
                channels[c.id] = Persistence.StoredChannel(
                    id: c.id, type: c.type, recipientIDs: c.recipientIDs,
                    name: c.name, lastMessageID: c.lastMessageID)
            }
            readStates = ready.readStates
            persistToDisk()
            emitConversations()

            // READY carries private_channels on most accounts. Only fall back
            // to REST when it did not, because that request costs a handshake.
            if ready.dmChannels.isEmpty {
                refreshChannelsFromREST()
            }

        case .messageCreate(let m):
            guard channels[m.channelID] != nil else { return }
            let stored = store(m)
            // Replace our own optimistic row rather than duplicating it.
            if m.authorID == selfUserID {
                dropPending(channelID: m.channelID, content: m.content)
            }
            append(stored, to: m.channelID)
            typing[m.channelID]?.removeValue(forKey: m.authorID)
            channels[m.channelID]?.lastMessageID = m.id
            persistToDisk()
            onMessages?(m.channelID)
            emitConversations()

        case .messageUpdate(let m):
            guard var list = messages[m.channelID] else { return }
            if let i = list.firstIndex(where: { $0.id == m.id }) {
                list[i] = store(m)
                messages[m.channelID] = list
                persistToDisk()
                onMessages?(m.channelID)
            }

        case .messageDelete(let channelID, let messageID):
            guard var list = messages[channelID] else { return }
            list.removeAll { $0.id == messageID }
            messages[channelID] = list
            persistToDisk()
            onMessages?(channelID)
            emitConversations()

        case .messageAck(let channelID, let messageID):
            readStates[channelID] = messageID
            persistToDisk()
            emitConversations()

        case .channelCreate(let c):
            channels[c.id] = Persistence.StoredChannel(
                id: c.id, type: c.type, recipientIDs: c.recipientIDs,
                name: c.name, lastMessageID: c.lastMessageID)
            persistToDisk()
            emitConversations()

        case .channelDelete(let id):
            channels.removeValue(forKey: id)
            messages.removeValue(forKey: id)
            persistToDisk()
            emitConversations()

        case .typingStart(let channelID, let userID, _):
            guard userID != selfUserID, channels[channelID] != nil else { return }
            var forChannel = typing[channelID] ?? [:]
            forChannel[userID] = Date().addingTimeInterval(10)
            typing[channelID] = forChannel
            emitConversations()

        case .presenceUpdate(let userID, let status):
            presence[userID] = status
            emitConversations()

        case .relationshipAdd(let u):
            users[u.id] = Persistence.StoredUser(
                id: u.id, username: u.username, displayName: u.displayName)
            persistToDisk()

        case .relationshipRemove, .readySupplemental, .ignored:
            break

        case .guildCreate:
            // Handled entirely in Gateway, which unsubscribes from it. The
            // store has no guild surface and must never grow one.
            break
        }
    }

    private func store(_ m: GatewayEvent.Message) -> Persistence.StoredMessage {
        return Persistence.StoredMessage(
            id: m.id,
            channelID: m.channelID,
            authorID: m.authorID,
            authorName: m.authorName,
            content: m.content,
            timestamp: m.timestamp,
            attachmentMarkers: m.attachments.map { $0.marker },
            attachmentURLs: m.attachments.map { $0.url },
            embedCount: m.embedCount)
    }

    private func append(_ message: Persistence.StoredMessage, to channelID: String) {
        var list = messages[channelID] ?? []
        guard !list.contains(where: { $0.id == message.id }) else { return }
        list.append(message)
        if list.count > DMStore.messagesInMemory {
            list.removeFirst(list.count - DMStore.messagesInMemory)
        }
        messages[channelID] = list
    }

    // MARK: - Reading, for the UI

    public func conversations() -> [Conversation] {
        expireTyping()
        var result = [Conversation]()
        result.reserveCapacity(channels.count)

        for (id, channel) in channels {
            let others = channel.recipientIDs.filter { $0 != selfUserID }
            let title: String
            if let name = channel.name, !name.isEmpty {
                title = name
            } else if others.isEmpty {
                title = "(empty)"
            } else {
                title = others.map { users[$0]?.displayName ?? "user\($0.suffix(4))" }
                              .joined(separator: ", ")
            }

            let list = messages[id] ?? []
            let last = list.last
            var preview = last?.content ?? ""
            if preview.isEmpty, let markers = last?.attachmentMarkers, !markers.isEmpty {
                preview = markers.joined(separator: " ")
            }

            let typingNames = (typing[id] ?? [:]).keys
                .map { users[$0]?.displayName ?? "someone" }

            let online = others.contains { (presence[$0] ?? "offline") != "offline" }

            result.append(Conversation(
                id: id,
                title: title,
                isGroup: channel.type == 3,
                unreadCount: unreadCount(channelID: id),
                lastMessagePreview: preview,
                lastMessageID: channel.lastMessageID,
                typingUserNames: typingNames,
                isOnline: online))
        }

        // Most recent first. Snowflake ids sort chronologically as integers,
        // and lexicographically only when the same length, so compare numbers.
        result.sort { a, b in
            let x = UInt64(a.lastMessageID ?? "0") ?? 0
            let y = UInt64(b.lastMessageID ?? "0") ?? 0
            return x > y
        }
        return result
    }

    private func unreadCount(channelID: String) -> Int {
        guard let last = channels[channelID]?.lastMessageID,
              let lastValue = UInt64(last) else { return 0 }
        guard let readID = readStates[channelID], let readValue = UInt64(readID) else {
            return messages[channelID]?.isEmpty == false ? 1 : 0
        }
        guard lastValue > readValue else { return 0 }
        // Exact count when the cache covers it; otherwise it is at least one.
        if let list = messages[channelID] {
            let n = list.filter { (UInt64($0.id) ?? 0) > readValue && $0.authorID != selfUserID }.count
            if n > 0 { return n }
        }
        return 1
    }

    public func lines(channelID: String) -> [Line] {
        let stored = messages[channelID] ?? []
        let pending = pendingSends[channelID] ?? []
        var out = [Line]()
        out.reserveCapacity(stored.count + pending.count)

        for m in stored {
            out.append(line(from: m, isPending: false))
        }
        for m in pending {
            out.append(line(from: m, isPending: true))
        }
        return out
    }

    private func line(from m: Persistence.StoredMessage, isPending: Bool) -> Line {
        return Line(
            messageID: m.id,
            authorName: m.authorName,
            content: m.content,
            attachmentMarkers: m.attachmentMarkers,
            attachmentURLs: m.attachmentURLs,
            embedCount: m.embedCount,
            isFromSelf: m.authorID == selfUserID,
            isPending: isPending,
            timeText: DMStore.shortTime(from: m.timestamp))
    }

    /// ISO 8601 to "14:32". Delegates to `shortClockTime`, which lives in
    /// Sources/Support so it can be tested without UIKit.
    static func shortTime(from iso: String) -> String {
        return shortClockTime(fromISO8601: iso)
    }

    public func typingNames(channelID: String) -> [String] {
        expireTyping()
        return (typing[channelID] ?? [:]).keys
            .map { users[$0]?.displayName ?? "someone" }
    }

    private func expireTyping() {
        let now = Date()
        for (channel, entries) in typing {
            let live = entries.filter { $0.value > now }
            if live.count != entries.count {
                typing[channel] = live.isEmpty ? nil : live
            }
        }
    }

    // MARK: - Actions

    /// Open a conversation. Fetches history only when the cache cannot serve it.
    public func openConversation(channelID: String) {
        let cached = messages[channelID]?.count ?? 0
        if cached < 10 && !historyFetched.contains(channelID) {
            historyFetched.insert(channelID)
            rest?.fetchMessages(channelID: channelID, limit: 25) { [weak self] result in
                guard case .success(let raw) = result else { return }
                DispatchQueue.main.async {
                    self?.ingestHistory(raw, channelID: channelID)
                }
            }
        }
        markRead(channelID: channelID)
    }

    private func ingestHistory(_ raw: [[String: Any]], channelID: String) {
        // REST returns newest first; the UI reads oldest first.
        for dict in raw.reversed() {
            guard let event = GatewayEvent.decode(name: "MESSAGE_CREATE", d: dict),
                  case .messageCreate(let m) = event else { continue }
            append(store(m), to: channelID)
        }
        messages[channelID]?.sort { (UInt64($0.id) ?? 0) < (UInt64($1.id) ?? 0) }
        persistToDisk()
        onMessages?(channelID)
    }

    /// Send. The row appears at once and is reconciled when the echo arrives.
    public func send(channelID: String, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let rest = rest else { return }

        let optimistic = Persistence.StoredMessage(
            id: "pending-\(UUID().uuidString)",
            channelID: channelID,
            authorID: selfUserID ?? "self",
            authorName: users[selfUserID ?? ""]?.displayName ?? "you",
            content: trimmed,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            attachmentMarkers: [], attachmentURLs: [], embedCount: 0)
        var list = pendingSends[channelID] ?? []
        list.append(optimistic)
        pendingSends[channelID] = list
        onMessages?(channelID)

        rest.sendMessage(channelID: channelID, content: trimmed) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if case .failure(let error) = result {
                    // Drop the optimistic row and report inline, in the
                    // conversation the user is looking at. Routing this through
                    // onFatal tried to present an alert from a view that may be
                    // off screen, and offered "sign out" for a failed message.
                    self.pendingSends[channelID]?.removeAll { $0.id == optimistic.id }
                    if self.pendingSends[channelID]?.isEmpty == true {
                        self.pendingSends[channelID] = nil
                    }
                    self.onMessages?(channelID)
                    self.onSendFailed?(channelID, error.description)
                }
                // On success the gateway echo removes the pending row.
            }
        }
    }

    private func dropPending(channelID: String, content: String) {
        guard var list = pendingSends[channelID] else { return }
        if let i = list.firstIndex(where: { $0.content == content }) {
            list.remove(at: i)
            pendingSends[channelID] = list.isEmpty ? nil : list
        }
    }

    public func markRead(channelID: String) {
        guard let lastID = messages[channelID]?.last?.id,
              !lastID.hasPrefix("pending-") else { return }
        guard readStates[channelID] != lastID else { return }
        readStates[channelID] = lastID
        persistToDisk()
        emitConversations()
        rest?.ack(channelID: channelID, messageID: lastID)
    }

    private func refreshChannelsFromREST() {
        rest?.fetchDMChannels { [weak self] result in
            guard case .success(let list) = result else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                for c in list {
                    self.channels[c.id] = Persistence.StoredChannel(
                        id: c.id, type: c.type, recipientIDs: c.recipientIDs,
                        name: c.name, lastMessageID: c.lastMessageID)
                }
                self.persistToDisk()
                self.emitConversations()
            }
        }
    }

    // MARK: - Plumbing

    private func emitConversations() {
        onConversationsChanged?()
    }

    private func persistToDisk() {
        persistence.update { snap in
            snap.channels = Array(self.channels.values)
            snap.users = self.users
            snap.readStates = self.readStates
            snap.selfUserID = self.selfUserID
            // Disk keeps fewer messages than memory. 50 is enough to open a
            // conversation without a history fetch.
            var trimmed = [String: [Persistence.StoredMessage]]()
            for (id, list) in self.messages {
                trimmed[id] = list.suffix(Persistence.messagesPerChannel)
            }
            snap.messages = trimmed
        }
    }

    public func flush() {
        persistence.flush()
    }
}
