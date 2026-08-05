//
//  APFSEncryptedVolumeUnlockerTests.swift
//  EjectifyTests
//
//  Created by Codex on 05/08/2026.
//

import Foundation
import Testing

struct APFSEncryptedVolumeUnlockerTests {

    struct ClassificationFixture: Sendable {
        let terminationStatus: Int32
        let plist: [String: PlistValue]
        let expectedResult: APFSEncryptedVolumeUnlocker.UnlockResult
    }

    enum PlistValue: Sendable {
        case bool(Bool)
        case integer(Int)
        case string(String)

        var value: Any {
            switch self {
            case .bool(let value):
                value
            case .integer(let value):
                value
            case .string(let value):
                value
            }
        }
    }

    @Test(arguments: [
        ClassificationFixture(
            terminationStatus: 0,
            plist: ["DiskManagementErrorCode": .integer(0), "Success": .bool(true)],
            expectedResult: .success
        ),
        ClassificationFixture(
            terminationStatus: 1,
            plist: [
                "DiskManagementErrorCode": .integer(-69591),
                "RateLimitStateBackoff": .bool(false),
                "RateLimitStateLockout": .bool(false),
                "Success": .bool(false)
            ],
            expectedResult: .invalidPassword
        ),
        ClassificationFixture(
            terminationStatus: 1,
            plist: [
                "DiskManagementErrorCode": .integer(-69591),
                "LocalizedUnlockDispositionMessage": .string("Your account is locked."),
                "RateLimitStateBackoff": .bool(true),
                "RateLimitStateLockout": .bool(false),
                "Success": .bool(false)
            ],
            expectedResult: .failed(message: "Your account is locked.")
        ),
        ClassificationFixture(
            terminationStatus: 1,
            plist: ["DiskManagementErrorCode": .integer(-69589), "Success": .bool(false)],
            expectedResult: .failed(message: "diskutil exited with status 1 and DiskManagementErrorCode -69589")
        ),
        ClassificationFixture(
            terminationStatus: 1,
            plist: [
                "DiskManagementErrorCode": .integer(-1),
                "LocalizedUnlockDispositionMessage": .string("Something else failed."),
                "Success": .bool(false)
            ],
            expectedResult: .failed(message: "Something else failed.")
        )
    ])
    func classifiesStructuredUnlockResult(_ fixture: ClassificationFixture) throws {
        let plist = fixture.plist.mapValues(\.value)
        let output = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        let result = APFSEncryptedVolumeUnlocker.classifyUnlockResult(
            terminationStatus: fixture.terminationStatus,
            output: output,
            errorOutput: Data()
        )

        #expect(result == fixture.expectedResult)
    }

    @Test func malformedOutputBecomesGenericFailure() {
        let result = APFSEncryptedVolumeUnlocker.classifyUnlockResult(
            terminationStatus: 1,
            output: Data("not plist".utf8),
            errorOutput: Data()
        )

        #expect(result == .failed(message: "not plist"))
    }
}
