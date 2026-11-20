//
//  MeterTests.swift
//
//  Part of the portable test suite: everything here compiles and runs on Linux
//  via Package.swift, as well as in the Xcode test target. Nothing in this
//  directory may import UIKit, Network or Security.
//
//  Run locally:  swift test
//

import XCTest
@testable import smolcord

final class ByteMeterTests: XCTestCase {

    func testInboundAndOutboundAreCounted() {
        let meter = ByteMeter()
        meter.recordOutbound(frameBytes: 24)
        meter.recordInbound(frameBytes: 40, inflated: 120)

        XCTAssertEqual(meter.framesOut, 1)
        XCTAssertEqual(meter.framesIn, 1)
        XCTAssertEqual(meter.rawBytesOut, 24)
        XCTAssertEqual(meter.rawBytesIn, 40)
        XCTAssertEqual(meter.inflatedBytes, 120)
    }

    func testConnectCostIsExcludedFromTheHourlyRate() {
        let meter = ByteMeter()
        meter.recordConnect(bytes: 5_400)
        // The handshake is paid once per connection, so it must not inflate the
        // hourly projection in the status line.
        XCTAssertEqual(meter.bytesLastHour, 0)
        XCTAssertEqual(meter.connectBytes, 5_400)
    }

    func testIdleHeartbeatTrafficStaysUnderBudget() {
        let meter = ByteMeter()
        XCTAssertFalse(meter.isOverBudget)

        // ONE MINUTE of heartbeats, not an hour's worth.
        //
        // The measured interval is 41250 ms, so about 1.45 beats per minute.
        // An earlier version of this test recorded all 87 hourly beats, which
        // all landed in a single minute bucket; projectedPerHour then scaled
        // that minute by 60 and reported 1.55MB/hr. The projection was right
        // and the test was wrong.
        for _ in 0..<2 {
            meter.recordOutbound(frameBytes: 24)
            meter.recordInbound(frameBytes: 20, inflated: 18)
        }
        XCTAssertFalse(meter.isOverBudget,
                       "idle heartbeat traffic should not approach 1MB/hr")
        // Sanity-check the magnitude: ~4 frames/min of overhead-dominated
        // traffic should land in the tens of KB per hour.
        XCTAssertLessThan(meter.projectedPerHour, 100 * 1_024)
    }

    func testProjectionExtrapolatesFromAShortWindowOnPurpose() {
        // Documents the behaviour the test above tripped over. A single busy
        // minute is reported as if the hour continued that way, which is what
        // gives the status line early warning rather than a lagging average.
        let meter = ByteMeter()
        meter.recordInbound(frameBytes: 20_000, inflated: 60_000)
        XCTAssertGreaterThan(meter.projectedPerHour, 20_000 * 50,
                             "a short window must extrapolate, not average down")
    }

    func testShortFormatting() {
        XCTAssertEqual(ByteMeter.short(512), "512B")
        XCTAssertEqual(ByteMeter.short(2_048), "2.0K")
        XCTAssertEqual(ByteMeter.short(1_572_864), "1.5M")
    }
}

final class ByteMeterReclassifyTests: XCTestCase {

    func testReadySizedPayloadWouldOtherwiseBlowTheProjection() {
        let meter = ByteMeter()
        // One READY, as measured: 118.7KB on the wire.
        meter.recordInbound(frameBytes: 121_548, inflated: 860_000)
        XCTAssertTrue(meter.isOverBudget,
                      "a 119KB payload in one bucket should project over budget; "
                    + "if this fails the test no longer reproduces the bug")

        meter.reclassifyAsConnect(bytes: 121_548, isColdStart: true)
        XCTAssertFalse(meter.isOverBudget,
                       "after reclassifying, the hourly projection must exclude READY")
        // Not asserted as exactly zero: a multi-frame payload leaves a small
        // per-frame overhead residue by design. See reclassifyAsConnect.
        XCTAssertLessThan(meter.projectedPerHour, 1_024 * 1_024 / 20,
                          "the residue must be negligible against the budget")
        XCTAssertEqual(meter.coldStarts, 1)
    }

    func testReclassifyKeepsOrdinaryTrafficInTheRate() {
        let meter = ByteMeter()
        meter.recordInbound(frameBytes: 121_548, inflated: 860_000)  // READY
        meter.recordInbound(frameBytes: 600, inflated: 1_400)        // a DM
        meter.reclassifyAsConnect(bytes: 121_548, isColdStart: true)

        // The DM must survive. Reclassifying walks back from the newest bucket,
        // so an over-eager implementation would eat it.
        XCTAssertGreaterThan(meter.bytesLastHour, 0)
        XCTAssertLessThan(meter.bytesLastHour, 2_000)
    }

    func testReclassifyNeverDrivesABucketNegative() {
        let meter = ByteMeter()
        meter.recordInbound(frameBytes: 100, inflated: 200)
        // More than was ever counted. Must clamp, not wrap.
        meter.reclassifyAsConnect(bytes: 500_000, isColdStart: false)
        XCTAssertEqual(meter.bytesLastHour, 0)
        XCTAssertEqual(meter.coldStarts, 0)
    }

    func testResumeIsCountedSeparatelyFromColdStart() {
        let meter = ByteMeter()
        meter.recordResume()
        meter.recordResume()
        meter.reclassifyAsConnect(bytes: 1_000, isColdStart: true)
        XCTAssertEqual(meter.resumes, 2)
        XCTAssertEqual(meter.coldStarts, 1)
        // A resume skips READY, which is the whole point: 131KB saved.
        XCTAssertEqual(meter.connectBytes, 1_000)
    }

    func testConnectBytesAreNeverInTheHourlyRate() {
        let meter = ByteMeter()
        meter.recordConnect(bytes: 5_400)
        XCTAssertEqual(meter.bytesLastHour, 0)
        XCTAssertFalse(meter.isOverBudget)
    }
}
