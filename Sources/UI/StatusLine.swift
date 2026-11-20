//
//  StatusLine.swift
//
//  The tmux-style bar pinned to the bottom of every screen.
//
//    [smolcord] ok  v42.1K ^3.2K  18.6K/hr  3 dm
//
//  The live data rate is here, on screen, at all times. That is not a debug
//  affordance. Staying under 1 MB/hr is the only reason this app exists instead
//  of the official client, so the number the user is buying belongs in front of
//  them. It turns red over budget.
//

import UIKit

public final class StatusLine: UIView {

    private let term = TermView()
    private var timer: Timer?

    private let meter: ByteMeter
    private var status: Gateway.Status = .offline
    private var unreadConversations = 0

    /// - Parameter status: the connection's current status. Gateway only fires
    ///   on a change, so a status line created while already connected would
    ///   otherwise read `off` until the next transition.
    public init(meter: ByteMeter, status: Gateway.Status = .offline) {
        self.meter = meter
        self.status = status
        super.init(frame: .zero)

        backgroundColor = TermColor.brightBlack.uiColor.withAlphaComponent(0.25)
        term.backgroundColor = .clear
        term.isOpaque = false
        term.contentInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        term.translatesAutoresizingMaskIntoConstraints = false
        addSubview(term)
        NSLayoutConstraint.activate([
            term.leadingAnchor.constraint(equalTo: leadingAnchor),
            term.trailingAnchor.constraint(equalTo: trailingAnchor),
            term.topAnchor.constraint(equalTo: topAnchor),
            term.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // One repaint a second is enough for a rate display, and it keeps the
        // meter's own change callback from driving the UI on every frame.
        timer = Timer.scheduledTimer(timeInterval: 1.0, target: self,
                                     selector: #selector(refresh),
                                     userInfo: nil, repeats: true)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { timer?.invalidate() }

    public var intrinsicHeight: CGFloat { return TermTheme.cellHeight + 4 }

    public override var intrinsicContentSize: CGSize {
        return CGSize(width: UIView.noIntrinsicMetric, height: intrinsicHeight)
    }

    public func update(status: Gateway.Status) {
        self.status = status
        refresh()
    }

    public func update(unreadConversations: Int) {
        self.unreadConversations = unreadConversations
        refresh()
    }

    @objc private func refresh() {
        let rate = meter.projectedPerHour
        let over = meter.isOverBudget

        let statusColor: TermColor
        switch status {
        case .ready:                 statusColor = .green
        case .connecting, .identifying, .resuming: statusColor = .yellow
        case .backoff:               statusColor = .yellow
        case .fatal:                 statusColor = .brightRed
        case .offline:               statusColor = .brightBlack
        }

        var runs = [
            TermRun("[smolcord] ", color: TermTheme.accent, bold: true),
            TermRun(status.terminalLabel, color: statusColor, bold: true),
            TermRun("  ", color: .white),
            TermRun("v" + ByteMeter.short(meter.rawBytesIn), color: TermTheme.dim),
            TermRun(" ^" + ByteMeter.short(meter.rawBytesOut), color: TermTheme.dim),
            TermRun("  ", color: .white),
            TermRun(ByteMeter.short(rate) + "/hr",
                    color: over ? TermTheme.warning : TermColor.brightGreen,
                    bold: over),
        ]
        if unreadConversations > 0 {
            runs.append(TermRun("  \(unreadConversations) dm", color: TermTheme.unread))
        }
        // A cold start measured 131KB against a 1MB/hr budget, so the count of
        // them matters more than the steady rate. Show it once there is one.
        if meter.coldStarts > 0 || meter.resumes > 0 {
            runs.append(TermRun("  c\(meter.coldStarts)", color: TermTheme.warning))
            runs.append(TermRun("/r\(meter.resumes)", color: TermColor.green))
        }
        if case .backoff(let delay) = status {
            runs.append(TermRun("  retry \(Int(delay))s", color: .yellow))
        }
        term.lines = [TermLine(runs)]
    }
}
