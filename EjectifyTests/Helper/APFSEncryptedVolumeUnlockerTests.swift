//
//  APFSEncryptedVolumeUnlockerTests.swift
//  EjectifyTests
//
//  Created by Codex on 05/08/2026.
//

import Foundation
import Testing

struct APFSEncryptedVolumeUnlockerTests {

    struct RecoveryFixture: Sendable {
        let metadata: DiskArbitrationVolumeOperator.ResolvedVolumeMetadata?
        let lockState: APFSVolumeLockStateProbe.LockState?
        let expectedAction: APFSEncryptedVolumeUnlocker.RecoveryAction
    }

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

        #expect(result == .failed(message: "diskutil exited with status 1"))
    }

    @Test func preservesPrivacySafeStructuredDiagnostics() throws {
        let output = try PropertyListSerialization.data(
            fromPropertyList: [
                "DiskManagementErrorCode": -69591,
                "LocalizedUnlockDispositionMessage": "Your account is locked.",
                "RateLimitStateBackoff": true,
                "RateLimitStateLockout": false,
                "Success": false
            ],
            format: .xml,
            options: 0
        )

        #expect(APFSEncryptedVolumeUnlocker.unlockDiagnosticMetadata(from: output) == "diskManagementErrorCode=-69591; rateLimitBackoff=true; rateLimitLockout=false")
    }

    @Test func reportsUnavailableDiagnosticsForMalformedOutput() {
        let metadata = APFSEncryptedVolumeUnlocker.unlockDiagnosticMetadata(from: Data("not plist".utf8))

        #expect(metadata == "diskManagementErrorCode=unavailable; rateLimitBackoff=unavailable; rateLimitLockout=unavailable")
    }

    @Test func preservesPrivacyRestrictionDiagnostics() throws {
        let output = try PropertyListSerialization.data(
            fromPropertyList: [
                "DiskManagementErrorCode": -69464,
                "LocalizedUnlockDispositionMessage": "The operation is restricted by privacy settings.",
                "RateLimitStateBackoff": false,
                "RateLimitStateLockout": false,
                "Success": false
            ],
            format: .xml,
            options: 0
        )

        let result = APFSEncryptedVolumeUnlocker.classifyAttemptResult(
            terminationStatus: 1,
            output: output,
            errorOutput: Data()
        )

        #expect(result.outcome == .failed(message: "The operation is restricted by privacy settings."))
        #expect(result.diagnostics == APFSEncryptedVolumeUnlocker.Diagnostics(
            diskManagementErrorCode: -69464,
            rateLimitBackoff: false,
            rateLimitLockout: false
        ))
    }

    @Test(arguments: [
        RecoveryFixture(
            metadata: nil,
            lockState: nil,
            expectedAction: .fail(message: "Volume is no longer available.")
        ),
        RecoveryFixture(
            metadata: DiskArbitrationVolumeOperator.ResolvedVolumeMetadata(
                bsdName: "disk4s1",
                isMounted: false,
                isEncrypted: false,
                isAPFS: true
            ),
            lockState: .locked,
            expectedAction: .fail(message: "Volume is not an encrypted APFS volume.")
        ),
        RecoveryFixture(
            metadata: DiskArbitrationVolumeOperator.ResolvedVolumeMetadata(
                bsdName: "disk4s1",
                isMounted: false,
                isEncrypted: true,
                isAPFS: false
            ),
            lockState: .locked,
            expectedAction: .fail(message: "Volume is not an encrypted APFS volume.")
        ),
        RecoveryFixture(
            metadata: DiskArbitrationVolumeOperator.ResolvedVolumeMetadata(
                bsdName: "disk4s1",
                isMounted: true,
                isEncrypted: true,
                isAPFS: true
            ),
            lockState: nil,
            expectedAction: .succeed
        ),
        RecoveryFixture(
            metadata: DiskArbitrationVolumeOperator.ResolvedVolumeMetadata(
                bsdName: "disk4s1",
                isMounted: false,
                isEncrypted: true,
                isAPFS: true
            ),
            lockState: .unlocked,
            expectedAction: .mount
        ),
        RecoveryFixture(
            metadata: DiskArbitrationVolumeOperator.ResolvedVolumeMetadata(
                bsdName: "disk4s1",
                isMounted: false,
                isEncrypted: true,
                isAPFS: true
            ),
            lockState: .locked,
            expectedAction: .unlock
        ),
        RecoveryFixture(
            metadata: DiskArbitrationVolumeOperator.ResolvedVolumeMetadata(
                bsdName: "disk4s1",
                isMounted: false,
                isEncrypted: true,
                isAPFS: true
            ),
            lockState: .unknown,
            expectedAction: .fail(message: "The encrypted volume state could not be determined.")
        )
    ])
    func selectsRecoveryAction(_ fixture: RecoveryFixture) {
        let action = APFSEncryptedVolumeUnlocker.recoveryAction(
            metadata: fixture.metadata,
            lockState: fixture.lockState
        )

        #expect(action == fixture.expectedAction)
    }

    @Test func processLaunchFailureBecomesStructuredFailure() {
        let result = APFSEncryptedVolumeUnlocker.performUnlockCommand(
            bsdName: "disk4s1",
            passphraseData: Data("secret".utf8),
            executableURL: URL(fileURLWithPath: "/path/that/does/not/exist")
        )

        guard case .failed(let message) = result.outcome else {
            Issue.record("Expected process launch failure.")
            return
        }

        #expect(message?.isEmpty == false)
        #expect(result.diagnostics == .unavailable)
    }

    @Test func privilegedExecutorUsesInjectedHelperRecovery() async {
        let request = APFSEncryptedVolumeUnlocker.UnlockRequest(
            volumeUUID: UUID(),
            volumeName: "Encrypted",
            bsdName: "disk4s1",
            logLabel: "bsd_name=disk4s1",
            executor: .privilegedHelper
        )

        let result = await APFSEncryptedVolumeUnlocker.shared.unlockAndMount(
            request: request,
            password: "secret"
        ) { receivedRequest, passphraseData in
            #expect(receivedRequest.executor == .privilegedHelper)
            #expect(passphraseData == Data("secret".utf8))
            return APFSEncryptedVolumeUnlocker.AttemptResult(
                outcome: .success,
                diagnostics: .unavailable
            )
        }

        #expect(result.outcome == .success)
    }
}
