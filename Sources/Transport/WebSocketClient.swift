//
//  WebSocketClient.swift
//
//  RFC 6455 client over NWConnection.
//
//  Why hand-rolled:
//
//    * URLSessionWebSocketTask is iOS 13+.
//    * NWProtocolWebSocket is iOS 13+.
//    * Network.framework itself shipped in iOS 12.0, so NWConnection with
//      NWProtocolTLS is available and is the right foundation.
//
//  Writing the ~400 lines ourselves also removes every third-party dependency
//  and puts an exact frame-level byte counter on the one code path that decides
//  whether this app meets its only hard requirement.
//
//  A note on byte accounting: NWConnection hands us plaintext, so we cannot
//  observe TLS record sizes the way the Python probe does through memory BIOs.
//  ByteMeter adds a fixed per-frame estimate for TLS and TCP/IP overhead
//  instead. The probe's measured figures are what calibrate that estimate.
//
//  iOS 12: no async/await, so this is a callback API driven by a serial queue.
//

import Foundation
import Network

public final class WebSocketClient {

    // MARK: - Types

    public enum Opcode: UInt8 {
        case continuation = 0x0
        case text         = 0x1
        case binary       = 0x2
        case close        = 0x8
        case ping         = 0x9
        case pong         = 0xA
    }

    public enum WSError: Error, CustomStringConvertible {
        case badURL(String)
        case upgradeRejected(String)
        case handshakeTimeout
        case connection(Error)
        case protocolViolation(String)
        case frameTooLarge(UInt64)

        public var description: String {
            switch self {
            case .badURL(let s):            return "bad websocket url: \(s)"
            case .upgradeRejected(let s):   return "upgrade rejected: \(s)"
            case .handshakeTimeout:         return "handshake timed out"
            case .connection(let e):        return "connection failed: \(e)"
            case .protocolViolation(let s): return "protocol violation: \(s)"
            case .frameTooLarge(let n):     return "frame of \(n) bytes exceeds the limit"
            }
        }
    }

    private enum State {
        case idle
        case connecting
        case upgrading
        case open
        case closing
        case closed
    }

    /// A server frame larger than this means the stream desynchronised.
    /// Discord's largest real payload is READY, well under 16 MB inflated and
    /// far smaller compressed.
    private static let maxFrameSize: UInt64 = 16 * 1_024 * 1_024

    // MARK: - Callbacks

    /// Upgrade accepted; safe to send.
    public var onOpen: (() -> Void)?
    /// A complete data frame. Fragments are reassembled before this fires.
    public var onMessage: ((Opcode, Data) -> Void)?
    /// Closed, cleanly or not. `code` is 0 when the peer sent no close frame.
    public var onClose: ((UInt16, String) -> Void)?
    public var onError: ((WSError) -> Void)?

    // MARK: - Stored

    private let host: String
    private let port: UInt16
    private let path: String
    private let extraHeaders: [String: String]
    private let meter: ByteMeter
    private let queue: DispatchQueue

    private var connection: NWConnection?
    private var state: State = .idle
    private var inbound = Data()

    /// Reassembly of a fragmented message: opcode of the first frame, and the
    /// bytes so far.
    private var fragmentOpcode: Opcode?
    private var fragmentBuffer = Data()

    private var handshakeKey = ""
    private var handshakeTimer: DispatchSourceTimer?

    // MARK: - Init

    /// - Parameter url: a `wss://` URL. Plain `ws://` is refused: a token must
    ///   never cross the network unencrypted.
    public init(url: String,
                headers: [String: String] = [:],
                meter: ByteMeter,
                queue: DispatchQueue = DispatchQueue(label: "smolcord.ws")) throws {
        guard let parsed = URLComponents(string: url),
              let h = parsed.host,
              parsed.scheme == "wss" else {
            throw WSError.badURL(url)
        }
        self.host = h
        self.port = UInt16(parsed.port ?? 443)
        var p = parsed.path.isEmpty ? "/" : parsed.path
        if let q = parsed.query, !q.isEmpty { p += "?" + q }
        self.path = p
        self.extraHeaders = headers
        self.meter = meter
        self.queue = queue
    }

    // MARK: - Lifecycle

    public func connect() {
        queue.async { self.startConnection() }
    }

