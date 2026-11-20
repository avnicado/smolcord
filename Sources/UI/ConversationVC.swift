//
//  ConversationVC.swift
//
//  One conversation, plus a prompt.
//
//    < dms                              alice
//    ----------------------------------------
//    14:32 alice
//      hey, did you see the thing
//    14:33 you
//      [png 240K]  hold to copy url
//    > |
//
//  Attachments render as a marker and are never downloaded. Long-press a
//  marker row to copy its URL: the user decides whether a byte is worth it,
//  outside the app.
//

import UIKit

public final class ConversationVC: UIViewController {

    private let store: DMStore
    private let meter: ByteMeter
    private let channelID: String

    private let log = TermLogView()
    private let promptMark = TermView()
    private let input = UITextView()
    private var statusLine: StatusLine!

    /// Row index -> attachment URL, for long-press copying.
    private var rowURLs: [Int: String] = [:]
    /// The header row index, which pops back to the list.
    private var backRow = 0
    /// A transient notice appended under the log: a copied URL, a failed send.
    private var notice: TermLine?
    private var noticeTimer: Timer?

    private var bottomConstraint: NSLayoutConstraint?
    private var typingRefresh: Timer?
    private var lastRenderedColumns = 0

    public init(store: DMStore, meter: ByteMeter, channelID: String) {
        self.store = store
        self.meter = meter
        self.channelID = channelID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        typingRefresh?.invalidate()
        noticeTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = TermTheme.background

        statusLine = StatusLine(meter: meter, status: store.status)

        log.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(log)

        // The prompt sigil is drawn, not a label, so it sits on the grid.
        promptMark.translatesAutoresizingMaskIntoConstraints = false
        promptMark.lines = [TermLine("> ", color: TermTheme.prompt, bold: true)]
        promptMark.backgroundColor = .clear
        promptMark.isOpaque = false
        view.addSubview(promptMark)

        input.translatesAutoresizingMaskIntoConstraints = false
        input.backgroundColor = .clear
        input.textColor = TermTheme.foreground
        input.font = TermTheme.font
        input.autocorrectionType = .no
        input.autocapitalizationType = .sentences
        input.keyboardAppearance = .dark
        input.returnKeyType = .send
        input.enablesReturnKeyAutomatically = true
        input.delegate = self
        input.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        input.textContainer.lineFragmentPadding = 0
        view.addSubview(input)

        statusLine.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLine)

        let guide: UILayoutGuide
        if #available(iOS 11.0, *) { guide = view.safeAreaLayoutGuide } else { guide = view.layoutMarginsGuide }

        let bottom = statusLine.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        bottomConstraint = bottom

        NSLayoutConstraint.activate([
            log.topAnchor.constraint(equalTo: guide.topAnchor),
            log.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            log.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            log.bottomAnchor.constraint(equalTo: input.topAnchor),

            promptMark.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            promptMark.widthAnchor.constraint(equalToConstant: TermTheme.cellWidth * 2 + 6),
            promptMark.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            promptMark.heightAnchor.constraint(equalToConstant: TermTheme.cellHeight),

            input.leadingAnchor.constraint(equalTo: promptMark.trailingAnchor),
            input.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            input.bottomAnchor.constraint(equalTo: statusLine.topAnchor),
            // One row tall. A growing composer would push the log around on a
            // 4-inch screen, and a DM is usually one line.
            input.heightAnchor.constraint(equalToConstant: TermTheme.cellHeight + 8),

            statusLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusLine.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusLine.heightAnchor.constraint(equalToConstant: statusLine.intrinsicHeight),
            bottom,
        ])

