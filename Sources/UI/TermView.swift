//
//  TermView.swift
//
//  A character-grid renderer.
//
//  Why not a stack of UILabels: a DM log is hundreds of short lines that change
//  constantly. Creating and laying out a label per line churns the view
//  hierarchy and drops frames on an iPhone 5s. This draws every visible line in
//  one CGContext pass, with no subviews at all.
//
//  Text is held as styled runs rather than per-character cells. A true cell
//  buffer is the more faithful terminal model, but drawing glyph by glyph costs
//  far more than drawing a run, and nothing here needs per-cell addressing.
//

import UIKit

/// One styled span of text within a line.
public struct TermRun {
    public let text: String
    public let color: TermColor
    public let bold: Bool
    /// Inverse video. Used for the selected row and the cursor.
    public let reverse: Bool

    public init(_ text: String,
                color: TermColor = .white,
                bold: Bool = false,
                reverse: Bool = false) {
        self.text = text
        self.color = color
        self.bold = bold
        self.reverse = reverse
    }
}

public struct TermLine {
    public var runs: [TermRun]
    public init(_ runs: [TermRun]) { self.runs = runs }
    public init(_ text: String, color: TermColor = .white, bold: Bool = false) {
        self.runs = [TermRun(text, color: color, bold: bold)]
    }
    public static let blank = TermLine([])

    var plainText: String {
        return runs.map { $0.text }.joined()
    }
}

/// Draws one styled line into a context. Shared by `TermView`, which handles
/// small bounded content, and `TermLineView`, which is one row of `TermLogView`.
///
/// Kept as a free function rather than a method so neither view owns it.
func drawTermLine(_ line: TermLine,
                  at origin: CGPoint,
                  rowHeight: CGFloat,
                  width: CGFloat,
                  highlighted: Bool,
                  in ctx: CGContext) {
    if highlighted {
        ctx.setFillColor(TermTheme.foreground.cgColor)
        ctx.fill(CGRect(x: 0, y: origin.y, width: width, height: rowHeight))
    }

    var x = origin.x
    for run in line.runs {
        guard !run.text.isEmpty else { continue }
        let font = run.bold ? TermTheme.boldFont : TermTheme.font
        // XOR: a reverse run inside a highlighted row cancels out.
        let inverse = run.reverse != highlighted

        let fg: UIColor
        if inverse {
            ctx.setFillColor(run.color.uiColor.cgColor)
            let runWidth = CGFloat(run.text.count) * TermTheme.cellWidth
            ctx.fill(CGRect(x: x, y: origin.y, width: runWidth, height: rowHeight))
            fg = TermTheme.background
        } else {
            fg = run.color.uiColor
        }

        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
        let ns = run.text as NSString
        // Centre the glyphs in the row box.
        let textY = origin.y + (rowHeight - font.lineHeight) / 2.0
        ns.draw(at: CGPoint(x: x, y: textY), withAttributes: attrs)
        x += CGFloat(run.text.count) * TermTheme.cellWidth
    }
}

/// A grid of styled lines drawn in one pass.
///
/// Use this ONLY for content with a small, known upper bound: the status line,
/// a login header, a few rows. It is a single view as tall as its content, so
/// a long log would create a layer taller than the GPU's maximum texture size
/// on A7 and A8 devices, which renders blank or exhausts memory.
///
/// For an unbounded log use `TermLogView`, which recycles one view per row.
public final class TermView: UIView {

    public var lines: [TermLine] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    /// Row index drawn in inverse video, or nil.
    public var highlightedRow: Int? {
        didSet { setNeedsDisplay() }
    }

    public var rowHeight: CGFloat { return TermTheme.cellHeight }

    /// Inset so text does not touch the bezel.
    public var contentInsets = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = TermTheme.background
        isOpaque = true
        // The grid is redrawn wholesale on change; caching a stale bitmap would
        // only add a copy.
        layer.drawsAsynchronously = false
        contentMode = .redraw
    }

    public override var intrinsicContentSize: CGSize {
        let height = CGFloat(lines.count) * rowHeight + contentInsets.top + contentInsets.bottom
        return CGSize(width: UIView.noIntrinsicMetric, height: max(height, rowHeight))
    }

    /// Columns available for text at the current width.
    public var columns: Int {
        let usable = bounds.width - contentInsets.left - contentInsets.right
        return TermTheme.columns(for: usable)
    }

    public override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        ctx.setFillColor(TermTheme.background.cgColor)
        ctx.fill(rect)

        // Draw only the rows intersecting the dirty rect. Scrolling a long log
        // then costs the same as scrolling a short one.
        let first = max(0, Int((rect.minY - contentInsets.top) / rowHeight))
        let last = min(lines.count - 1,
                       Int((rect.maxY - contentInsets.top) / rowHeight) + 1)
        guard first <= last else { return }

        for row in first...last {
            drawLine(lines[row], row: row, in: ctx)
        }
    }

    private func drawLine(_ line: TermLine, row: Int, in ctx: CGContext) {
        drawTermLine(line,
                     at: CGPoint(x: contentInsets.left,
                                 y: contentInsets.top + CGFloat(row) * rowHeight),
                     rowHeight: rowHeight,
                     width: bounds.width,
                     highlighted: row == highlightedRow,
                     in: ctx)
    }

    /// Row index at a point, for tap handling.
    public func row(at point: CGPoint) -> Int? {
        let index = Int((point.y - contentInsets.top) / rowHeight)
        guard index >= 0, index < lines.count else { return nil }
        return index
    }

    // MARK: - Wrapping

    /// Wrap text to a column count. Delegates to `wrapTerminalText`, which
    /// lives in Sources/Support so it can be tested without UIKit.
    public static func wrap(_ text: String,
                            columns: Int,
                            hangingIndent: Int = 0) -> [String] {
        return wrapTerminalText(text, columns: columns, hangingIndent: hangingIndent)
    }
}
