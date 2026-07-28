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

    @Test func indeterminateUnmountFailurePreservesRemountCandidate() {
        let disposition = VolumeOperationOutcomePolicy.automaticRemountCandidateDisposition(
            after: .unmountCompleted(success: false, status: nil)
        )

        #expect(disposition == .preserve)
    }

    @Test func definitiveUnmountFailureRemovesRemountCandidate() {
        let disposition = VolumeOperationOutcomePolicy.automaticRemountCandidateDisposition(
            after: .unmountCompleted(success: false, status: Int32(kDAReturnBusy))
        )

        #expect(disposition == .remove)
    }

    @Test func successfulUnmountPreservesRemountCandidate() {
        let disposition = VolumeOperationOutcomePolicy.automaticRemountCandidateDisposition(
            after: .unmountCompleted(success: true, status: nil)
        )

        #expect(disposition == .preserve)
    }

    @Test func retryCancellationPreservesRemountCandidate() {
        let disposition = VolumeOperationOutcomePolicy.automaticRemountCandidateDisposition(
            after: .retryCancelled
        )

        #expect(disposition == .preserve)
    }

    @Test func completedAndTerminalRemountEventsRemoveCandidate() {
        let events: [VolumeOperationOutcomePolicy.AutomaticRemountCandidateEvent] = [
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

    @Test func retryScheduleUsesExistingDelaysBeforeExhaustion() {
        let delays = (0...3).map {
            VolumeOperationOutcomePolicy.automaticRemountRetryDelay(afterFailedAttemptAt: $0)
        }

        #expect(delays == [.seconds(3), .seconds(10), .seconds(30), nil])
    }
}