        log.onTapLine = { [weak self] row in self?.handleTap(row: row) }
        log.onLongPressLine = { [weak self] row in self?.handleLongPress(row: row) }

        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)

        // Typing indicators expire on a timer, so the footer needs a nudge.
        typingRefresh = Timer.scheduledTimer(timeInterval: 2.0, target: self,
                                             selector: #selector(refreshFooter),
                                             userInfo: nil, repeats: true)

        // The only place history is ever fetched.
        store.openConversation(channelID: channelID)
        reload(scrollToBottom: true)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        store.onMessages = { [weak self] id in
            guard let self = self, id == self.channelID else { return }
            self.reload(scrollToBottom: true)
        }
        store.onStatusChanged = { [weak self] status in
            self?.statusLine.update(status: status)
        }
        store.onConversationsChanged = { [weak self] in self?.refreshFooter() }
        store.onSendFailed = { [weak self] id, message in
            guard let self = self, id == self.channelID else { return }
            self.show(notice: TermLine("send failed: " + message,
                                       color: TermTheme.warning))
        }
        statusLine.update(status: store.status)
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Deliberately does NOT clear the store's observers.
        //
        // The relative order of the incoming screen's viewWillAppear and the
        // outgoing screen's viewWillDisappear during a pop is not guaranteed
        // and has differed between iOS versions. Clearing here can therefore
        // wipe the claim ChannelListVC has just made, which is how the list's
        // status line froze.
        //
        // Instead, every screen claims all observers in its own
        // viewWillAppear. A closure left pointing at a popped controller is
        // harmless: they all capture self weakly, so it becomes a no-op.
        store.markRead(channelID: channelID)
    }

    public override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if lastRenderedColumns != log.columns { reload(scrollToBottom: false) }
    }

    // MARK: - Rendering

    private func reload(scrollToBottom: Bool) {
        let lines = store.lines(channelID: channelID)
        let columns = log.columns
        lastRenderedColumns = columns

        var out = [TermLine]()
        rowURLs.removeAll()

        // Back row. The nav bar is hidden, so this is the way out, and the
        // swipe-back gesture is re-enabled in AppDelegate as a second route.
        let convo = store.conversations().first { $0.id == channelID }
        let title = convo?.title ?? channelID
        let back = "< dms"
        let room = max(1, columns - back.count - 1)
        var shownTitle = title
        if shownTitle.count > room {
            shownTitle = String(shownTitle.prefix(max(1, room - 1))) + "~"
        }
        let gap = max(1, columns - back.count - shownTitle.count)
        out.append(TermLine([
            TermRun(back, color: TermTheme.accent, bold: true),
            TermRun(String(repeating: " ", count: gap), color: .white),
            TermRun(shownTitle, color: TermColor.brightWhite, bold: true),
        ]))
        backRow = 0
        out.append(TermLine(String(repeating: "-", count: max(10, columns)),
                            color: TermTheme.dim))

        if lines.isEmpty {
            out.append(TermLine.blank)
            out.append(TermLine("no messages in the cache.", color: TermTheme.dim))
        }

        var lastAuthor = ""
        for line in lines {
            // Collapse the header when the same person speaks twice in a row.
            // Vertical space is the scarce resource on a 4-inch screen.
            if line.authorName != lastAuthor {
                let who = line.isFromSelf ? "you" : line.authorName
                out.append(TermLine([
                    TermRun(line.timeText.isEmpty ? "--:--" : line.timeText,
                            color: TermTheme.dim),
                    TermRun(" ", color: .white),
                    TermRun(who,
                            color: line.isFromSelf ? TermTheme.selfAuthor : TermTheme.otherAuthor,
                            bold: true),
                    TermRun(line.isPending ? "  (sending)" : "", color: TermTheme.dim),
                ]))
                lastAuthor = line.authorName
            }

            if !line.content.isEmpty {
                for wrapped in TermView.wrap(line.content, columns: max(8, columns - 2)) {
                    out.append(TermLine("  " + wrapped,
                                        color: line.isPending ? TermTheme.dim : TermColor.white))
                }
            }

            // Attachments: a marker, never a download.
            for (i, marker) in line.attachmentMarkers.enumerated() {
                out.append(TermLine([
                    TermRun("  ", color: .white),
                    TermRun(marker, color: TermTheme.attachment, bold: true),
                    TermRun("  hold to copy url", color: TermTheme.dim),
                ]))
                if i < line.attachmentURLs.count {
                    rowURLs[out.count - 1] = line.attachmentURLs[i]
                }
            }

            if line.embedCount > 0 {
                let plural = line.embedCount == 1 ? "" : "s"
                out.append(TermLine("  [\(line.embedCount) embed\(plural) not loaded]",
                                    color: TermTheme.dim))
            }
        }

        let names = store.typingNames(channelID: channelID)
        if !names.isEmpty {
            let who = names.count == 1 ? names[0] : "\(names.count) people"
            out.append(TermLine("\(who) is typing...", color: TermTheme.accent))
        }
        if let notice = notice {
            out.append(notice)
        }

        log.lines = out
        if scrollToBottom { log.scrollToBottom() }
    }

    @objc private func refreshFooter() {
        // Typing state and the notice live at the end of the log, so a full
        // rebuild is the simplest correct thing. The table recycles rows, so
        // this is cheap even on an A7.
        reload(scrollToBottom: false)
    }

    private func show(notice line: TermLine) {
        notice = line
        reload(scrollToBottom: true)
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(timeInterval: 4.0, target: self,
                                           selector: #selector(clearNotice),
                                           userInfo: nil, repeats: false)
    }

    @objc private func clearNotice() {
        notice = nil
        reload(scrollToBottom: false)
    }

    // MARK: - Interaction

    private func handleTap(row: Int) {
        if row == backRow {
            navigationController?.popViewController(animated: false)
        }
    }

    private func handleLongPress(row: Int) {
        guard let url = rowURLs[row] else { return }
        UIPasteboard.general.string = url
        show(notice: TermLine("url copied to clipboard.", color: TermColor.brightGreen))
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                            as? NSValue)?.cgRectValue else { return }
        let overlap = max(0, view.bounds.height - view.convert(frame, from: nil).minY)
        var inset = overlap
        if #available(iOS 11.0, *) { inset = max(0, overlap - view.safeAreaInsets.bottom) }
        bottomConstraint?.constant = -inset
        view.layoutIfNeeded()
        log.scrollToBottom()
    }
}

extension ConversationVC: UITextViewDelegate {
    public func textView(_ textView: UITextView,
                         shouldChangeTextIn range: NSRange,
                         replacementText text: String) -> Bool {
        guard text == "\n" else { return true }
        let content = textView.text ?? ""
        textView.text = ""
        store.send(channelID: channelID, content: content)
        return false
    }
}
