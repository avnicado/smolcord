//
//  GatewayEvent.swift
//
//  Decodes the gateway's dispatch events -- but only the ones a DM client uses.
//
//  Two deliberate decisions here:
//
//  1. JSONSerialization, not Codable.
//     READY is the largest and most complex event the gateway sends. Codable
//     would materialise the whole object graph to reach a handful of fields.
//     On an iPhone 5s that is measurable. We walk the dictionary and lift only
//     what we need.
//
//  2. An allow-list, not a switch with a default.
//     Any event type not named below is dropped without parsing its body.
//
//     This is the ONLY guard against guild messages, not a second line of
//     defence. Op 37 was measured and does not stop guild MESSAGE_CREATE: a
//     16-guild account still took 28 of them in 3.7 minutes after
//     unsubscribing. Those bytes arrive and are paid for no matter what we do
//     here. The filter saves CPU and storage, not data.
//
//  DM detection: a DM event has no `guild_id`. Anything carrying one is a guild
//  event and is discarded at this boundary.
//

import Foundation

public enum GatewayEvent {
    case ready(Ready)
    case readySupplemental
    case messageCreate(Message)
    case messageUpdate(Message)
    case messageDelete(channelID: String, messageID: String)
    case messageAck(channelID: String, messageID: String)
    case channelCreate(DMChannel)
    case channelDelete(channelID: String)
    case typingStart(channelID: String, userID: String, timestamp: Int)
    case presenceUpdate(userID: String, status: String)
    case relationshipAdd(user: User)
    case relationshipRemove(userID: String)

    /// A guild arrived after READY. We want nothing from it except the id, so
    /// we can unsubscribe from it. Large accounts list guilds as unavailable in
    /// READY and stream them in later; those guilds stay subscribed, and
    /// therefore expensive, unless we send op 37 again.
    case guildCreate(guildID: String)

    /// Recognised, but carrying no DM-relevant content. Counted, not stored.
    case ignored(String)

    // MARK: - Models

    public struct User {
        public let id: String
        public let username: String
        /// Display name. Discord's "global_name" after the Pomelo rename; falls
        /// back to username.
        public let displayName: String

        public init(id: String, username: String, displayName: String) {
            self.id = id
            self.username = username
            self.displayName = displayName
        }
    }

    public struct Attachment {
        public let filename: String
        public let size: Int
        public let url: String

        /// How the terminal UI renders this. We never fetch the bytes.
        public var marker: String {
            let kb = Double(size) / 1024.0
            let sizeText: String
            if kb < 1 { sizeText = "\(size)B" }
            else if kb < 1024 { sizeText = String(format: "%.0fK", kb) }
            else { sizeText = String(format: "%.1fM", kb / 1024.0) }
            // Pure Swift, not `(filename as NSString).pathExtension`:
            // String/NSString bridging is unavailable on Linux, and this file
            // is in the portable subset that `swift test` compiles.
            let ext = GatewayEvent.pathExtension(of: filename)
            return "[\(ext.isEmpty ? "file" : ext) \(sizeText)]"
        }
    }

    public struct Message {
        public let id: String
        public let channelID: String
        public let authorID: String
        public let authorName: String
        public let content: String
        public let timestamp: String
        public let attachments: [Attachment]
        /// Embeds are counted but never rendered or fetched.
        public let embedCount: Int
        public let referencedMessageID: String?
    }

    public struct DMChannel {
        public let id: String
        /// 1 = DM, 3 = group DM. Anything else is not ours.
        public let type: Int
        public let recipientIDs: [String]
        public let lastMessageID: String?
        public let name: String?
    }

    public struct Ready {
        public let sessionID: String
        public let resumeGatewayURL: String?
        public let selfUser: User
        /// Every user object in the payload, hoisted by `dedupeUserObjects`.
        public let users: [String: User]
        public let dmChannels: [DMChannel]
        /// guild id -> version, for the client_state cache. We keep these only
        /// to send them back; guild content is never stored.
        public let guildVersions: [String: Int]
        public let guildIDs: [String]
        /// channel id -> last read message id.
        public let readStates: [String: String]
    }

    // MARK: - Decoding

    /// Event names we parse. Everything else is `.ignored`.
    private static let known: Set<String> = [
        "READY", "READY_SUPPLEMENTAL",
        "MESSAGE_CREATE", "MESSAGE_UPDATE", "MESSAGE_DELETE", "MESSAGE_ACK",
        "CHANNEL_CREATE", "CHANNEL_DELETE",
        "TYPING_START", "PRESENCE_UPDATE",
        "RELATIONSHIP_ADD", "RELATIONSHIP_REMOVE",
        // Not DM content. Carried only so we can unsubscribe from late guilds.
        "GUILD_CREATE",
    ]

