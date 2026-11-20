//
//  Persistence.swift
//
//  One JSON file in Application Support.
//
//  What it stores, and why each item earns its bytes:
//
//    guildVersions   lever 3. Lets the next IDENTIFY skip unchanged guild data.
//    sessionID/seq   lets the next launch RESUME instead of IDENTIFY. RESUME is
//                    cheaper by the entire size of READY.
//    readStates      so unread counts render before the socket is up.
//    messages        the last 50 per channel. Opening a conversation shows
//                    content immediately, which means we skip the history
//                    fetch unless the user scrolls back.
//
//  Core Data would be the conventional choice and the wrong one: a DM-only
//  client with a 50-message cache per channel fits in a file small enough to
//  read in one go, and the store is rewritten atomically.
//
//  The token is NOT here. It lives in the keychain.
//

import Foundation

public final class Persistence {

    public struct StoredMessage: Codable {
        public let id: String
        public let channelID: String
        public let authorID: String
        public let authorName: String
        public let content: String
        public let timestamp: String
        /// Rendered attachment markers, e.g. "[png 240K]". The URLs are kept so
        /// long-press can copy them; the bytes are never fetched.
        public let attachmentMarkers: [String]
        public let attachmentURLs: [String]
        public let embedCount: Int
    }

    public struct StoredChannel: Codable {
        public let id: String
        public let type: Int
        public let recipientIDs: [String]
        public let name: String?
        public var lastMessageID: String?
    }

    public struct StoredUser: Codable {
        public let id: String
        public let username: String
        public let displayName: String
    }

    /// Snapshot is decoded leniently: a file written by an earlier build is
    /// missing newer keys, and a hard decode failure would throw the whole
    /// store away and force a full IDENTIFY. See `init(from:)`.
    public struct Snapshot: Codable {
        public var version: Int = 1
        public var sessionID: String?
        public var sequence: Int?
        public var resumeGatewayURL: String?
        public var guildVersions: [String: Int] = [:]
        /// Every guild id seen. Needed to re-send op 37 after a RESUME, which
        /// never replays READY. Ids only, never guild content.
        public var knownGuildIDs: Set<String> = []
        public var readStates: [String: String] = [:]
        public var channels: [StoredChannel] = []
        public var users: [String: StoredUser] = [:]
        public var messages: [String: [StoredMessage]] = [:]
        public var selfUserID: String?

        public init() {}

        enum CodingKeys: String, CodingKey {
            case version, sessionID, sequence, resumeGatewayURL, guildVersions
            case knownGuildIDs, readStates, channels, users, messages, selfUserID
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // decodeIfPresent returns nil for a missing key rather than
            // throwing, so a store written by an earlier build decodes fine
            // and newer fields take their defaults. A genuinely corrupt file
            // does throw, and Persistence.init catches that and starts fresh.
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
            sequence = try c.decodeIfPresent(Int.self, forKey: .sequence)
            resumeGatewayURL = try c.decodeIfPresent(String.self, forKey: .resumeGatewayURL)
            guildVersions = try c.decodeIfPresent([String: Int].self,
                                                  forKey: .guildVersions) ?? [:]
            knownGuildIDs = try c.decodeIfPresent(Set<String>.self,
                                                  forKey: .knownGuildIDs) ?? []
            readStates = try c.decodeIfPresent([String: String].self,
                                               forKey: .readStates) ?? [:]
            channels = try c.decodeIfPresent([StoredChannel].self,
                                             forKey: .channels) ?? []
            users = try c.decodeIfPresent([String: StoredUser].self,
                                          forKey: .users) ?? [:]
            messages = try c.decodeIfPresent([String: [StoredMessage]].self,
                                             forKey: .messages) ?? [:]
            selfUserID = try c.decodeIfPresent(String.self, forKey: .selfUserID)
        }
    }

    /// Messages retained per channel on disk.
    public static let messagesPerChannel = 50

    private let url: URL
    private let io = DispatchQueue(label: "smolcord.persistence")
    private var pending: DispatchWorkItem?

    public private(set) var snapshot: Snapshot

    /// - Parameter directory: where the store lives. Defaults to Application
    ///   Support; the tests pass a temporary directory so they never touch a
    ///   real install's cache.
    public init(filename: String = "smolcord.json", directory: URL? = nil) {
        // The force-unwrap this replaces would crash anywhere Application
        // Support is absent, which includes a Linux `swift test` run.
        let dir = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(filename)

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = Snapshot()
        }
    }

    /// Mutate and schedule a write. Writes are coalesced: a burst of messages
    /// produces one disk write, not one per message.
    public func update(_ mutate: (inout Snapshot) -> Void) {
        mutate(&snapshot)
        scheduleSave()
    }

    private func scheduleSave() {
        pending?.cancel()
        let copy = snapshot
        let work = DispatchWorkItem { [weak self] in
            self?.writeNow(copy)
        }
        pending = work
        io.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Write immediately. Call on background or terminate.
    public func flush() {
        pending?.cancel()
        let copy = snapshot
        io.sync { self.writeNow(copy) }
    }

    private func writeNow(_ snap: Snapshot) {
        guard let data = try? JSONEncoder().encode(snap) else { return }
        // Atomic: a crash mid-write must not leave a truncated store that
        // forces a full IDENTIFY on the next launch.
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func wipe() {
        pending?.cancel()
        snapshot = Snapshot()
        io.sync { try? FileManager.default.removeItem(at: self.url) }
    }
}