    private func startConnection() {
        guard state == .idle || state == .closed else { return }
        state = .connecting
        inbound.removeAll(keepingCapacity: true)
        fragmentOpcode = nil
        fragmentBuffer.removeAll(keepingCapacity: true)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Heartbeats already prove liveness every 41s, so TCP keepalive would
        // only add packets. Leave it off.
        tcp.enableKeepalive = false

        let tls = NWProtocolTLS.Options()
        let params = NWParameters(tls: tls, tcp: tcp)

        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 443,
            using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            switch newState {
            case .ready:
                self.sendUpgradeRequest()
            case .failed(let error):
                self.fail(.connection(error))
            case .cancelled:
                self.finishClose(code: 0, reason: "cancelled")
            case .waiting(let error):
                // No route, or the radio is down. Surface it rather than hang.
                self.fail(.connection(error))
            default:
                break
            }
        }
        conn.start(queue: queue)
        armHandshakeTimeout()
    }

    private func armHandshakeTimeout() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.state == .connecting || self.state == .upgrading {
                self.fail(.handshakeTimeout)
            }
        }
        timer.resume()
        handshakeTimer = timer
    }

    public func close(code: UInt16 = 1001) {
        queue.async {
            guard self.state == .open else {
                self.connection?.cancel()
                return
            }
            self.state = .closing
            var payload = Data()
            payload.append(UInt8(code >> 8))
            payload.append(UInt8(code & 0xFF))
            self.sendFrame(opcode: .close, payload: payload)
            // Give the peer a moment to echo the close, then drop the socket.
            self.queue.asyncAfter(deadline: .now() + 1.0) {
                self.connection?.cancel()
            }
        }
    }

    private func fail(_ error: WSError) {
        guard state != .closed else { return }
        state = .closed
        handshakeTimer?.cancel(); handshakeTimer = nil
        connection?.cancel()
        onError?(error)
    }

    private func finishClose(code: UInt16, reason: String) {
        guard state != .closed else { return }
        state = .closed
        handshakeTimer?.cancel(); handshakeTimer = nil
        onClose?(code, reason)
    }

    // MARK: - HTTP upgrade

    private func sendUpgradeRequest() {
        guard state == .connecting else { return }
        state = .upgrading

        var keyBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { keyBytes[i] = UInt8.random(in: 0...255) }
        handshakeKey = Data(keyBytes).base64EncodedString()

        let hostHeader = port == 443 ? host : "\(host):\(port)"
        var lines = [
            "GET \(path) HTTP/1.1",
            "Host: \(hostHeader)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(handshakeKey)",
            "Sec-WebSocket-Version: 13",
        ]
        for (k, v) in extraHeaders { lines.append("\(k): \(v)") }
        let request = lines.joined(separator: "\r\n") + "\r\n\r\n"
        let data = Data(request.utf8)

        meter.recordConnect(bytes: data.count)
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if let error = error { self.fail(.connection(error)); return }
            self.receiveLoop()
        })
    }

    /// Consume the HTTP response head. Returns true once the upgrade is done.
    private func tryCompleteUpgrade() -> Bool {
        guard let range = inbound.range(of: Data("\r\n\r\n".utf8)) else {
            // Guard against a peer that never terminates the head.
            if inbound.count > 16 * 1_024 {
                fail(.upgradeRejected("response head exceeded 16KB"))
            }
            return false
        }
        let headData = inbound.subdata(in: inbound.startIndex..<range.lowerBound)
        inbound.removeSubrange(inbound.startIndex..<range.upperBound)

        let head = String(data: headData, encoding: .utf8) ?? ""
        meter.recordConnect(bytes: headData.count + 4)

        let statusLine = head.components(separatedBy: "\r\n").first ?? ""
        guard statusLine.contains("101") else {
            fail(.upgradeRejected(statusLine))
            return false
        }

        state = .open
        handshakeTimer?.cancel(); handshakeTimer = nil
        onOpen?()
        return true
    }

    // MARK: - Receive

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.fail(.connection(error))
                return
            }
            if let data = data, !data.isEmpty {
                self.inbound.append(data)
                self.drainInbound()
            }
            if isComplete {
                self.finishClose(code: 0, reason: "peer closed the stream")
                return
            }
            if self.state == .open || self.state == .upgrading || self.state == .closing {
                self.receiveLoop()
            }
        }
    }

    private func drainInbound() {
        if state == .upgrading {
            guard tryCompleteUpgrade() else { return }
        }
        // A single read can hold several frames. Parse until starved.
        while state == .open || state == .closing {
            switch parseFrame() {
            case .needMore:
                return
            case .failed(let err):
                fail(err)
                return
            case .frame(let fin, let opcode, let payload, let wireLength):
                handle(fin: fin, opcode: opcode, payload: payload, wireLength: wireLength)
            }
        }
    }

    private enum ParseResult {
        case needMore
        case failed(WSError)
        case frame(fin: Bool, opcode: Opcode, payload: Data, wireLength: Int)
    }

    /// Parse one frame off the front of `inbound`, consuming it on success.
    private func parseFrame() -> ParseResult {
        let base = inbound.startIndex
        let available = inbound.count
        guard available >= 2 else { return .needMore }

        let b0 = inbound[base]
        let b1 = inbound[base + 1]
        let fin = (b0 & 0x80) != 0
        let rawOpcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        var length = UInt64(b1 & 0x7F)
        var offset = 2

        if length == 126 {
            guard available >= 4 else { return .needMore }
            length = UInt64(inbound[base + 2]) << 8 | UInt64(inbound[base + 3])
            offset = 4
        } else if length == 127 {
            guard available >= 10 else { return .needMore }
            length = 0
            for i in 0..<8 {
                length = (length << 8) | UInt64(inbound[base + 2 + i])
            }
            offset = 10
        }

        guard length <= WebSocketClient.maxFrameSize else {
            return .failed(.frameTooLarge(length))
        }
        // A server must never mask. Handling it anyway keeps a buggy proxy from
        // silently corrupting the stream.
        var maskKey = [UInt8]()
        if masked {
            guard available >= offset + 4 else { return .needMore }
            maskKey = [inbound[base + offset], inbound[base + offset + 1],
                       inbound[base + offset + 2], inbound[base + offset + 3]]
            offset += 4
        }

        let total = offset + Int(length)
        guard available >= total else { return .needMore }

        guard let opcode = Opcode(rawValue: rawOpcode) else {
            return .failed(.protocolViolation("unknown opcode 0x\(String(rawOpcode, radix: 16))"))
        }

        var payload = inbound.subdata(in: (base + offset)..<(base + total))
        if masked && !maskKey.isEmpty {
            for i in 0..<payload.count {
                payload[payload.startIndex + i] ^= maskKey[i & 3]
            }
        }
        inbound.removeSubrange(base..<(base + total))

        return .frame(fin: fin, opcode: opcode, payload: payload, wireLength: total)
    }

    private func handle(fin: Bool, opcode: Opcode, payload: Data, wireLength: Int) {
        switch opcode {
        case .ping:
            meter.recordInbound(frameBytes: wireLength, inflated: 0)
            sendFrame(opcode: .pong, payload: payload)

        case .pong:
            meter.recordInbound(frameBytes: wireLength, inflated: 0)

        case .close:
            meter.recordInbound(frameBytes: wireLength, inflated: 0)
            var code: UInt16 = 0
            var reason = ""
            if payload.count >= 2 {
                let i = payload.startIndex
                code = UInt16(payload[i]) << 8 | UInt16(payload[i + 1])
                if payload.count > 2 {
                    reason = String(data: payload.subdata(in: (i + 2)..<payload.endIndex),
                                    encoding: .utf8) ?? ""
                }
            }
            if state == .open {
                state = .closing
                sendFrame(opcode: .close, payload: payload)
            }
            connection?.cancel()
            finishClose(code: code, reason: reason)

        case .text, .binary:
            if fin {
                // Common case: a whole message in one frame. No copy.
                deliver(opcode: opcode, payload: payload, wireLength: wireLength)
            } else {
                fragmentOpcode = opcode
                fragmentBuffer = payload
                meter.recordInbound(frameBytes: wireLength, inflated: 0)
            }

        case .continuation:
            guard let started = fragmentOpcode else {
                fail(.protocolViolation("continuation frame with no start frame"))
                return
            }
            fragmentBuffer.append(payload)
            if fin {
                let assembled = fragmentBuffer
                fragmentOpcode = nil
                fragmentBuffer = Data()
                deliver(opcode: started, payload: assembled, wireLength: wireLength)
            } else {
                meter.recordInbound(frameBytes: wireLength, inflated: 0)
            }
        }
    }

    private func deliver(opcode: Opcode, payload: Data, wireLength: Int) {
        // Inflated size is unknown here; the Gateway layer reports it after
        // decompression. Frame bytes are what the carrier billed.
        meter.recordInbound(frameBytes: wireLength, inflated: 0)
        onMessage?(opcode, payload)
    }

    // MARK: - Send

    public func send(text: String) {
        queue.async { self.sendFrame(opcode: .text, payload: Data(text.utf8)) }
    }

    public func send(binary: Data) {
        queue.async { self.sendFrame(opcode: .binary, payload: binary) }
    }

    /// Build and write one masked client frame. Must run on `queue`.
    @discardableResult
    private func sendFrame(opcode: Opcode, payload: Data) -> Int {
        guard state == .open || state == .closing else { return 0 }

        var frame = Data()
        frame.append(0x80 | opcode.rawValue)

        let n = payload.count
        if n < 126 {
            frame.append(0x80 | UInt8(n))
        } else if n < 65_536 {
            frame.append(0x80 | 126)
            frame.append(UInt8((n >> 8) & 0xFF))
            frame.append(UInt8(n & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xFF))
            }
        }

        // RFC 6455 requires a client to mask every frame with a fresh random
        // key. A predictable key is a protocol violation, not a style choice.
        var mask = [UInt8](repeating: 0, count: 4)
        for i in 0..<4 { mask[i] = UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)

        var masked = payload
        for i in 0..<masked.count {
            masked[masked.startIndex + i] ^= mask[i & 3]
        }
        frame.append(masked)

        meter.recordOutbound(frameBytes: frame.count)
        connection?.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error = error { self?.fail(.connection(error)) }
        })
        return frame.count
    }

    public var isOpen: Bool {
        var result = false
        queue.sync { result = (self.state == .open) }
        return result
    }
}
