//
//  EncryptedVolumeCredentialStore.swift
//  Ejectify
//
//  Created by Codex on 05/08/2026.
//

import Foundation
import Security

/// Stores encrypted-volume unlock passphrases in the user's macOS Keychain.
final class EncryptedVolumeCredentialStore: @unchecked Sendable {

    /// Errors produced while reading or writing Keychain items.
    enum StoreError: LocalizedError {
        case unhandledStatus(OSStatus)

        /// Human-readable Keychain error description.
        var errorDescription: String? {
            switch self {
            case .unhandledStatus(let status):
                if let message = SecCopyErrorMessageString(status, nil) as String? {
                    return message
                }

                return "Keychain returned status \(status)"
            }
        }
    }

    /// Shared store instance used for automatic remount unlocks.
    static let shared = EncryptedVolumeCredentialStore()

    /// Keychain service namespace for encrypted volume passphrases.
    private static let serviceName = "nl.nielsmouthaan.Ejectify.encrypted-volume"

    /// Creates a Keychain query scoped to one persisted volume identifier.
    private func query(for volumeID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: volumeID
        ]
    }

    /// Returns the saved passphrase for a volume, if one exists.
    func password(for volumeID: String) throws -> String? {
        var query = query(for: volumeID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else {
            return nil
        }

        guard status == errSecSuccess else {
            throw StoreError.unhandledStatus(status)
        }

        guard let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Saves or replaces the passphrase for a volume.
    func savePassword(_ password: String, for volumeID: String) throws {
        let passwordData = Data(password.utf8)
        var addQuery = query(for: volumeID)
        addQuery[kSecAttrLabel as String] = "Ejectify encrypted volume password"
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData as String] = passwordData

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let attributesToUpdate: [String: Any] = [kSecValueData as String: passwordData]
            let updateStatus = SecItemUpdate(query(for: volumeID) as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw StoreError.unhandledStatus(updateStatus)
            }
            return
        }

        guard addStatus == errSecSuccess else {
            throw StoreError.unhandledStatus(addStatus)
        }
    }

    /// Deletes the saved passphrase for a volume, if present.
    func deletePassword(for volumeID: String) throws {
        let status = SecItemDelete(query(for: volumeID) as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unhandledStatus(status)
        }
    }
}
