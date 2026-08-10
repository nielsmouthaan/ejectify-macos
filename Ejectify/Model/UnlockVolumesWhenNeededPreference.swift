//
//  UnlockVolumesWhenNeededPreference.swift
//  Ejectify
//
//  Created by Codex on 10/08/2026.
//

import Foundation

/// Persists whether Ejectify may provide encrypted-volume passwords when native unlocking does not finish.
enum UnlockVolumesWhenNeededPreference {

    /// Stable defaults key used for the preference.
    static let key = "preference.unlockVolumesWhenNeeded"

    /// Reads the preference, defaulting to enabled when it has never been saved.
    static func value(in userDefaults: UserDefaults) -> Bool {
        userDefaults.object(forKey: key) as? Bool ?? true
    }

    /// Persists the selected preference value.
    static func set(_ value: Bool, in userDefaults: UserDefaults) {
        userDefaults.set(value, forKey: key)
    }
}
