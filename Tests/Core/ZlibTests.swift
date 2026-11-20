//
//  ZlibTests.swift
//
//  Part of the portable test suite: everything here compiles and runs on Linux
//  via Package.swift, as well as in the Xcode test target. Nothing in this
//  directory may import UIKit, Network or Security.
//
//  Run locally:  swift test
//

import XCTest
#if canImport(CZlib)
import CZlib
#endif
@testable import smolcord

final class ZlibInflaterTests: XCTestCase {

    /// Build a zlib-stream blob the way Discord does: deflate, then flush with
    /// Z_SYNC_FLUSH so the message ends in 00 00 FF FF.
    private func deflateChunk(_ payload: Data,
                              stream: inout z_stream,
                              first: Bool) -> Data {
        if first {
            deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15, 8,
                          Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                          Int32(MemoryLayout<z_stream>.size))
        }
        var out = Data()
        var input = [UInt8](payload)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        input.withUnsafeMutableBufferPointer { inPtr in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inPtr.count)
            repeat {
                buffer.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(outPtr.count)
                    _ = deflate(&stream, Z_SYNC_FLUSH)
                    let produced = outPtr.count - Int(stream.avail_out)
                    if produced > 0 {
                        out.append(contentsOf: UnsafeBufferPointer(
                            start: outPtr.baseAddress, count: produced))
                    }
                }
            } while stream.avail_out == 0
        }
        return out
    }

    func testSingleMessageInflates() throws {
        var deflater = z_stream()
        let payload = Data("{\"op\":11,\"d\":null}".utf8)
        let blob = deflateChunk(payload, stream: &deflater, first: true)

        // The flush marker must be present, or the inflater keeps waiting.
        XCTAssertEqual(Array(blob.suffix(4)), [0x00, 0x00, 0xFF, 0xFF],
                       "deflate did not emit a Z_SYNC_FLUSH boundary")

        let inflater = try ZlibInflater()
        let message = try inflater.feed(blob)
        XCTAssertNotNil(message)
        XCTAssertEqual(message?.data, payload)
        XCTAssertEqual(message?.compressedLength, blob.count)
        deflateEnd(&deflater)
    }

    func testPartialFeedBuffersUntilMarker() throws {
        var deflater = z_stream()
        let payload = Data(repeating: 0x78, count: 5000)
        let blob = deflateChunk(payload, stream: &deflater, first: true)

        let inflater = try ZlibInflater()
        let half = blob.count / 2
        // A gateway message split across two WebSocket frames must not inflate
        // early. Doing so desynchronises the shared context.
        XCTAssertNil(try inflater.feed(blob.prefix(half)))
        XCTAssertGreaterThan(inflater.pendingBytes, 0)

        let message = try inflater.feed(blob.suffix(from: half))
        XCTAssertEqual(message?.data, payload)
        XCTAssertEqual(message?.compressedLength, blob.count)
        XCTAssertEqual(inflater.pendingBytes, 0)
        deflateEnd(&deflater)
    }

    func testSharedContextAcrossMessages() throws {
        var deflater = z_stream()
        let inflater = try ZlibInflater()
        var sizes = [Int]()
        var first = true

        // Repeated structure must get cheaper. If each message were inflated
        // against a fresh context this would fail outright.
        for i in 1...4 {
            let payload = Data("{\"t\":\"TYPING_START\",\"d\":{\"user_id\":\"\(i)\"}}".utf8)
            let blob = deflateChunk(payload, stream: &deflater, first: first)
            first = false
            let message = try inflater.feed(blob)
            XCTAssertEqual(message?.data, payload, "message \(i) did not round-trip")
            sizes.append(blob.count)
        }
        XCTAssertLessThan(sizes[3], sizes[0],
                          "shared deflate context is not reducing size: \(sizes)")
        deflateEnd(&deflater)
    }
}
