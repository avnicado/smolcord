//
//  TextWrap.swift
//
//  Terminal line wrapping. Pure string arithmetic, no UIKit.
//
//  Separate from TermView for one reason: it is the only part of the rendering
//  path that can be tested off an Apple platform. UIKit does not exist on
//  Linux, so anything importing it is unverifiable until CI or a Mac runs. This
//  file is not, so a local `swift test` covers it.
//

import Foundation

/// Wrap text to a column count, breaking on spaces where possible.
///
/// - Parameter hangingIndent: spaces prefixed to continuation lines, so a
///   wrapped message still reads as one block in a dense log.
public func wrapTerminalText(_ text: String,
                             columns: Int,
                             hangingIndent: Int = 0) -> [String] {
    guard columns > 4 else { return [text] }
    var out = [String]()

    for paragraph in text.components(separatedBy: "\n") {
        if paragraph.isEmpty {
            out.append("")
            continue
        }
        var line = ""
        var limit = columns
        let indent = String(repeating: " ", count: hangingIndent)

        for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
            let candidate = line.isEmpty ? String(word) : line + " " + word
            if candidate.count <= limit {
                line = candidate
                continue
            }
            if !line.isEmpty {
                out.append(line)
                limit = columns - hangingIndent
                line = indent + String(word)
            } else {
                line = String(word)
            }
            // A single word longer than the row: hard-break it rather than let
            // it run off the edge.
            while line.count > limit {
                let cut = line.index(line.startIndex, offsetBy: limit)
                out.append(String(line[..<cut]))
                line = indent + String(line[cut...])
            }
        }
        if !line.isEmpty { out.append(line) }
    }
    return out.isEmpty ? [""] : out
}

/// ISO 8601 to "14:32".
///
/// Parsed by hand rather than with DateFormatter. A formatter allocation per
/// message is measurable on an iPhone 5s, and the only thing needed is two
/// fields at fixed offsets.
///
/// Returns "" for anything that does not look like a timestamp.
public func shortClockTime(fromISO8601 iso: String) -> String {
    guard let tIndex = iso.firstIndex(of: "T") else { return "" }
    let after = iso.index(after: tIndex)
    let rest = iso[after...]
    let clock = String(rest.prefix(5))
    // "14:32" and nothing else. A truncated timestamp must not render as junk.
    guard clock.count == 5, clock[clock.index(clock.startIndex, offsetBy: 2)] == ":" else {
        return ""
    }
    return clock
}
