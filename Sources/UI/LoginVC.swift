//
//  LoginVC.swift
//
//  Token entry.
//
//  The risk notice is on this screen, in plain words, before the field. A
//  user-token client is a self-bot under Discord's Terms of Service and the
//  account can be terminated. Burying that would be dishonest: it is the one
//  thing the user cannot discover by using the app.
//

import UIKit

public final class LoginVC: UIViewController {

    private let store: DMStore
    private let header = TermView()
    private let field = UITextView()
    private let hint = TermView()

    public var onSignedIn: (() -> Void)?

    public init(store: DMStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = TermTheme.background

        header.translatesAutoresizingMaskIntoConstraints = false
        header.lines = [
            TermLine("smolcord", color: TermTheme.accent, bold: true),
            TermLine("a terminal discord client for dms", color: TermTheme.dim),
            TermLine.blank,
            TermLine("target: under 1MB/hr. no images, no", color: TermColor.brightGreen),
            TermLine("avatars, no embeds, no telemetry.", color: TermColor.brightGreen),
            TermLine.blank,
            TermLine("WARNING", color: TermTheme.warning, bold: true),
            TermLine("this signs in with a user token.", color: TermColor.white),
            TermLine("discord calls that a self-bot. it", color: TermColor.white),
            TermLine("breaks their terms of service and", color: TermColor.white),
            TermLine("the account can be terminated.", color: TermColor.white),
            TermLine.blank,
            TermLine("paste token, then press return:", color: TermTheme.prompt),
        ]
        view.addSubview(header)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.backgroundColor = TermColor.brightBlack.uiColor.withAlphaComponent(0.2)
        field.textColor = TermTheme.foreground
        field.font = TermTheme.font
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.keyboardAppearance = .dark
        field.returnKeyType = .go
        field.delegate = self
        // No smart quotes: they would corrupt a pasted token.
        if #available(iOS 11.0, *) {
            field.smartQuotesType = .no
            field.smartDashesType = .no
            field.smartInsertDeleteType = .no
        }
        view.addSubview(field)

        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.lines = [
            TermLine("the token is stored in the keychain,", color: TermTheme.dim),
            TermLine("device-only, never in a backup.", color: TermTheme.dim),
        ]
        view.addSubview(hint)

        let guide: UILayoutGuide
        if #available(iOS 11.0, *) { guide = view.safeAreaLayoutGuide } else { guide = view.layoutMarginsGuide }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -10),

            field.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -10),
            field.heightAnchor.constraint(equalToConstant: TermTheme.cellHeight * 3),

            hint.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 10),
            hint.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -10),
        ])
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }

    private func attemptSignIn() {
        let token = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count > 20 else {
            hint.lines = [TermLine("that does not look like a token.", color: TermTheme.warning)]
            return
        }
        field.text = ""
        field.resignFirstResponder()
        store.signIn(token: token)
        onSignedIn?()
    }
}

extension LoginVC: UITextViewDelegate {
    public func textView(_ textView: UITextView,
                         shouldChangeTextIn range: NSRange,
                         replacementText text: String) -> Bool {
        if text == "\n" {
            attemptSignIn()
            return false
        }
        return true
    }
}
