//
//  VolumeOperationOutcomePolicyTests.swift
//  EjectifyTests
//
//  Created by Codex on 28/07/2026.
//

import Foundation
@preconcurrency import DiskArbitration
import Testing

struct VolumeOperationOutcomePolicyTests {

    struct UnmountCompletion: Sendable {
        let success: Bool
        let status: DAReturn?
    }

    @Test func failedHelperResultWithoutStatusNormalizesToNil() {
        let status = VolumeOperationOutcomePolicy.normalizedHelperStatus(
            success: false,
            rawStatus: Int32(kDAReturnSuccess)
        )

        #expect(status == nil)
    }

    @Test func failedHelperResultPreservesDiskArbitrationStatus() {
        let status = VolumeOperationOutcomePolicy.normalizedHelperStatus(
            success: false,
            rawStatus: Int32(kDAReturnBusy)
        )

        #expect(status == Int32(kDAReturnBusy))
    }

    @Test func successfulHelperResultHasNoFailureStatus() {
        let status = VolumeOperationOutcomePolicy.normalizedHelperStatus(
            success: true,
            rawStatus: Int32(kDAReturnBusy)
        )

        #expect(status == nil)
    }

    @Test(arguments: [
        UnmountCompletion(success: true, status: nil),
        UnmountCompletion(success: false, status: nil),
        UnmountCompletion(success: false, status: Int32(kDAReturnBusy)),
        UnmountCompletion(success: false, status: 49_168),
        UnmountCompletion(success: false, status: Int32(kDAReturnNotPermitted)),
        UnmountCompletion(success: false, status: Int32(kDAReturnUnsupported))
    ])
    func automaticUnmountCompletionAlwaysPreservesRemountCandidate(_ completion: UnmountCompletion) {
        let disposition = VolumeOperationOutcomePolicy.automaticRemountCandidateDisposition(
            after: .unmountCompleted(success: completion.success, status: completion.status)
        )

        #expect(disposition == .preserve)
    }

    @Test func encodedUnixBusyStatusHasRecognizableDescription() {
        #expect(DAReturn(49_168).statusDescription == "EBUSY (Resource busy)")
    }

    @Test func retryCancellationPreservesRemountCandidate() {
        let disposition = VolumeOperationOutcomePolicy.automaticRemountCandidateDisposition(
            after: .retryCancelled
        )

        #expect(disposition == .preserve)
    }

    @Test func completedAndTerminalRemountEventsRemoveCandidate() {
        let events: [VolumeOperationOutcomePolicy.AutomaticRemountCandidateEvent] = [
            .ejectModeEnabled,
            .remountSucceeded,
            .terminalRemountFailure,
            .retryExhausted
        ]

        for event in events {
            let disposition = VolumeOperationOutcomePolicy.automaticRemountCandidateDisposition(after: event)
            #expect(disposition == .remove)
        }
    }

    @Test func unavailableDiskIsRetryable() {
        let outcome = VolumeOperationOutcomePolicy.automaticRemountAttemptOutcome(
            for: .diskUnavailable
        )

        #expect(outcome == .retryableFailure)
    }

    @Test func diskThatBecomesAvailableCanCompleteRemount() {
        let unavailableOutcome = VolumeOperationOutcomePolicy.automaticRemountAttemptOutcome(
            for: .diskUnavailable
        )
        let mountedOutcome = VolumeOperationOutcomePolicy.automaticRemountAttemptOutcome(
            for: .mountSucceeded
        )

        #expect(unavailableOutcome == .retryableFailure)
        #expect(mountedOutcome == .succeeded)
    }

    @Test func helperBackedMountTimeoutIsRetryable() {
        let outcome = VolumeOperationOutcomePolicy.automaticRemountAttemptOutcome(
            for: .mountFailed(status: nil)
        )

        #expect(outcome == .retryableFailure)
    }

    @Test func retryableMountStatusIsRetryable() {
        let outcome = VolumeOperationOutcomePolicy.automaticRemountAttemptOutcome(
            for: .mountFailed(status: Int32(kDAReturnBusy))
        )

        #expect(outcome == .retryableFailure)
    }

