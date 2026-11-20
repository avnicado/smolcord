//
//  TermLogView.swift
//
//  A scrolling terminal log of arbitrary length.
//
//  Why a UITableView rather than one tall custom view:
//
//  The obvious implementation is a single view as tall as the whole log inside
//  a UIScrollView, drawing every visible row in one pass. That works on a
//  modern device and fails on the ones this app targets. A conversation of 200
//  wrapped messages is a few thousand points tall; at 2x on an A7 or A8 the
//  backing layer exceeds the GPU's maximum texture size, and the view renders
//  blank or exhausts memory. iOS gives no warning when this happens.
//
//  A table view solves it the boring way: one recycled view per row, nothing
//  larger than the viewport ever rasterised. Rows are a fixed height, so there
//  is no layout pass per row and scrolling stays cheap on old hardware.
//
//  Each row still draws itself with drawTermLine, so the rendering is identical
//  to TermView's.
//

import UIKit

/// One row. Draws a single TermLine and nothing else.
final class TermLineView: UIView {

    var line = TermLine.blank {
        didSet { setNeedsDisplay() }
    }
    var highlighted = false {
        didSet { setNeedsDisplay() }
    }
    var leftInset: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = TermTheme.background
        isOpaque = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(TermTheme.background.cgColor)
        ctx.fill(rect)
        drawTermLine(line,
                     at: CGPoint(x: leftInset, y: 0),
                     rowHeight: bounds.height,
                     width: bounds.width,
                     highlighted: highlighted,
                     in: ctx)
    }
}

final class TermLineCell: UITableViewCell {

    static let reuseID = "term.line"

    let lineView = TermLineView(frame: .zero)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = TermTheme.background
        contentView.backgroundColor = TermTheme.background
        selectionStyle = .none
        lineView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(lineView)
        NSLayoutConstraint.activate([
            lineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            lineView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            lineView.topAnchor.constraint(equalTo: contentView.topAnchor),
            lineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

public final class TermLogView: UIView {

    /// The whole log. Assigning reloads; the table recycles rows itself.
    public var lines: [TermLine] = [] {
        didSet { table.reloadData() }
    }

    /// Row index to draw in inverse video, or nil.
    public var highlightedRow: Int? {
        didSet { table.reloadData() }
    }

    public var onTapLine: ((Int) -> Void)?
    public var onLongPressLine: ((Int) -> Void)?

    private let table = UITableView(frame: .zero, style: .plain)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    private func commonInit() {
        backgroundColor = TermTheme.background

        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = TermTheme.background
        table.separatorStyle = .none
        table.indicatorStyle = .white
        table.rowHeight = TermTheme.cellHeight
        // A fixed row height lets the table skip the estimated-height pass
        // entirely, which is the expensive part on an A7.
        table.estimatedRowHeight = 0
        table.dataSource = self
        table.delegate = self
        table.register(TermLineCell.self, forCellReuseIdentifier: TermLineCell.reuseID)
        table.alwaysBounceVertical = true
        table.allowsSelection = true
        table.tableFooterView = UIView()
        if #available(iOS 11.0, *) {
            table.contentInsetAdjustmentBehavior = .never
        }
        addSubview(table)
        NSLayoutConstraint.activate([
            table.leadingAnchor.constraint(equalTo: leadingAnchor),
            table.trailingAnchor.constraint(equalTo: trailingAnchor),
            table.topAnchor.constraint(equalTo: topAnchor),
            table.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let long = UILongPressGestureRecognizer(target: self,
                                                action: #selector(handleLongPress(_:)))
        table.addGestureRecognizer(long)
    }

    /// Columns of text that fit at the current width.
    public var columns: Int {
        // 6pt of inset on each side, matching TermLineView.leftInset.
        return TermTheme.columns(for: max(bounds.width - 12, 200))
    }

    public func scrollToBottom(animated: Bool = false) {
        guard !lines.isEmpty else { return }
        let last = IndexPath(row: lines.count - 1, section: 0)
        table.scrollToRow(at: last, at: .bottom, animated: animated)
    }

    /// Append without reloading the whole table. Used for transient notices.
    public func append(_ line: TermLine, scroll: Bool = true) {
        lines.append(line)
        if scroll { scrollToBottom() }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: table)
        guard let indexPath = table.indexPathForRow(at: point) else { return }
        onLongPressLine?(indexPath.row)
    }
}

extension TermLogView: UITableViewDataSource, UITableViewDelegate {

    public func tableView(_ tableView: UITableView,
                          numberOfRowsInSection section: Int) -> Int {
        return lines.count
    }

    public func tableView(_ tableView: UITableView,
                          cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: TermLineCell.reuseID, for: indexPath)
        guard let termCell = cell as? TermLineCell else { return cell }
        // Guard the index: reloadData and a pending layout pass can race when
        // `lines` shrinks, and an out-of-range read would crash.
        termCell.lineView.line = indexPath.row < lines.count
            ? lines[indexPath.row]
            : TermLine.blank
        termCell.lineView.highlighted = (indexPath.row == highlightedRow)
        return termCell
    }

    public func tableView(_ tableView: UITableView,
                          didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        onTapLine?(indexPath.row)
    }
}
