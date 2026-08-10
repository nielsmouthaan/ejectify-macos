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

    /// Explicit action selected from the encrypted-volume password prompt.
    enum Outcome {
        case unlock(Response)
        case notNow
    }

    /// User input returned from the unlock prompt.
    struct Response {

        /// Passphrase entered by the user.
        let password: String

        /// Indicates whether the passphrase should be saved in Keychain.
        let shouldSaveInKeychain: Bool
    }

    /// Presents the prompt and returns the selected action.
    func requestPassword(for volume: Volume) -> Outcome {
        while true {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = String(localized: "Unlock \"\(volume.name)\"?")
            alert.informativeText = String(
                localized: "The volume couldn’t be unlocked automatically. Enter the volume password to unlock and remount it."
            )
            alert.addButton(withTitle: String(localized: "Unlock"))
            alert.addButton(withTitle: String(localized: "Not Now"))
            alert.accessoryView = makeAccessoryView()

            NSApp.activate(ignoringOtherApps: true)
            let result = alert.runModal()

            switch result {
            case .alertSecondButtonReturn:
                return .notNow
            case .alertFirstButtonReturn:
                break
            default:
                return .notNow
            }

            guard let stackView = alert.accessoryView as? NSStackView,
                  let passwordField = stackView.arrangedSubviews.first(where: { $0 is NSSecureTextField }) as? NSSecureTextField,
                  let saveCheckbox = stackView.arrangedSubviews.first(where: { $0 is NSButton }) as? NSButton else {
                return .notNow
            }

            let password = passwordField.stringValue
            guard !password.isEmpty else {
                continue
            }

            return .unlock(
                Response(password: password, shouldSaveInKeychain: saveCheckbox.state == .on)
            )
        }
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
        saveCheckbox.state = .off

        let stackView = NSStackView(views: [passwordField, saveCheckbox])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 8
        stackView.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        passwordField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return stackView
    }
}
