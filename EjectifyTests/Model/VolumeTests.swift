//
//  VolumeTests.swift
//  EjectifyTests
//
//  Created by Codex on 05/08/2026.
//

import Foundation
import Testing

struct VolumeTests {

    @Test func wholeDiskSelectionKeepsOneRepresentativeForSiblingPartitions() {
        let firstPartition = makeVolume(id: "first", bsdName: "disk7s1", wholeDiskBSDName: "disk7")
        let secondPartition = makeVolume(id: "second", bsdName: "disk7s2", wholeDiskBSDName: "disk7")

        let representatives = Volume.uniqueWholeDiskRepresentatives(from: [firstPartition, secondPartition])

        #expect(representatives.map(\.id) == ["first"])
    }

    @Test func wholeDiskSelectionPreservesDistinctDisksAndInputOrder() {
        let firstDisk = makeVolume(id: "first", bsdName: "disk7s1", wholeDiskBSDName: "disk7")
        let secondDisk = makeVolume(id: "second", bsdName: "disk8s1", wholeDiskBSDName: "disk8")

        let representatives = Volume.uniqueWholeDiskRepresentatives(from: [secondDisk, firstDisk])

        #expect(representatives.map(\.id) == ["second", "first"])
    }

    @Test func wholeDiskSelectionSupportsVolumesWithoutUUIDs() {
        let volume = makeVolume(
            id: "fallback|disk9s1",
            diskUUID: nil,
            bsdName: "disk9s1",
            wholeDiskBSDName: "disk9"
        )

        let representatives = Volume.uniqueWholeDiskRepresentatives(from: [volume])

        #expect(representatives.count == 1)
        #expect(representatives.first?.diskUUID == nil)
        #expect(representatives.first?.wholeDiskBSDName == "disk9")
    }

    private func makeVolume(
        id: String,
        diskUUID: UUID? = UUID(),
        bsdName: String,
        wholeDiskBSDName: String
    ) -> Volume {
        Volume(
            id: id,
            diskUUID: diskUUID,
            name: "Test Volume",
            url: URL(fileURLWithPath: "/Volumes/Test"),
            bsdName: bsdName,
            wholeDiskBSDName: wholeDiskBSDName,
            category: .external,
            isEncrypted: false,
            isAPFS: true
        )
    }
}
