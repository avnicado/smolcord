//
//  ZlibInflater.swift
//
//  Discord's `zlib-stream` transport compression.
//
//  How the wire format works:
//
//    * One inflate context lives for the whole connection. Later messages are
//      compressed against the dictionary built by earlier ones, so a fresh
//      context per message would produce garbage. This is also why idle
//      traffic is so cheap: repeated JSON structure compresses to almost
//      nothing after the first few messages.
//    * The stream is never closed. Each gateway message ends with a
//      Z_SYNC_FLUSH marker, the four bytes 00 00 FF FF. Buffer compressed
//      bytes until that suffix lands, then inflate.
//    * A single gateway message can span several WebSocket frames, and a
//      single frame can be a fragment. Only the suffix marks a boundary.
//
//  Apple's Compression framework is deliberately not used here. Its raw
//  DEFLATE mode has no documented handling of an empty stored block at a
//  partial-flush boundary, which is exactly what Z_SYNC_FLUSH emits. System
//  zlib is on the device, is the reference implementation, and costs one
//  bridging header.
//

import Foundation

// On Apple platforms zlib arrives through the bridging header named in
// project.yml. Under SwiftPM it arrives as a system-library module instead.
#if canImport(CZlib)
import CZlib
#endif

public final class ZlibInflater {

    public enum InflateError: Error, CustomStringConvertible {
        case initFailed(Int32)
        case corrupt(Int32)
        case bufferLimitExceeded(Int)

        public var description: String {
            switch self {
            case .initFailed(let c):  return "inflateInit2 failed (\(c))"
            case .corrupt(let c):     return "inflate failed (\(c))"
            case .bufferLimitExceeded(let n):
                return "compressed buffer exceeded \(n) bytes without a flush marker"
            }
        }
    }

    /// A completed gateway message.
    public struct Message {
        /// The inflated JSON bytes.
        public let data: Data
        /// On-wire compressed length, so the caller can attribute cost to the
        /// specific event this message carried.
        public let compressedLength: Int
    }

    private static let syncFlushSuffix: [UInt8] = [0x00, 0x00, 0xFF, 0xFF]

    /// A READY payload on a large account is the biggest thing the gateway
    /// sends. 8 MB compressed is far past anything legitimate, so hitting this
    /// means the stream desynchronised and we should reconnect rather than
    /// keep allocating.
    private static let maxCompressedBuffer = 8 * 1_024 * 1_024

    private var stream = z_stream()
    private var buffer = [UInt8]()
    private var outBuffer: [UInt8]
    private var initialised = false

    /// - Parameter outputChunk: inflate scratch size. 64 KB handles ordinary
    ///   events in one pass; READY loops.
    public init(outputChunk: Int = 64 * 1_024) throws {
        outBuffer = [UInt8](repeating: 0, count: outputChunk)
        let rc = smol_inflate_init(&stream)
        guard rc == Z_OK else { throw InflateError.initFailed(rc) }
        initialised = true
        buffer.reserveCapacity(16 * 1_024)
    }

    deinit {
        if initialised { inflateEnd(&stream) }
    }

    /// Feed bytes from one WebSocket frame.
    ///
    /// Returns nil while the gateway message is incomplete. Returns a Message
    /// once the Z_SYNC_FLUSH marker arrives.
    public func feed(_ bytes: Data) throws -> Message? {
        buffer.append(contentsOf: bytes)

        guard buffer.count >= 4 else { return nil }
        guard buffer.count <= ZlibInflater.maxCompressedBuffer else {
            throw InflateError.bufferLimitExceeded(ZlibInflater.maxCompressedBuffer)
        }
        // Boundary check: the last four bytes must be the flush marker.
        let tail = buffer.count - 4
        guard buffer[tail] == 0x00, buffer[tail + 1] == 0x00,
              buffer[tail + 2] == 0xFF, buffer[tail + 3] == 0xFF else {
            return nil
        }

        let compressedLength = buffer.count
        var out = Data()
        out.reserveCapacity(compressedLength * 3)

        try buffer.withUnsafeMutableBufferPointer { inPtr -> Void in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inPtr.count)

            repeat {
                let rc: Int32 = outBuffer.withUnsafeMutableBufferPointer { outPtr -> Int32 in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(outPtr.count)
                    let r = inflate(&stream, Z_SYNC_FLUSH)
                    let produced = outPtr.count - Int(stream.avail_out)
                    if produced > 0 {
                        out.append(contentsOf: UnsafeBufferPointer(
                            start: outPtr.baseAddress, count: produced))
                    }
                    return r
                }
                // Z_OK means "made progress"; Z_BUF_ERROR at a flush boundary
                // with no input left is the normal end of a message.
                if rc == Z_BUF_ERROR && stream.avail_in == 0 { break }
                guard rc == Z_OK || rc == Z_STREAM_END else {
                    throw InflateError.corrupt(rc)
                }
                if rc == Z_STREAM_END { break }
            } while stream.avail_in > 0
        }

        buffer.removeAll(keepingCapacity: true)
        stream.next_in = nil
        stream.avail_in = 0
        stream.next_out = nil
        stream.avail_out = 0

        return Message(data: out, compressedLength: compressedLength)
    }

    /// Bytes buffered but not yet inflated. Non-zero means a message is still
    /// arriving.
    public var pendingBytes: Int { return buffer.count }
}
