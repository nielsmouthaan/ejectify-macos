//
//  APFSVolumeLockStateProbeTests.swift
//  EjectifyTests
//
//  Created by Codex on 06/08/2026.
//

import Foundation
import Testing

struct APFSVolumeLockStateProbeTests {

    struct ClassificationFixture: Sendable {
        let plist: [String: PlistValue]
        let expectedState: APFSVolumeLockStateProbe.LockState
    }

    enum PlistValue: Sendable {
        case bool(Bool)
        case string(String)

        var value: Any {
            switch self {
            case .bool(let value):
                value
            case .string(let value):
                value
            }
        }
    }

    @Test(arguments: [
        ClassificationFixture(
            plist: [
                "Encryption": .bool(true),
                "FilesystemType": .string("apfs"),
                "Locked": .bool(true)
            ],
            expectedState: .locked
        ),
        ClassificationFixture(
            plist: [
                "Encryption": .bool(true),
                "FilesystemType": .string("APFS"),
                "Locked": .bool(false)
            ],
            expectedState: .unlocked
        ),
        ClassificationFixture(
            plist: [
                "Encryption": .bool(false),
                "FilesystemType": .string("apfs"),
                "Locked": .bool(true)
            ],
            expectedState: .unknown
        ),
        ClassificationFixture(
            plist: [
                "Encryption": .bool(true),
                "FilesystemType": .string("exfat"),
                "Locked": .bool(true)
            ],
            expectedState: .unknown
        ),
        ClassificationFixture(
            plist: [
                "Encryption": .bool(true),
                "FilesystemType": .string("apfs")
            ],
            expectedState: .unknown
        )
    ])
    func classifiesStructuredVolumeState(_ fixture: ClassificationFixture) throws {
        let output = try PropertyListSerialization.data(
            fromPropertyList: fixture.plist.mapValues(\.value),
            format: .xml,
            options: 0
        )

        let state = APFSVolumeLockStateProbe.classifyLockState(
            terminationStatus: 0,
            output: output
        )

        #expect(state == fixture.expectedState)
    }

    @Test func failedCommandHasUnknownState() throws {
        let output = try PropertyListSerialization.data(
            fromPropertyList: [
                "Encryption": true,
                "FilesystemType": "apfs",
                "Locked": true
            ],
            format: .xml,
            options: 0
        )

        let state = APFSVolumeLockStateProbe.classifyLockState(
            terminationStatus: 1,
            output: output
        )

        #expect(state == .unknown)
    }

    @Test func malformedOutputHasUnknownState() {
        let state = APFSVolumeLockStateProbe.classifyLockState(
            terminationStatus: 0,
            output: Data("not plist".utf8)
        )

        #expect(state == .unknown)
    }

    @Test func requestPrefersUUIDBeforeBSDName() throws {
        let diskUUID = try #require(UUID(uuidString: "96BA994F-3C29-413E-9FA9-36F86D938A51"))
        let volume = makeVolume(diskUUID: diskUUID)

        let request = APFSVolumeLockStateProbe.Request(volume: volume)

        #expect(request.identifiers == [diskUUID.uuidString, "disk15s1"])
    }

    @Test func requestUsesBSDNameWithoutUUID() {
        let request = APFSVolumeLockStateProbe.Request(volume: makeVolume(diskUUID: nil))

        #expect(request.identifiers == ["disk15s1"])
    }

    private func makeVolume(diskUUID: UUID?) -> Volume {
        Volume(
            id: diskUUID?.uuidString ?? "fallback-id",
            diskUUID: diskUUID,
            name: "Test Volume",
            url: URL(fileURLWithPath: "/Volumes/Test Volume"),
            bsdName: "disk15s1",
            wholeDiskBSDName: "disk14",
            category: .external,
            isEncrypted: true,
            isAPFS: true
        )
    }
}
