//
//  VolumeLogLabelFormatterTests.swift
//  EjectifyTests
//
//  Created by Codex on 10/07/2026.
//

import Foundation
import Testing

struct VolumeLogLabelFormatterTests {

    @Test func uuidAndBSDNameAreFormattedAsCorrelationFields() throws {
        let uuid = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))

        let label = VolumeLogLabelFormatter.label(uuid: uuid, bsdName: "disk4s1")

        #expect(label == "volume_uuid=11111111-2222-3333-4444-555555555555; bsd_name=disk4s1")
    }

    @Test func missingUUIDUsesExplicitPlaceholder() {
        let label = VolumeLogLabelFormatter.label(uuid: nil, bsdName: "disk5s1")

        #expect(label == "volume_uuid=none; bsd_name=disk5s1")
    }

    @Test func emptyMetadataUsesExplicitPlaceholders() {
        let label = VolumeLogLabelFormatter.label(uuid: nil, bsdName: "")

        #expect(label == "volume_uuid=none; bsd_name=none")
    }
}
