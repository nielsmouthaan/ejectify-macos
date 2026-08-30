//
//  VolumeTests.swift
//  EjectifyTests
//
//  Created by Codex on 05/08/2026.
//

import Foundation
@preconcurrency import DiskArbitration
import Testing

struct VolumeTests {

    @Test func diskArbitrationVolumeNameIsPreferredForDisplay() {
        let displayName = Volume.displayName(
            for: URL(fileURLWithPath: "/Volumes/Fallback"),
            diskInfo: [kDADiskDescriptionVolumeNameKey: "Preferred"]
        )

        #expect(displayName == "Preferred")
    }

    @Test(arguments: [
        (Volume.Category.internalVolume, true),
        (.external, true),
        (.diskImage, false)
    ])
    func categoryProvidesExistingDefaultSelection(fixture: (Volume.Category, Bool)) {
        let id = "test-default-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "volume.\(id)") }

        let volume = makeVolume(id: id, category: fixture.0)
        #expect(volume.enabled == fixture.1)
    }

    @Test func UUIDBackedSelectionSurvivesReconnectWithChangedBSDName() {
        let identityUUID = UUID()
        let id = identityUUID.uuidString
        defer { UserDefaults.standard.removeObject(forKey: "volume.\(id)") }
        let first = makeVolume(id: id, identityUUID: identityUUID, bsdName: "disk7s1", category: .external)
        first.enabled = false

        let reconnected = makeVolume(id: id, identityUUID: identityUUID, bsdName: "disk13s1", category: .external)
        #expect(reconnected.enabled == false)
        #expect(reconnected.identityUUID == identityUUID)
        #expect(reconnected.bsdName == "disk13s1")
    }

    @Test func identityUUIDRemainsTheOperationIdentity() {
        let identityUUID = UUID()
        let volume = makeVolume(id: identityUUID.uuidString, identityUUID: identityUUID, category: .external)
        #expect(volume.identityUUID == identityUUID)
        #expect(volume.logLabel.contains(identityUUID.uuidString))
    }

    private func makeVolume(
        id: String,
        identityUUID: UUID? = UUID(),
        bsdName: String = "disk99s1",
        category: Volume.Category
    ) -> Volume {
        Volume(
            id: id,
            identityUUID: identityUUID,
            name: "Test Volume",
            url: URL(fileURLWithPath: "/Volumes/Test"),
            bsdName: bsdName,
            category: category,
            isEncrypted: false,
            isAPFS: true
        )
    }
}
