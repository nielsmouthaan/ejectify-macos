//
//  EncryptedVolumePromptSuppressionStore.swift
//  Ejectify
//
//  Created by Codex on 07/08/2026.
//

import Foundation

/// Persists the volume identifiers for which Ejectify password prompts are suppressed.
final class EncryptedVolumePromptSuppressionStore: @unchecked Sendable {

    /// Shared store used by automatic remount reconciliation and volume preference changes.
    static let shared = EncryptedVolumePromptSuppressionStore()

    private let userDefaults: UserDefaults
    private let storageKey: String

    /// Creates a suppression store backed by the supplied defaults and storage key.
    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "encryptedVolumePromptSuppression.volumeIDs"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    /// Returns whether Ejectify password prompts are suppressed for a volume identifier.
    func isSuppressed(for volumeID: String) -> Bool {
        suppressedVolumeIDs.contains(volumeID)
    }

    /// Suppresses future Ejectify password prompts for a volume identifier.
    func suppressPrompts(for volumeID: String) {
        var volumeIDs = suppressedVolumeIDs
        volumeIDs.insert(volumeID)
        userDefaults.set(volumeIDs.sorted(), forKey: storageKey)
    }

    /// Clears prompt suppression and returns whether a stored suppression was removed.
    @discardableResult
    func clearSuppression(for volumeID: String) -> Bool {
        var volumeIDs = suppressedVolumeIDs
        guard volumeIDs.remove(volumeID) != nil else {
            return false
        }

        userDefaults.set(volumeIDs.sorted(), forKey: storageKey)
        return true
    }

    /// Current suppressed identifiers normalized from persisted defaults.
    private var suppressedVolumeIDs: Set<String> {
        Set(userDefaults.stringArray(forKey: storageKey) ?? [])
    }
}