    @Test func missingDiskMountStatusIsRetryable() {
        let outcome = VolumeOperationOutcomePolicy.automaticRemountAttemptOutcome(
            for: .mountFailed(status: Int32(kDAReturnNotFound))
        )

        #expect(outcome == .retryableFailure)
    }

    @Test func nonRetryableMountStatusIsTerminal() {
        let outcome = VolumeOperationOutcomePolicy.automaticRemountAttemptOutcome(
            for: .mountFailed(status: Int32(kDAReturnUnsupported))
        )

        #expect(outcome == .terminalFailure)
    }

    @Test func successfulMountCompletesRemount() {
        let outcome = VolumeOperationOutcomePolicy.automaticRemountAttemptOutcome(
            for: .mountSucceeded
        )

        #expect(outcome == .succeeded)
    }

    @Test func busyUnmountRemainsPendingUntilWakeReconciliationSucceeds() {
        let unmountDisposition = VolumeOperationOutcomePolicy.automaticRemountCandidateDisposition(
            after: .unmountCompleted(success: false, status: 49_168)
        )
        let wakeOutcome = VolumeOperationOutcomePolicy.automaticRemountAttemptOutcome(
            for: .mountSucceeded
        )
        let reconciledDisposition = VolumeOperationOutcomePolicy.automaticRemountCandidateDisposition(
            after: .remountSucceeded
        )

        #expect(unmountDisposition == .preserve)
        #expect(wakeOutcome == .succeeded)
        #expect(reconciledDisposition == .remove)
    }

    @Test func retryScheduleUsesExistingDelaysBeforeExhaustion() {
        let delays = (0...3).map {
            VolumeOperationOutcomePolicy.automaticRemountRetryDelay(afterFailedAttemptAt: $0)
        }

        #expect(delays == [.seconds(3), .seconds(10), .seconds(30), nil])
    }

    @Test func encryptedAPFSMountFailureRequestsLockStateProbeInUnmountMode() {
        let shouldProbe = VolumeOperationOutcomePolicy.shouldProbeEncryptedAPFSLockState(
            isEncrypted: true,
            isAPFS: true,
            ejectModeEnabled: false
        )

        #expect(shouldProbe)
    }

    @Test(arguments: [
        (isEncrypted: false, isAPFS: true, ejectModeEnabled: false),
        (isEncrypted: true, isAPFS: false, ejectModeEnabled: false),
        (isEncrypted: true, isAPFS: true, ejectModeEnabled: true)
    ])
    func mountFailureDoesNotProbeOutsideEncryptedAPFSUnmountMode(
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
        (candidateExists: false, isReadyToMount: true, ejectModeEnabled: false),
        (candidateExists: true, isReadyToMount: false, ejectModeEnabled: false),
        (candidateExists: true, isReadyToMount: true, ejectModeEnabled: true)
    ])
    func staleEncryptedAPFSUnlockIsDeferred(
        fixture: (candidateExists: Bool, isReadyToMount: Bool, ejectModeEnabled: Bool)
    ) {
        let continuation = VolumeOperationOutcomePolicy.encryptedAPFSUnlockContinuation(
            candidateExists: fixture.candidateExists,
            isReadyToMount: fixture.isReadyToMount,
            ejectModeEnabled: fixture.ejectModeEnabled,
            lockState: .locked
        )

        #expect(continuation == .deferUntilLater)
    }

    @Test func alreadyUnlockedEncryptedAPFSVolumeCompletesWithoutUnlock() {
        let continuation = VolumeOperationOutcomePolicy.encryptedAPFSUnlockContinuation(
            candidateExists: true,
            isReadyToMount: true,
            ejectModeEnabled: false,
            lockState: .unlocked
        )

        #expect(continuation == .completeWithoutUnlock)
    }

    @Test(arguments: [
        APFSVolumeLockStateProbe.LockState.locked,
        APFSVolumeLockStateProbe.LockState.unknown
    ])
    func currentEncryptedAPFSVolumeAttemptsUnlock(
        lockState: APFSVolumeLockStateProbe.LockState
    ) {
        let continuation = VolumeOperationOutcomePolicy.encryptedAPFSUnlockContinuation(
            candidateExists: true,
            isReadyToMount: true,
            ejectModeEnabled: false,
            lockState: lockState
        )

        #expect(continuation == .attemptUnlock)
    }
}
