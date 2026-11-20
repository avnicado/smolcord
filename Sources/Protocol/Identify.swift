//
//  Identify.swift
//
//  Builds the IDENTIFY payload, and the op 37 bulk unsubscribe that follows it.
//
//  Three of the four data levers live in this file:
//
//    lever 1  capabilities        shrink READY at the server
//    lever 2  op 37 unsubscribe   stop guild presence (NOT guild messages)
//    lever 3  client_state        skip unchanged guild data on reconnect
//
//  Lever 4 (zlib-stream) is in the URL, in Gateway.swift.
//

import Foundation

public struct Identify {

    /// Client identity sent in IDENTIFY `properties`.
    ///
    /// These must look like a real client. A blank or novel property set is the
    /// clearest possible signal that a token is being used by something other
    /// than Discord's own app.
    ///
    /// Bump `clientVersion` and `clientBuildNumber` together, and re-check
    /// GatewayCapabilities.official when you do.
    public struct Properties {
        public var os = "iOS"
        public var browser = "Discord iOS"
        public var device = "iPhone"
        public var systemLocale = "en-US"
        public var clientVersion = "189.0"
        public var releaseChannel = "stable"
        public var osVersion = "12.5.7"
        public var clientBuildNumber = 394000

        public init() {}

        func asDictionary() -> [String: Any] {
            return [
                "os": os,
                "browser": browser,
                "device": device,
                "system_locale": systemLocale,
                "client_version": clientVersion,
                "release_channel": releaseChannel,
                "os_version": osVersion,
                "client_build_number": clientBuildNumber,
                "client_event_source": NSNull(),
            ]
        }
    }

    /// Build the IDENTIFY payload.
    ///
    /// - Parameter guildVersions: lever 3. Versions kept from the previous
    ///   READY. Discord omits guild data that has not changed since. Pass an
    ///   empty dictionary on a first run.
    public static func payload(token: String,
                               properties: Properties = Properties(),
                               guildVersions: [String: Int]) -> [String: Any] {
        return [
            "op": GatewayOpcode.identify.rawValue,
            "d": [
                "token": token,
                "capabilities": GatewayCapabilities.official.rawValue,
                "properties": properties.asDictionary(),
                // Invisible. We are a reader, not a presence broadcaster, and
                // staying invisible avoids our own presence fan-out coming
                // back to us.
                "presence": [
                    "status": "invisible",
                    "activities": [],
                    "afk": false,
                    "since": 0,
                ] as [String: Any],
                // Transport compression is enabled on the URL, so payload
                // compression must be off. Discord allows only one.
                "compress": false,
                "client_state": [
                    "guild_versions": guildVersions,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    /// RESUME. Cheaper than IDENTIFY by the whole size of READY, so always
    /// prefer it when the session is still alive.
    public static func resumePayload(token: String,
                                     sessionID: String,
                                     sequence: Int) -> [String: Any] {
        return [
            "op": GatewayOpcode.resume.rawValue,
            "d": [
                "token": token,
                "session_id": sessionID,
                "seq": sequence,
            ] as [String: Any],
        ]
    }

    /// Lever 2. Unsubscribe from every guild in one message.
    ///
    /// MEASURED, 19 Nov 2026, on a 16-guild account over a 3.7-minute shared
    /// window against a subscribed control session:
    ///
    ///   guild PRESENCE_UPDATE   26 -> 0      silenced
    ///   guild MESSAGE_CREATE    29 -> 28     no effect
    ///   guild MESSAGE_UPDATE     2 -> 2      no effect
    ///
    /// So this does NOT stop guild messages, contrary to the community
    /// documentation that describes subscriptions as gating all "non-stateful"
    /// events. The flags govern presence, activities and member updates.
    /// TYPING_START did not occur in either arm, so its behaviour is untested.
    ///
    /// Worth keeping regardless: it removed roughly 400 presence events an
    /// hour, about 75KB/hr, for one 2KB message paid once per connection.
    ///
    /// Not tried: `large_threshold` at its minimum of 50, which the gateway
    /// docs tie to non-stateful delivery for users, and a subscription entry
    /// shaped differently from all-false. Guild messages measured at about
    /// 65KB/hr in frames, so there was no budget reason to keep digging.
    ///
    /// DM channels are not guilds, so DM events are unaffected either way.
    public static func unsubscribeAllGuildsPayload(guildIDs: [String]) -> [String: Any] {
        var subscriptions = [String: Any]()
        subscriptions.reserveCapacity(guildIDs.count)
        for id in guildIDs {
            subscriptions[id] = [
                "typing": false,
                "threads": false,
                "activities": false,
                "member_updates": false,
                "members": [],
                "channels": [String: Any](),
            ] as [String: Any]
        }
        return [
            "op": GatewayOpcode.bulkGuildSubscribe.rawValue,
            "d": ["subscriptions": subscriptions] as [String: Any],
        ]
    }

    /// Serialise without pretty printing or sorted keys. Both would add bytes.
    public static func encode(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
