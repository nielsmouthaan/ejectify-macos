//
//  EncryptedVolumePasswordPrompt.swift
//  Ejectify
//
//  Created by Codex on 05/08/2026.
//

import AppKit

/// Presents a password prompt for unlocking an encrypted APFS volume.
@MainActor
final class EncryptedVolumePasswordPrompt {

    /// User input returned from the unlock prompt.
    struct Response {

        /// Passphrase entered by the user.
        let password: String

        /// Indicates whether the passphrase should be saved in Keychain.
        let shouldSaveInKeychain: Bool
    }

    /// Presents the prompt and returns the entered password, or `nil` when cancelled.
    func requestPassword(for volume: Volume, previousFailure: String?) -> Response? {
        var currentFailure = previousFailure

        while true {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = String(localized: "Unlock encrypted volume")
            alert.informativeText = informativeText(for: volume, previousFailure: currentFailure)
            alert.addButton(withTitle: String(localized: "Unlock"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.accessoryView = makeAccessoryView()

            NSApp.activate(ignoringOtherApps: true)
            let result = alert.runModal()
            guard result == .alertFirstButtonReturn,
                  let stackView = alert.accessoryView as? NSStackView,
                  let passwordField = stackView.arrangedSubviews.first(where: { $0 is NSSecureTextField }) as? NSSecureTextField,
                  let saveCheckbox = stackView.arrangedSubviews.first(where: { $0 is NSButton }) as? NSButton else {
                return nil
            }

            let password = passwordField.stringValue
            guard !password.isEmpty else {
                currentFailure = String(localized: "Enter a password to unlock this volume.")
                continue
            }

            return Response(password: password, shouldSaveInKeychain: saveCheckbox.state == .on)
        }
    }

    /// Builds the prompt explanatory copy.
    private func informativeText(for volume: Volume, previousFailure: String?) -> String {
        let baseMessage = String(
            localized: "Ejectify needs the password for \"\(volume.name)\" to unlock and remount this encrypted APFS volume."
        )

        guard let previousFailure, !previousFailure.isEmpty else {
            return baseMessage
        }

        return "\(previousFailure)\n\n\(baseMessage)"
    }

    /// Creates the secure password field and Keychain checkbox.
    private func makeAccessoryView() -> NSView {
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        passwordField.placeholderString = String(localized: "Password")

        let saveCheckbox = NSButton(
            checkboxWithTitle: String(localized: "Save password in Keychain"),
            target: nil,
            action: nil
        )
        saveCheckbox.state = .on

        let stackView = NSStackView(views: [passwordField, saveCheckbox])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 8
        stackView.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        passwordField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return stackView
    }
}
