//
//  ChannelListVC.swift
//
//  The DM list, rendered as terminal rows:
//
//    direct messages  (3)
//    ----------------------------------
//    [ 1] * alice                     3
//           see you tomorrow
//    [ 2]   bob, carol           typing
//    [ 3]   dave
//
//    :sign out
//
//  An index in brackets, a presence dot, the name, and an unread count on the
//  right. No avatars. The absence of avatars is the product.
//

import UIKit

public final class ChannelListVC: UIViewController {

    private let store: DMStore
    private let meter: ByteMeter
    private let log = TermLogView()
    private var statusLine: StatusLine!

    private var conversations: [DMStore.Conversation] = []

    /// What a drawn row does when tapped. Header and spacer rows are absent.
    private enum RowAction {
        case open(String)
        case signOut
    }
    private var rowActions: [Int: RowAction] = [:]

    public init(store: DMStore, meter: ByteMeter) {
        self.store = store
        self.meter = meter
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = TermTheme.background
        title = "dms"

        statusLine = StatusLine(meter: meter, status: store.status)

        log.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(log)

        statusLine.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLine)

        let guide: UILayoutGuide
        if #available(iOS 11.0, *) { guide = view.safeAreaLayoutGuide } else { guide = view.layoutMarginsGuide }

        NSLayoutConstraint.activate([
            log.topAnchor.constraint(equalTo: guide.topAnchor),
            log.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            log.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            log.bottomAnchor.constraint(equalTo: statusLine.topAnchor),

            statusLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusLine.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusLine.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            statusLine.heightAnchor.constraint(equalToConstant: statusLine.intrinsicHeight),
        ])

        log.onTapLine = { [weak self] row in self?.handleTap(row: row) }
    }

    /// Observers are claimed here, not in viewDidLoad. They are single closures
    /// and ConversationVC takes them while it is on top, so the visible screen
    /// has to reclaim all of them on the way back.
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        store.onConversationsChanged = { [weak self] in self?.reload() }
        store.onStatusChanged = { [weak self] status in
            self?.statusLine.update(status: status)
        }
        store.onFatal = { [weak self] message in self?.showFatal(message) }
        store.onMessages = { [weak self] _ in self?.reload() }
        store.onSendFailed = nil

        statusLine.update(status: store.status)
        reload()
    }

    public override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Column count depends on width, so a rotation or a split-view resize
        // needs the rows laid out again.
        if lastRenderedColumns != log.columns { reload() }
    }
    private var lastRenderedColumns = 0

    // MARK: - Rendering

    private func reload() {
        conversations = store.conversations()
        rowActions.removeAll()
        let columns = log.columns
        lastRenderedColumns = columns

        var lines = [TermLine]()

        lines.append(TermLine([
            TermRun("direct messages", color: TermTheme.accent, bold: true),
            TermRun("  (\(conversations.count))", color: TermTheme.dim),
        ]))
        lines.append(TermLine(String(repeating: "-", count: max(10, columns)),
                              color: TermTheme.dim))

        if conversations.isEmpty {
            lines.append(TermLine.blank)
            switch store.status {
            case .ready:
                lines.append(TermLine("no conversations.", color: TermTheme.dim))
            case .fatal(let message):
                lines.append(TermLine("not connected:", color: TermTheme.warning))
                for wrapped in TermView.wrap(message, columns: columns) {
                    lines.append(TermLine(wrapped, color: TermTheme.warning))
                }
            default:
                lines.append(TermLine("connecting...", color: TermTheme.dim))
            }
        }

        var unreadTotal = 0
        for (i, convo) in conversations.enumerated() {
            if convo.unreadCount > 0 { unreadTotal += 1 }

            let index = String(format: "[%2d]", i + 1)
            let dot = convo.isOnline ? "*" : " "
            let dotColor = convo.isOnline ? TermTheme.online : TermTheme.offline

            // Typing beats an unread count in the right-hand column.
            let right: String
            let rightColor: TermColor
            if !convo.typingUserNames.isEmpty {
                right = "typing"
                rightColor = TermTheme.accent
            } else if convo.unreadCount > 0 {
                right = String(convo.unreadCount)
                rightColor = TermTheme.unread
            } else {
                right = ""
                rightColor = TermTheme.dim
            }

            // Lay the row out on the grid: index, dot, name, padding, right.
            let fixed = index.count + 1 + dot.count + 1 + right.count + 1
            let nameRoom = max(6, columns - fixed)
            var name = convo.title
            if name.count > nameRoom {
                name = String(name.prefix(max(1, nameRoom - 1))) + "~"
            }
            let pad = max(1, columns - fixed - name.count)

            lines.append(TermLine([
                TermRun(index, color: TermTheme.dim),
                TermRun(" ", color: .white),
                TermRun(dot, color: dotColor, bold: true),
                TermRun(" ", color: .white),
                TermRun(name,
                        color: convo.unreadCount > 0 ? TermColor.brightWhite : TermColor.white,
                        bold: convo.unreadCount > 0),
                TermRun(String(repeating: " ", count: pad), color: .white),
                TermRun(right, color: rightColor, bold: !right.isEmpty),
            ]))
            rowActions[lines.count - 1] = .open(convo.id)

            if !convo.lastMessagePreview.isEmpty {
                let preview = TermView.wrap(convo.lastMessagePreview,
                                            columns: max(10, columns - 7)).first ?? ""
                lines.append(TermLine("       " + preview, color: TermTheme.dim))
                rowActions[lines.count - 1] = .open(convo.id)
            }
        }

        // The only command in the app. Rendered as a prompt line so it reads
        // as a command rather than a button.
        lines.append(TermLine.blank)
        lines.append(TermLine([
            TermRun(":", color: TermTheme.prompt, bold: true),
            TermRun("sign out", color: TermTheme.dim),
        ]))
        rowActions[lines.count - 1] = .signOut

        log.lines = lines
        statusLine.update(unreadConversations: unreadTotal)
    }

    // MARK: - Interaction

    private func handleTap(row: Int) {
        guard let action = rowActions[row] else { return }
        switch action {
        case .open(let channelID):
            let vc = ConversationVC(store: store, meter: meter, channelID: channelID)
            navigationController?.pushViewController(vc, animated: false)
        case .signOut:
            confirmSignOut()
        }
    }

    private func confirmSignOut() {
        let alert = UIAlertController(
            title: "sign out",
            message: "this deletes the token from the keychain and wipes the "
                   + "local message cache.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "sign out", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.store.signOut()
            let login = LoginVC(store: self.store)
            login.onSignedIn = { [weak self] in
                guard let self = self else { return }
                self.navigationController?.setViewControllers(
                    [ChannelListVC(store: self.store, meter: self.meter)],
                    animated: false)
            }
            self.navigationController?.setViewControllers([login], animated: false)
        })
        present(alert, animated: false)
    }

    private func showFatal(_ message: String) {
        // Only reached for an unrecoverable connection problem. A failed send
        // is reported inline in the conversation instead.
        let alert = UIAlertController(title: "connection", message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "ok", style: .default))
        alert.addAction(UIAlertAction(title: "sign out", style: .destructive) { [weak self] _ in
            // Let this alert finish dismissing first. Presenting while another
            // alert is on its way out is silently dropped.
            DispatchQueue.main.async { self?.confirmSignOut() }
        })
        present(alert, animated: false)
    }
}