    /// Decode a dispatch payload.
    ///
    /// - Parameters:
    ///   - name: the `t` field.
    ///   - d: the `d` field, already parsed as a dictionary.
    /// - Returns: nil when the event is a guild event, or not useful to us.
    public static func decode(name: String, d: Any?) -> GatewayEvent? {
        guard known.contains(name) else { return .ignored(name) }
        let dict = d as? [String: Any]

        // Handled before the guild filter below: this is the one guild event we
        // want, and we want exactly one field from it.
        if name == "GUILD_CREATE" {
            guard let dict = dict else { return nil }
            // clientStateV2 moves the id into a `properties` subkey.
            let gid = str(dict["id"])
                ?? str((dict["properties"] as? [String: Any])?["id"])
            guard let id = gid else { return nil }
            return .guildCreate(guildID: id)
        }

        // Guild events are not our business. One field check, before any work.
        //
        // This does not save bytes: guild messages arrive regardless, because
        // op 37 does not gate them. It saves the cost of parsing them and
        // keeps them out of the store.
        if let dict = dict, dict["guild_id"] != nil {
            return .ignored(name + "(guild)")
        }

        switch name {
        case "READY":
            guard let dict = dict, let ready = parseReady(dict) else { return nil }
            return .ready(ready)

        case "READY_SUPPLEMENTAL":
            // Carries voice states, activities and merged presences. A DM-only
            // text client needs none of it.
            return .readySupplemental

        case "MESSAGE_CREATE":
            guard let dict = dict, let m = parseMessage(dict) else { return nil }
            return .messageCreate(m)

        case "MESSAGE_UPDATE":
            guard let dict = dict, let m = parseMessage(dict) else { return nil }
            return .messageUpdate(m)

        case "MESSAGE_DELETE":
            guard let dict = dict,
                  let cid = str(dict["channel_id"]),
                  let mid = str(dict["id"]) else { return nil }
            return .messageDelete(channelID: cid, messageID: mid)

        case "MESSAGE_ACK":
            guard let dict = dict,
                  let cid = str(dict["channel_id"]),
                  let mid = str(dict["message_id"]) else { return nil }
            return .messageAck(channelID: cid, messageID: mid)

        case "CHANNEL_CREATE":
            guard let dict = dict, let ch = parseChannel(dict) else { return nil }
            return .channelCreate(ch)

        case "CHANNEL_DELETE":
            guard let dict = dict, let cid = str(dict["id"]) else { return nil }
            return .channelDelete(channelID: cid)

        case "TYPING_START":
            guard let dict = dict,
                  let cid = str(dict["channel_id"]),
                  let uid = str(dict["user_id"]) else { return nil }
            let ts = (dict["timestamp"] as? Int) ?? Int(Date().timeIntervalSince1970)
            return .typingStart(channelID: cid, userID: uid, timestamp: ts)

        case "PRESENCE_UPDATE":
            guard let dict = dict else { return nil }
            let uid = str(dict["user_id"])
                ?? str((dict["user"] as? [String: Any])?["id"])
            guard let userID = uid else { return nil }
            let status = (dict["status"] as? String) ?? "offline"
            return .presenceUpdate(userID: userID, status: status)

        case "RELATIONSHIP_ADD":
            guard let dict = dict,
                  let u = parseUser(dict["user"] as? [String: Any]) else { return nil }
            return .relationshipAdd(user: u)

        case "RELATIONSHIP_REMOVE":
            guard let dict = dict, let id = str(dict["id"]) else { return nil }
            return .relationshipRemove(userID: id)

        default:
            return .ignored(name)
        }
    }

    /// Lowercased extension, or "" when there is none.
    ///
    /// A leading dot does not count: ".bashrc" has no extension.
    static func pathExtension(of filename: String) -> String {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else {
            return ""
        }
        return String(filename[filename.index(after: dot)...]).lowercased()
    }

    // MARK: - Field helpers

