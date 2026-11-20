//
//  ProtocolTests.swift
//
//  Part of the portable test suite: everything here compiles and runs on Linux
//  via Package.swift, as well as in the Xcode test target. Nothing in this
//  directory may import UIKit, Network or Security.
//
//  Run locally:  swift test
//

import XCTest
@testable import smolcord

final class CapabilitiesTests: XCTestCase {

    func testOfficialValueMatchesTheReferenceClient() {
        // A capabilities value no real client sends is an anti-spam
        // fingerprint. If this fails, the reference value moved: check
        // Capabilities.default() in dolfies/discord.py-self and update both
        // this expectation and the comment in Identify.swift.
        XCTAssertEqual(GatewayCapabilities.official.rawValue,
                       GatewayCapabilities.expectedOfficialRawValue,
                       "capabilities drifted from the official client value")
    }

    func testTheExpensiveReadyTrimsAreEnabled() {
        let caps = GatewayCapabilities.official
        // dedupeUserObjects is the single biggest READY reduction available.
        XCTAssertTrue(caps.contains(.dedupeUserObjects))
        // prioritizedReadyPayload requires it, and carries both bits.
        XCTAssertTrue(caps.contains(.prioritizedReadyPayload))
        // clientStateV2 is what makes the guild_versions cache work at all.
        XCTAssertTrue(caps.contains(.clientStateV2))
        XCTAssertTrue(caps.contains(.lazyUserNotes))
        XCTAssertTrue(caps.contains(.userSettingsProto))
    }
}

final class IdentifyTests: XCTestCase {

    func testIdentifyCarriesCapabilitiesAndClientState() throws {
        let payload = Identify.payload(token: "redacted",
                                       guildVersions: ["123": 7, "456": 2])
        let d = payload["d"] as? [String: Any]
        XCTAssertNotNil(d)

        XCTAssertEqual(d?["capabilities"] as? Int,
                       GatewayCapabilities.expectedOfficialRawValue)

        // Transport compression is on via the URL, so payload compression must
        // be off. Discord allows only one, and sending both is an error.
        XCTAssertEqual(d?["compress"] as? Bool, false)

        // Lever 3: unchanged guild data is skipped on the next IDENTIFY.
        let clientState = d?["client_state"] as? [String: Any]
        let versions = clientState?["guild_versions"] as? [String: Int]
        XCTAssertEqual(versions?["123"], 7)
        XCTAssertEqual(versions?["456"], 2)

        // Invisible: we are a reader, not a presence broadcaster.
        let presence = d?["presence"] as? [String: Any]
        XCTAssertEqual(presence?["status"] as? String, "invisible")
    }

    func testUnsubscribePayloadSetsEveryFlagFalse() throws {
        let payload = Identify.unsubscribeAllGuildsPayload(guildIDs: ["1", "2", "3"])
        XCTAssertEqual(payload["op"] as? Int, GatewayOpcode.bulkGuildSubscribe.rawValue)

        let d = payload["d"] as? [String: Any]
        let subs = d?["subscriptions"] as? [String: Any]
        XCTAssertEqual(subs?.count, 3)

        // This is lever 2. A flag left true reopens the presence stream, which
        // measured at roughly 75KB/hr on a 16-guild account.
        for id in ["1", "2", "3"] {
            let entry = subs?[id] as? [String: Any]
            XCTAssertEqual(entry?["typing"] as? Bool, false, "guild \(id)")
            XCTAssertEqual(entry?["activities"] as? Bool, false, "guild \(id)")
            XCTAssertEqual(entry?["threads"] as? Bool, false, "guild \(id)")
            XCTAssertEqual(entry?["member_updates"] as? Bool, false, "guild \(id)")
            XCTAssertEqual((entry?["members"] as? [Any])?.count, 0, "guild \(id)")
        }
    }

    func testUnsubscribePayloadStaysSmall() throws {
        // 200 guilds is the user-account maximum. The message is paid once per
        // connect, so it must stay in the single-digit kilobytes.
        let ids = (0..<200).map { String(1_000_000_000_000_000_000 + $0) }
        let payload = Identify.unsubscribeAllGuildsPayload(guildIDs: ids)
        let encoded = Identify.encode(payload)
        XCTAssertNotNil(encoded)
        let bytes = encoded!.utf8.count
        XCTAssertLessThan(bytes, 32_000,
                          "op 37 for 200 guilds grew to \(bytes) bytes")
    }

