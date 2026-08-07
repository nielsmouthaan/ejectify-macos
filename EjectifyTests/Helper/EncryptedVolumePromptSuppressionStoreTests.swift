//
//  EncryptedVolumePromptSuppressionStoreTests.swift
//  EjectifyTests
//
//  Created by Codex on 07/08/2026.
//

import Foundation
import Testing

struct EncryptedVolumePromptSuppressionStoreTests {

    /// Creates isolated defaults for one suppression-store test.
    private func makeFixture() -> (
        store: EncryptedVolumePromptSuppressionStore,
        userDefaults: UserDefaults,
        suiteName: String,
        storageKey: String
    ) {
        let suiteName = "EncryptedVolumePromptSuppressionStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        let storageKey = "test.promptSuppression"
        return (
            EncryptedVolumePromptSuppressionStore(
                userDefaults: userDefaults,
                storageKey: storageKey
            ),
            userDefaults,
            suiteName,
            storageKey
        )
    }

    @Test func suppressionPersistsAcrossStoreInstances() {
        let fixture = makeFixture()
        defer { fixture.userDefaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.store.suppressPrompts(for: "volume-a")
        let reloadedStore = EncryptedVolumePromptSuppressionStore(
            userDefaults: fixture.userDefaults,
            storageKey: fixture.storageKey
        )

        #expect(reloadedStore.isSuppressed(for: "volume-a"))
    }

    @Test func suppressionIsIsolatedPerVolume() {
        let fixture = makeFixture()
        defer { fixture.userDefaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.store.suppressPrompts(for: "volume-a")

        #expect(fixture.store.isSuppressed(for: "volume-a"))
        #expect(fixture.store.isSuppressed(for: "volume-b") == false)
    }

    @Test func suppressedVolumeRemainsSuppressedForFutureCycles() {
        let fixture = makeFixture()
        defer { fixture.userDefaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.store.suppressPrompts(for: "volume-a")
        fixture.store.suppressPrompts(for: "volume-a")

        #expect(fixture.store.isSuppressed(for: "volume-a"))
    }

    @Test func reEnablingVolumeCanResetSuppression() {
        let fixture = makeFixture()
        defer { fixture.userDefaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.store.suppressPrompts(for: "volume-a")
        let didClear = fixture.store.clearSuppression(for: "volume-a")

        #expect(didClear)
        #expect(fixture.store.isSuppressed(for: "volume-a") == false)
    }

    @Test func clearingUnsuppressedVolumeDoesNotChangeOtherVolumes() {
        let fixture = makeFixture()
        defer { fixture.userDefaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.store.suppressPrompts(for: "volume-a")
        let didClear = fixture.store.clearSuppression(for: "volume-b")

        #expect(didClear == false)
        #expect(fixture.store.isSuppressed(for: "volume-a"))
    }
}