    /// Discord snowflakes are strings, but some payloads carry numbers.
    /// Normalise rather than trust.
    private static func str(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func parseUser(_ dict: [String: Any]?) -> User? {
        guard let dict = dict, let id = str(dict["id"]) else { return nil }
        let username = (dict["username"] as? String) ?? "unknown"
        let global = dict["global_name"] as? String
        return User(id: id,
                    username: username,
                    displayName: (global?.isEmpty == false ? global! : username))
    }

    private static func parseMessage(_ dict: [String: Any]) -> Message? {
        guard let id = str(dict["id"]), let cid = str(dict["channel_id"]) else { return nil }
        let author = dict["author"] as? [String: Any]
        let authorUser = parseUser(author)

        var attachments = [Attachment]()
        if let raw = dict["attachments"] as? [[String: Any]] {
            for a in raw {
                attachments.append(Attachment(
                    filename: (a["filename"] as? String) ?? "file",
                    size: (a["size"] as? Int) ?? 0,
                    url: (a["url"] as? String) ?? ""))
            }
        }
        let embeds = (dict["embeds"] as? [[String: Any]])?.count ?? 0
        let ref = (dict["message_reference"] as? [String: Any])
            .flatMap { str($0["message_id"]) }

        return Message(
            id: id,
            channelID: cid,
            authorID: authorUser?.id ?? str(dict["author_id"]) ?? "0",
            authorName: authorUser?.displayName ?? "unknown",
            content: (dict["content"] as? String) ?? "",
            timestamp: (dict["timestamp"] as? String) ?? "",
            attachments: attachments,
            embedCount: embeds,
            referencedMessageID: ref)
    }

    private static func parseChannel(_ dict: [String: Any]) -> DMChannel? {
        guard let id = str(dict["id"]) else { return nil }
        let type = (dict["type"] as? Int) ?? -1
        // 1 = DM, 3 = group DM. Reject guild channel types outright.
        guard type == 1 || type == 3 else { return nil }

        var recipients = [String]()
        if let ids = dict["recipient_ids"] as? [Any] {
            recipients = ids.compactMap { str($0) }
        } else if let objs = dict["recipients"] as? [[String: Any]] {
            recipients = objs.compactMap { str($0["id"]) }
        }
        return DMChannel(
            id: id,
            type: type,
            recipientIDs: recipients,
            lastMessageID: str(dict["last_message_id"]),
            name: dict["name"] as? String)
    }

    private static func parseReady(_ dict: [String: Any]) -> Ready? {
        guard let sessionID = dict["session_id"] as? String else { return nil }
        guard let selfUser = parseUser(dict["user"] as? [String: Any]) else { return nil }

        // `dedupeUserObjects` hoists every user here.
        var users = [String: User]()
        if let raw = dict["users"] as? [[String: Any]] {
            users.reserveCapacity(raw.count)
            for u in raw {
                if let parsed = parseUser(u) { users[parsed.id] = parsed }
            }
        }

        // `prioritizedReadyPayload` can put private channels in either event,
        // so handle both keys.
        var channels = [DMChannel]()
        for key in ["private_channels", "lazy_private_channels"] {
            if let raw = dict[key] as? [[String: Any]] {
                for c in raw {
                    if let parsed = parseChannel(c) { channels.append(parsed) }
                }
            }
        }

        // Guild versions only. Guild content is never retained.
        var versions = [String: Int]()
        var guildIDs = [String]()
        if let guilds = dict["guilds"] as? [[String: Any]] {
            guildIDs.reserveCapacity(guilds.count)
            for g in guilds {
                // clientStateV2 moves id into a `properties` subkey.
                let gid = str(g["id"]) ?? str((g["properties"] as? [String: Any])?["id"])
                guard let id = gid else { continue }
                guildIDs.append(id)
                if let v = g["version"] as? Int { versions[id] = v }
            }
        }

        // read_state is versioned by `versionedReadStates`, so it may be an
        // object wrapping `entries` rather than a bare array.
        var readStates = [String: String]()
        let rsEntries: [[String: Any]]?
        if let obj = dict["read_state"] as? [String: Any] {
            rsEntries = obj["entries"] as? [[String: Any]]
        } else {
            rsEntries = dict["read_state"] as? [[String: Any]]
        }
        if let entries = rsEntries {
            for e in entries {
                if let cid = str(e["id"]), let mid = str(e["last_message_id"]) {
                    readStates[cid] = mid
                }
            }
        }

        return Ready(
            sessionID: sessionID,
            resumeGatewayURL: dict["resume_gateway_url"] as? String,
            selfUser: selfUser,
            users: users,
            dmChannels: channels,
            guildVersions: versions,
            guildIDs: guildIDs,
            readStates: readStates)
    }
}
