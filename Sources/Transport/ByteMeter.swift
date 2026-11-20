//
//  ByteMeter.swift
//
//  Counts every byte the app puts on, or takes off, the network.
//
//  This is not instrumentation bolted on for debugging. Staying under 1 MB/hr
//  is the only hard requirement smolcord has, so the number is a first-class
//  part of the product and it is shown in the status line at all times.
//
//  Two things are counted separately:
//
//    * wire bytes     -- what the carrier bills. Frame bytes plus an estimate
//                        of TLS record and TCP/IP header overhead.
//    * inflated bytes -- what the JSON parser sees. Useful only as a ratio.
//
//  iOS 12: no Combine, so observers are plain closures.
//

import Foundation

public final class ByteMeter {

    /// A one-minute bucket. Sixty of them give a rolling hour without storing
    /// every event.
    private struct Bucket {
        var minute: Int
        var bytes: Int
    }

    // TLS 1.3 AEAD record overhead: 5-byte header, 16-byte tag, 1-byte inner
    // content type. Each WebSocket frame normally lands in its own record.
    private static let tlsRecordOverhead = 22

    // IPv4 + TCP headers, for the segment and for the ACK it provokes.
    private static let tcpIpOverhead = 52 * 2

    private let lock = NSLock()
    private var buckets: [Bucket] = []

    private(set) public var framesIn = 0
    private(set) public var framesOut = 0
    private(set) public var rawBytesIn = 0
    private(set) public var rawBytesOut = 0
    private(set) public var inflatedBytes = 0

    /// Bytes attributed to connecting: TLS handshake, HTTP upgrade, READY and
    /// READY_SUPPLEMENTAL. Paid once per connection, so it is excluded from the
    /// hourly rate and reported separately.
    private(set) public var connectBytes = 0

    /// Connections that paid for a full READY.
    private(set) public var coldStarts = 0

    /// Connections that resumed instead, skipping READY.
    private(set) public var resumes = 0

    /// Called after every update, on an unspecified queue. The UI hops to main.
    public var onChange: (() -> Void)?

    public init() {}

    // MARK: - Recording

    public func recordConnect(bytes: Int) {
        lock.lock()
        connectBytes += bytes
        rawBytesOut += bytes
        lock.unlock()
        onChange?()
    }

    public func recordInbound(frameBytes: Int, inflated: Int) {
        lock.lock()
        framesIn += 1
        rawBytesIn += frameBytes
        inflatedBytes += inflated
        addToBucket(frameBytes + ByteMeter.tlsRecordOverhead + ByteMeter.tcpIpOverhead)
        lock.unlock()
        onChange?()
    }

    public func recordOutbound(frameBytes: Int) {
        lock.lock()
        framesOut += 1
        rawBytesOut += frameBytes
        addToBucket(frameBytes + ByteMeter.tlsRecordOverhead + ByteMeter.tcpIpOverhead)
        lock.unlock()
        onChange?()
    }

    /// Move bytes already counted in the hourly buckets into connect cost.
    ///
    /// The transport counts every frame as it arrives, because it cannot know
    /// what a frame contains until the gateway layer has inflated and parsed
    /// it. READY is the problem case: measured at 119KB on the wire, it all
    /// lands in one minute's bucket, and `projectedPerHour` multiplies that
    /// minute by 60. The status line then reads about 7MB/hr and shows red for
    /// the next eight minutes after every launch.
    ///
    /// So the Gateway calls this once it knows a payload was a one-time cost.
    /// `isColdStart` distinguishes a full READY from a resume, because the
    /// measurements say the number of cold starts is what decides the budget.
    /// A note on precision: `recordInbound` adds an overhead estimate per
    /// WebSocket frame, and a 119KB READY arrives as several frames. This
    /// removes the payload plus one frame's overhead, so a multi-frame payload
    /// leaves a residue of roughly 126 bytes per extra frame. That is about
    /// 1KB against a 1MB budget. Tracking it exactly would mean threading a
    /// frame count from the transport through the inflater to here, which is
    /// more coupling than the accuracy is worth.
    public func reclassifyAsConnect(bytes: Int, isColdStart: Bool) {
        lock.lock()
        let billed = bytes + ByteMeter.tlsRecordOverhead + ByteMeter.tcpIpOverhead
        connectBytes += bytes
        removeFromBuckets(billed)
        if isColdStart { coldStarts += 1 }
        lock.unlock()
        onChange?()
    }

    /// Record a resume. Cheap by definition: no READY is sent.
    public func recordResume() {
        lock.lock()
        resumes += 1
        lock.unlock()
        onChange?()
    }

    /// Caller must hold the lock. Walks back from the newest bucket, since the
    /// bytes being reclassified were counted moments ago.
    private func removeFromBuckets(_ bytes: Int) {
        var remaining = bytes
        var index = buckets.count - 1
        while remaining > 0 && index >= 0 {
            let available = buckets[index].bytes
            let take = min(available, remaining)
            buckets[index].bytes = available - take
            remaining -= take
            index -= 1
        }
    }

    /// Caller must hold the lock.
    private func addToBucket(_ bytes: Int) {
        let minute = Int(Date().timeIntervalSince1970) / 60
        if let last = buckets.last, last.minute == minute {
            buckets[buckets.count - 1].bytes += bytes
        } else {
            buckets.append(Bucket(minute: minute, bytes: bytes))
        }
        // Keep one hour plus a little slack.
        if buckets.count > 64 {
            buckets.removeFirst(buckets.count - 64)
        }
    }

    // MARK: - Reading

    /// Billable bytes over the trailing hour, excluding connect cost.
    public var bytesLastHour: Int {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = Int(Date().timeIntervalSince1970) / 60 - 60
        return buckets.reduce(0) { $0 + ($1.minute > cutoff ? $1.bytes : 0) }
    }

    /// Projected hourly rate. Over a short window the trailing hour reads low,
    /// so scale up by the elapsed fraction and report the honest projection.
    public var projectedPerHour: Int {
        lock.lock()
        let cutoff = Int(Date().timeIntervalSince1970) / 60 - 60
        let live = buckets.filter { $0.minute > cutoff }
        let total = live.reduce(0) { $0 + $1.bytes }
        let minutes = live.isEmpty ? 0 : max(1, (live.last!.minute - live.first!.minute) + 1)
        lock.unlock()
        guard minutes > 0 else { return 0 }
        if minutes >= 60 { return total }
        return Int(Double(total) * 60.0 / Double(minutes))
    }

    public var isOverBudget: Bool {
        return projectedPerHour > 1_024 * 1_024
    }

    public func reset() {
        lock.lock()
        buckets.removeAll()
        framesIn = 0; framesOut = 0
        rawBytesIn = 0; rawBytesOut = 0
        inflatedBytes = 0; connectBytes = 0
        coldStarts = 0; resumes = 0
        lock.unlock()
        onChange?()
    }

    // MARK: - Formatting

    /// Terminal-friendly short form: 1.4K, 812B, 2.1M.
    public static func short(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b < 1_024 { return "\(bytes)B" }
        if b < 1_024 * 1_024 { return String(format: "%.1fK", b / 1_024) }
        return String(format: "%.1fM", b / (1_024 * 1_024))
    }
}
