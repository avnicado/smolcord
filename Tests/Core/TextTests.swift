//
//  TextTests.swift
//
//  Part of the portable test suite: everything here compiles and runs on Linux
//  via Package.swift, as well as in the Xcode test target. Nothing in this
//  directory may import UIKit, Network or Security.
//
//  Run locally:  swift test
//

import XCTest
@testable import smolcord

final class TextWrapTests: XCTestCase {

    func testWrapsOnSpaces() {
        let lines = wrapTerminalText("the quick brown fox jumps over", columns: 12)
        XCTAssertTrue(lines.allSatisfy { $0.count <= 12 }, "\(lines)")
    }

    func testHardBreaksAnOverlongWord() {
        let lines = wrapTerminalText(String(repeating: "x", count: 40), columns: 10)
        XCTAssertGreaterThanOrEqual(lines.count, 4)
        XCTAssertTrue(lines.allSatisfy { $0.count <= 10 }, "\(lines)")
    }

    func testPreservesParagraphBreaks() {
        let lines = wrapTerminalText("one\n\ntwo", columns: 20)
        XCTAssertEqual(lines, ["one", "", "two"])
    }
}

final class TimeFormattingTests: XCTestCase {

    func testISOTimestampToShortClock() {
        XCTAssertEqual(shortClockTime(fromISO8601: "2026-11-15T14:32:07.123000+00:00"), "14:32")
        XCTAssertEqual(shortClockTime(fromISO8601: ""), "")
        XCTAssertEqual(shortClockTime(fromISO8601: "garbage"), "")
    }
}