    func testEncodingAddsNoWhitespace() throws {
        let encoded = Identify.encode(["op": 1, "d": 42])
        XCTAssertNotNil(encoded)
        XCTAssertFalse(encoded!.contains("\n"))
        XCTAssertFalse(encoded!.contains(": "))
    }
}

final class GatewayEventTests: XCTestCase {

    func testGuildMessagesAreDiscardedAtTheDecodeBoundary() {
        // MEASURED: op 37 does not stop guild messages, so this filter is the
        // only guard. It saves parsing and storage, not bytes. Even so,
        // it must cost no parsing and store nothing.
        let d: [String: Any] = [
            "id": "111", "channel_id": "222", "guild_id": "333",
            "content": "should never reach the store",
            "author": ["id": "444", "username": "someone"],
        ]
        let event = GatewayEvent.decode(name: "MESSAGE_CREATE", d: d)
        guard case .some(.ignored(let label)) = event else {
            return XCTFail("a guild MESSAGE_CREATE was not ignored: \(String(describing: event))")
        }
        XCTAssertTrue(label.contains("guild"))
    }

    func testDMMessageDecodes() {
        let d: [String: Any] = [
            "id": "111", "channel_id": "222",
            "content": "hello",
            "timestamp": "2026-11-15T14:32:07.123000+00:00",
            "author": ["id": "444", "username": "alice", "global_name": "Alice"],
            "attachments": [["filename": "shot.png", "size": 245_760,
                             "url": "https://cdn.example/shot.png"]],
            "embeds": [],
        ]
        guard case .some(.messageCreate(let m)) = GatewayEvent.decode(name: "MESSAGE_CREATE", d: d) else {
            return XCTFail("a DM MESSAGE_CREATE failed to decode")
        }
        XCTAssertEqual(m.channelID, "222")
        XCTAssertEqual(m.authorName, "Alice")
        XCTAssertEqual(m.content, "hello")
        XCTAssertEqual(m.attachments.count, 1)
        // The marker is what the terminal renders. The bytes are never fetched.
        XCTAssertEqual(m.attachments[0].marker, "[png 240K]")
    }

    func testUnknownEventsAreIgnoredWithoutParsing() {
        let event = GatewayEvent.decode(name: "GUILD_AUDIT_LOG_ENTRY_CREATE", d: ["a": 1])
        guard case .some(.ignored) = event else {
            return XCTFail("an unknown event was not ignored")
        }
    }

    func testGuildChannelTypesAreRejected() {
        // type 0 is a guild text channel. Only 1 (DM) and 3 (group DM) are ours.
        let event = GatewayEvent.decode(name: "CHANNEL_CREATE",
                                        d: ["id": "9", "type": 0])
        XCTAssertNil(event, "a guild text channel was accepted as a DM")
    }

    func testSnowflakesArriveAsStringsOrNumbers() {
        // Some payloads carry numeric ids. Normalise rather than trust.
        let d: [String: Any] = ["channel_id": 222, "user_id": 444, "timestamp": 1_700_000_000]
        guard case .some(.typingStart(let cid, let uid, _)) =
                GatewayEvent.decode(name: "TYPING_START", d: d) else {
            return XCTFail("numeric snowflakes were not normalised")
        }
        XCTAssertEqual(cid, "222")
        XCTAssertEqual(uid, "444")
    }

    func testReadyLiftsDedupedUsersAndGuildVersions() {
        let d: [String: Any] = [
            "session_id": "abc",
            "resume_gateway_url": "wss://resume.example",
            "user": ["id": "1", "username": "me"],
            // dedupeUserObjects hoists every user into this array.
            "users": [["id": "2", "username": "alice", "global_name": "Alice"],
                      ["id": "3", "username": "bob"]],
            "private_channels": [["id": "10", "type": 1, "recipient_ids": ["2"]]],
            // clientStateV2 moves id into a properties subkey.
            "guilds": [["properties": ["id": "900"], "version": 42],
                       ["id": "901", "version": 7]],
            // versionedReadStates wraps the entries in an object.
            "read_state": ["entries": [["id": "10", "last_message_id": "555"]]],
        ]
        guard case .some(.ready(let ready)) = GatewayEvent.decode(name: "READY", d: d) else {
            return XCTFail("READY failed to decode")
        }
        XCTAssertEqual(ready.sessionID, "abc")
        XCTAssertEqual(ready.resumeGatewayURL, "wss://resume.example")
        XCTAssertEqual(ready.users["2"]?.displayName, "Alice")
        XCTAssertEqual(ready.users["3"]?.displayName, "bob")
        XCTAssertEqual(ready.dmChannels.count, 1)
        // Both guild id shapes must be found, or op 37 misses guilds and
        // their presence stream stays open.
        XCTAssertEqual(Set(ready.guildIDs), Set(["900", "901"]))
        XCTAssertEqual(ready.guildVersions["900"], 42)
        XCTAssertEqual(ready.readStates["10"], "555")
    }

