//
//  UnlockVolumesWhenNeededPreferenceTests.swift
//  EjectifyTests
//
//  Created by Codex on 10/08/2026.
//

import Foundation
import Testing

struct UnlockVolumesWhenNeededPreferenceTests {

    @Test func missingValueDefaultsToEnabled() {
        let (userDefaults, suiteName) = makeIsolatedDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        #expect(UnlockVolumesWhenNeededPreference.value(in: userDefaults))
    }

    @Test func bothValuesPersist() {
        let (userDefaults, suiteName) = makeIsolatedDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        UnlockVolumesWhenNeededPreference.set(false, in: userDefaults)
        #expect(UnlockVolumesWhenNeededPreference.value(in: UserDefaults(suiteName: suiteName)!) == false)

        UnlockVolumesWhenNeededPreference.set(true, in: userDefaults)
        #expect(UnlockVolumesWhenNeededPreference.value(in: UserDefaults(suiteName: suiteName)!))
    }

    /// Creates a unique defaults suite so tests never modify the app's actual preferences.
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "UnlockVolumesWhenNeededPreferenceTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return (userDefaults, suiteName)
    }
}
