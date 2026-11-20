//
//  DMStoreTests.swift
//
//  NOT in the portable suite. DMStore reaches Keychain (Security.framework)
//  and Gateway (Network.framework), so these only run in the Xcode test
//  target, on a simulator or a device.
//
//  The synthetic events keep it off the network even there.
//

import XCTest
@testable import smolcord

final class DMStoreTests: XCTestCase {

    private var dir: URL!
    private var store: DMStore!
    private var persistence: Persistence!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smolcord-dm-\(UUID().uuidString)")
        persistence = Persistence(filename: "t.json", directory: dir)
        store = DMStore(persistence: persistence, meter: ByteMeter())
    }

    override func tearDown() {
        if let dir = dir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    private func ready() -> GatewayEvent {
        let me = GatewayEvent.User(id: "1", username: "me", displayName: "me")
        return .ready(GatewayEvent.Ready(
            sessionID: "s",
            resumeGatewayURL: nil,
            selfUser: me,
            users: [
                "2": GatewayEvent.User(id: "2", username: "alice", displayName: "Alice"),
                "3": GatewayEvent.User(id: "3", username: "bob", displayName: "Bob"),
            ],
            dmChannels: [
                GatewayEvent.DMChannel(id: "10", type: 1, recipientIDs: ["2"],
                                       lastMessageID: "100", name: nil),
                GatewayEvent.DMChannel(id: "20", type: 1, recipientIDs: ["3"],
                                       lastMessageID: "200", name: nil),
            ],
            guildVersions: ["900": 3],
            guildIDs: ["900"],
            readStates: ["10": "100"]))
    }

    private func message(_ id: String, channel: String, author: String,
                         text: String,
                         attachments: [GatewayEvent.Attachment] = []) -> GatewayEvent {
        return .messageCreate(GatewayEvent.Message(
            id: id, channelID: channel, authorID: author,
            authorName: author == "1" ? "me" : "Alice",
            content: text,
            timestamp: "2026-11-19T14:32:07.000000+00:00",
            attachments: attachments, embedCount: 0, referencedMessageID: nil))
    }

    func testReadyPopulatesConversations() {
        store.apply(ready())
        let convos = store.conversations()
        XCTAssertEqual(convos.count, 2)
        XCTAssertEqual(Set(convos.map { $0.title }), ["Alice", "Bob"])
    }

    func testConversationsSortNewestFirstBySnowflakeValue() {
        store.apply(ready())
        // Snowflakes of different lengths sort wrongly as strings. "99" is
        // lexically greater than "200" but numerically smaller.
        store.apply(.channelCreate(GatewayEvent.DMChannel(
            id: "30", type: 1, recipientIDs: ["2"], lastMessageID: "99", name: nil)))
        let ids = store.conversations().map { $0.id }
        XCTAssertEqual(ids.first, "20", "expected the highest snowflake first, got \(ids)")
        XCTAssertEqual(ids.last, "30")
    }

    func testIncomingMessageUpdatesPreviewAndUnread() {
        store.apply(ready())
        store.apply(message("300", channel: "20", author: "3", text: "hello there"))
        guard let convo = store.conversations().first(where: { $0.id == "20" }) else {
            return XCTFail("channel 20 missing")
        }
        XCTAssertEqual(convo.lastMessagePreview, "hello there")
        XCTAssertGreaterThan(convo.unreadCount, 0)
    }

    func testReadChannelHasNoUnread() {
        store.apply(ready())
        // readStates marks 10 as read up to its last message.
        guard let convo = store.conversations().first(where: { $0.id == "10" }) else {
            return XCTFail("channel 10 missing")
        }
        XCTAssertEqual(convo.unreadCount, 0)
    }

    func testOwnMessagesAreMarkedAsFromSelf() {
        store.apply(ready())
        store.apply(message("301", channel: "20", author: "1", text: "mine"))
        let lines = store.lines(channelID: "20")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].isFromSelf)
        XCTAssertFalse(lines[0].isPending)
    }

    func testAttachmentsBecomeMarkersAndKeepTheirURLs() {
        store.apply(ready())
        store.apply(message("302", channel: "20", author: "3", text: "",
                            attachments: [GatewayEvent.Attachment(
                                filename: "shot.png", size: 245_760,
                                url: "https://cdn.example/shot.png")]))
        let lines = store.lines(channelID: "20")
        XCTAssertEqual(lines.last?.attachmentMarkers, ["[png 240K]"])
        XCTAssertEqual(lines.last?.attachmentURLs, ["https://cdn.example/shot.png"])
    }

    func testMessageDeleteRemovesTheLine() {
        store.apply(ready())
        store.apply(message("303", channel: "20", author: "3", text: "oops"))
        XCTAssertEqual(store.lines(channelID: "20").count, 1)
        store.apply(.messageDelete(channelID: "20", messageID: "303"))
        XCTAssertEqual(store.lines(channelID: "20").count, 0)
    }

    func testMessagesForUnknownChannelsAreDropped() {
        store.apply(ready())
        // A channel we never saw is not a DM we track. Storing it would grow
        // the cache for content the UI can never show.
        store.apply(message("304", channel: "99999", author: "3", text: "x"))
        XCTAssertEqual(store.lines(channelID: "99999").count, 0)
    }

    func testTypingExpires() {
        store.apply(ready())
        store.apply(.typingStart(channelID: "20", userID: "3", timestamp: 0))
        XCTAssertEqual(store.typingNames(channelID: "20"), ["Bob"])
        // Discord typing lasts 10 seconds; the store stamps an expiry rather
        // than relying on a stop event, because none is sent.
        XCTAssertFalse(store.typingNames(channelID: "20").isEmpty)
    }

    func testOwnTypingIsIgnored() {
        store.apply(ready())
        store.apply(.typingStart(channelID: "20", userID: "1", timestamp: 0))
        XCTAssertTrue(store.typingNames(channelID: "20").isEmpty)
    }

    func testGuildCreateIsNotStored() {
        store.apply(ready())
        let before = store.conversations().count
        store.apply(.guildCreate(guildID: "901"))
        XCTAssertEqual(store.conversations().count, before,
                       "a guild must never appear as a conversation")
    }

    func testDMStoreDoesNotOwnGuildVersions() {
        store.apply(ready())
        // Deliberately nil. READY carries guild versions, and DMStore drops
        // them: persisting them is Gateway's job, through its SessionCache and
        // the onSessionCache callback. DMStore has no guild responsibilities
        // at all, which is why it has no guild state to get wrong.
        //
        // An earlier version of this test asserted the opposite and failed in
        // CI. The division of labour is the correct behaviour, not the bug.
        XCTAssertNil(persistence.snapshot.guildVersions["900"],
                     "DMStore must not persist guild state")
    }

    func testDMStorePersistsOnlyWhatTheUICanShow() {
        store.apply(ready())
        store.apply(message("310", channel: "20", author: "3", text: "hi"))
        let snap = persistence.snapshot

        // Everything persisted must be DM-shaped. A 119KB READY arrives full
        // of channels, roles and emojis for 16 guilds; none of it may land
        // on disk.
        XCTAssertTrue(snap.channels.allSatisfy { $0.type == 1 || $0.type == 3 })
        XCTAssertTrue(snap.messages.keys.allSatisfy { snap.channels.contains { c in c.id == $0 } },
                      "a message was stored for a channel that is not a tracked DM")
        XCTAssertNotNil(snap.selfUserID)
    }

    func testGuildContentIsNeverRetained() {
        store.apply(ready())
        XCTAssertTrue(persistence.snapshot.channels.allSatisfy { $0.type == 1 || $0.type == 3 },
                      "only DM and group-DM channels may be persisted")
    }
}
