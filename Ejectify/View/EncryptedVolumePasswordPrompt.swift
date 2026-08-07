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
        case doNotAskAgain
    }

    /// User input returned from the unlock prompt.
    struct Response {

        /// Passphrase entered by the user.
        let password: String

        /// Indicates whether the passphrase should be saved in Keychain.
        let shouldSaveInKeychain: Bool
    }

    /// Presents the prompt and returns the selected action.
    func requestPassword(for volume: Volume, previousFailure: String?) -> Outcome {
        var currentFailure = previousFailure

        while true {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = String(localized: "Unlock \"\(volume.name)\"?")
            alert.informativeText = informativeText(for: volume, previousFailure: currentFailure)
            alert.addButton(withTitle: String(localized: "Unlock"))
            alert.addButton(withTitle: String(localized: "Not Now"))
            alert.addButton(withTitle: String(localized: "Don’t Ask Again"))
            alert.accessoryView = makeAccessoryView()

            NSApp.activate(ignoringOtherApps: true)
            let result = alert.runModal()

            switch result {
            case .alertSecondButtonReturn:
                return .notNow
            case .alertThirdButtonReturn:
                return .doNotAskAgain
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
                currentFailure = String(localized: "Enter a password to unlock this volume.")
                continue
            }

            return .unlock(
                Response(password: password, shouldSaveInKeychain: saveCheckbox.state == .on)
            )
        }
    }

    /// Builds the prompt explanatory copy.
    private func informativeText(for volume: Volume, previousFailure: String?) -> String {
        let baseMessage = String(localized: "macOS did not unlock this encrypted APFS volume automatically. Ejectify cannot access passwords stored by Disk Utility. Enter the volume password to let Ejectify pass it to macOS and remount the volume.")

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
            checkboxWithTitle: String(localized: "Save this password in Keychain for future automatic unlocking"),
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