    func testAttachmentMarkerFormatting() {
        let cases: [(Int, String, String)] = [
            (512, "a.txt", "[txt 512B]"),
            (245_760, "b.png", "[png 240K]"),
            (5_242_880, "c.mp4", "[mp4 5.0M]"),
            (1_024, "noext", "[file 1K]"),
        ]
        for (size, name, expected) in cases {
            let a = GatewayEvent.Attachment(filename: name, size: size, url: "")
            XCTAssertEqual(a.marker, expected, "\(name)")
        }
    }
}

final class CloseCodeTests: XCTestCase {

    func testAuthenticationFailureIsFatalNotRetried() {
        // Retrying a dead token burns a TLS handshake per attempt, measured at
        // about 5.4KB, forever.
        XCTAssertTrue(GatewayCloseCode.fatal.contains(GatewayCloseCode.authenticationFailed))
        XCTAssertFalse(GatewayCloseCode.reidentify.contains(GatewayCloseCode.authenticationFailed))
    }

    func testSessionTimeoutAsksForAFreshIdentify() {
        XCTAssertTrue(GatewayCloseCode.reidentify.contains(GatewayCloseCode.sessionTimedOut))
        XCTAssertTrue(GatewayCloseCode.reidentify.contains(GatewayCloseCode.invalidSequence))
    }

    func testRateLimitIsNeitherFatalNorReidentify() {
        // 4008 should back off and resume, not throw the session away.
        XCTAssertFalse(GatewayCloseCode.fatal.contains(GatewayCloseCode.rateLimited))
        XCTAssertFalse(GatewayCloseCode.reidentify.contains(GatewayCloseCode.rateLimited))
    }
}

final class LateGuildTests: XCTestCase {

    func testGuildCreateYieldsOnlyTheID() {
        // Large accounts list guilds as unavailable in READY and stream them in
        // afterwards. Those guilds stay subscribed, and therefore expensive,
        // unless op 37 is sent again. We want the id and nothing else.
        let d: [String: Any] = [
            "id": "900",
            "name": "a big noisy server",
            "channels": [["id": "1", "type": 0], ["id": "2", "type": 0]],
            "members": [["user": ["id": "5"]]],
        ]
        guard case .some(.guildCreate(let id)) = GatewayEvent.decode(name: "GUILD_CREATE", d: d) else {
            return XCTFail("GUILD_CREATE did not yield a guild id")
        }
        XCTAssertEqual(id, "900")
    }

    func testGuildCreateFindsIDUnderClientStateV2Properties() {
        // clientStateV2 moves guild properties into a subkey. Missing the id
        // here would silently leave that guild subscribed.
        let d: [String: Any] = ["properties": ["id": "901", "name": "x"], "version": 3]
        guard case .some(.guildCreate(let id)) = GatewayEvent.decode(name: "GUILD_CREATE", d: d) else {
            return XCTFail("GUILD_CREATE with properties.id did not decode")
        }
        XCTAssertEqual(id, "901")
    }

    func testGuildCreateSurvivesTheGuildIDFilter() {
        // An unavailable-guild payload can carry guild_id. GUILD_CREATE must be
        // handled before the filter that drops guild-scoped events, or late
        // guilds are never unsubscribed.
        let d: [String: Any] = ["id": "902", "guild_id": "902", "unavailable": true]
        guard case .some(.guildCreate(let id)) = GatewayEvent.decode(name: "GUILD_CREATE", d: d) else {
            return XCTFail("GUILD_CREATE was swallowed by the guild_id filter")
        }
        XCTAssertEqual(id, "902")
    }

    func testPassiveGuildUpdatesAreIgnoredNotTreatedAsContent() {
        // We enable passive_guild_update_v2, so these keep arriving for
        // unsubscribed guilds by design. They must cost no parsing.
        for name in ["PASSIVE_UPDATE_V2", "PASSIVE_UPDATE_V1", "CHANNEL_UNREADS_UPDATE"] {
            let event = GatewayEvent.decode(name: name, d: ["guild_id": "900"])
            guard case .some(.ignored) = event else {
                return XCTFail("\(name) was not ignored")
            }
        }
    }
}
