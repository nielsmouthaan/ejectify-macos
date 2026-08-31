//
//  VolumeOperationOutcomePolicyTests.swift
//  EjectifyTests
//
//  Created by Codex on 28/07/2026.
//

import Foundation
import Testing

struct VolumeOperationOutcomePolicyTests {

    @Test(arguments: [
        DiskutilOperator.Outcome.failed,
        .timedOut,
        .launchFailed,
        .targetUnavailable
    ])
    func retryableMountFailuresRemainRetryable(_ operationOutcome: DiskutilOperator.Outcome) {
        let outcome = VolumeOperationOutcomePolicy.automaticRemountAttemptOutcome(
            for: .mountFailed(outcome: operationOutcome)
        )

        #expect(outcome == .retryableFailure)
    }

    @Test(arguments: [
        DiskutilOperator.Outcome.invalidTarget,
        .targetAmbiguous
    ])
    func invalidOrAmbiguousMountTargetIsTerminal(_ operationOutcome: DiskutilOperator.Outcome) {
        let outcome = VolumeOperationOutcomePolicy.automaticRemountAttemptOutcome(
            for: .mountFailed(outcome: operationOutcome)
        )

        #expect(outcome == .terminalFailure)
    }

    @Test func successfulMountCompletesRemount() {
        #expect(VolumeOperationOutcomePolicy.automaticRemountAttemptOutcome(for: .mountSucceeded) == .succeeded)
    }

    @Test func retryScheduleUsesExistingDelaysBeforeExhaustion() {
        let delays = (0...3).map {
            VolumeOperationOutcomePolicy.automaticRemountRetryDelay(afterFailedAttemptAt: $0)
        }

        #expect(delays == [.seconds(3), .seconds(10), .seconds(30), nil])
    }

    @Test func everyFailedEncryptedAPFSMountCanProbeLockState() {
        let decisions = (0...3).map { _ in
            VolumeOperationOutcomePolicy.shouldProbeEncryptedAPFSLockState(
                isEncrypted: true,
                isAPFS: true,
                ejectModeEnabled: false
            )
        }

        #expect(decisions == [true, true, true, true])
    }

    @Test(arguments: [
        (isEncrypted: false, isAPFS: true, ejectModeEnabled: false),
        (isEncrypted: true, isAPFS: false, ejectModeEnabled: false),
        (isEncrypted: true, isAPFS: true, ejectModeEnabled: true)
    ])
    func lockStateIsNotProbedOutsideEncryptedAPFSUnmountMode(
        fixture: (isEncrypted: Bool, isAPFS: Bool, ejectModeEnabled: Bool)
    ) {
        let shouldProbe = VolumeOperationOutcomePolicy.shouldProbeEncryptedAPFSLockState(
            isEncrypted: fixture.isEncrypted,
            isAPFS: fixture.isAPFS,
            ejectModeEnabled: fixture.ejectModeEnabled
        )

        #expect(shouldProbe == false)
    }

    @Test(arguments: [
        (isEnabled: true, expected: VolumeOperationOutcomePolicy.EncryptedAPFSFallbackDecision.useFallback),
        (isEnabled: false, expected: VolumeOperationOutcomePolicy.EncryptedAPFSFallbackDecision.endRecovery)
    ])
    func encryptedFallbackPreferenceSelectsExpectedDecision(
        fixture: (
            isEnabled: Bool,
            expected: VolumeOperationOutcomePolicy.EncryptedAPFSFallbackDecision
        )
    ) {
        let decision = VolumeOperationOutcomePolicy.encryptedAPFSFallbackDecision(
            unlockVolumesWhenNeeded: fixture.isEnabled
        )

        #expect(decision == fixture.expected)
    }
}
