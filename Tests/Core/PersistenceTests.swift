//
//  PersistenceTests.swift
//
//  Part of the portable test suite: everything here compiles and runs on Linux
//  via Package.swift, as well as in the Xcode test target. Nothing in this
//  directory may import UIKit, Network or Security.
//
//  Run locally:  swift test
//

import XCTest
@testable import smolcord

final class PersistenceTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smolcord-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let dir = dir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    func testRoundTrip() {
        let store = Persistence(filename: "t.json", directory: dir)
        store.update { snap in
            snap.sessionID = "abc"
            snap.sequence = 42
            snap.guildVersions = ["900": 7]
            snap.knownGuildIDs = ["900", "901"]
        }
        store.flush()

        let reloaded = Persistence(filename: "t.json", directory: dir)
        XCTAssertEqual(reloaded.snapshot.sessionID, "abc")
        XCTAssertEqual(reloaded.snapshot.sequence, 42)
        XCTAssertEqual(reloaded.snapshot.guildVersions["900"], 7)
        XCTAssertEqual(reloaded.snapshot.knownGuildIDs, ["900", "901"])
    }

    func testAnOlderStoreWithoutNewerKeysStillLoads() throws {
        // knownGuildIDs was added after the first build shipped. A store
        // written without it must not be discarded: losing it costs a full
        // IDENTIFY plus a 119KB READY.
        let legacy = """
        {"version":1,"sessionID":"old","sequence":7,"guildVersions":{"5":2}}
        """
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("t.json"))

        let store = Persistence(filename: "t.json", directory: dir)
        XCTAssertEqual(store.snapshot.sessionID, "old",
                       "a store missing newer keys was thrown away")
        XCTAssertEqual(store.snapshot.sequence, 7)
        XCTAssertEqual(store.snapshot.knownGuildIDs, [])
        XCTAssertTrue(store.snapshot.channels.isEmpty)
    }

    func testCorruptStoreStartsFreshRatherThanCrashing() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: dir.appendingPathComponent("t.json"))
        let store = Persistence(filename: "t.json", directory: dir)
        XCTAssertNil(store.snapshot.sessionID)
    }

    func testWipeRemovesTheFile() {
        let store = Persistence(filename: "t.json", directory: dir)
        store.update { $0.sessionID = "x" }
        store.flush()
        store.wipe()
        let reloaded = Persistence(filename: "t.json", directory: dir)
        XCTAssertNil(reloaded.snapshot.sessionID)
    }
}
