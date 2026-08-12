//
//  VolumeOperationOutcomePolicy.swift
//  Ejectify
//
//  Created by Codex on 28/07/2026.
//

import Foundation
@preconcurrency import DiskArbitration

/// Normalizes routed operation results and defines automatic remount retry decisions.
enum VolumeOperationOutcomePolicy {

    /// Describes whether an automatic wake-reconciliation candidate remains pending.
    enum AutomaticRemountCandidateDisposition: Equatable, Sendable {
        case preserve
        case remove
    }

    /// Represents an event that can change whether an automatic remount candidate remains pending.
    enum AutomaticRemountCandidateEvent: Equatable, Sendable {
        case unmountCompleted(success: Bool, status: DAReturn?)
        case ejectModeEnabled
        case remountSucceeded
        case terminalRemountFailure
        case retryExhausted
        case retryCancelled
    }

    /// Represents one immediate automatic remount attempt before retry policy is applied.
    enum AutomaticRemountAttemptResult: Equatable, Sendable {
        case diskUnavailable
        case mountSucceeded
        case mountFailed(status: DAReturn?)
    }

    /// Describes how the automatic remount workflow should proceed after one attempt.
    enum AutomaticRemountAttemptOutcome: Equatable, Sendable {
        case succeeded
        case retryableFailure
        case terminalFailure
    }

    /// Describes how encrypted APFS unlock handling should continue after live-state revalidation.
    enum EncryptedAPFSUnlockContinuation: Equatable, Sendable {
        case attemptUnlock
        case attemptNormalMount
        case deferUntilLater
    }

    /// Describes the live encrypted APFS state observed after the native-unlock grace period.
    enum NativeUnlockPostGraceState: Equatable, Sendable {
        case externallyMounted
        case unlocked
        case locked
        case unknown
        case unavailable
    }

    /// Describes how automatic remount reconciliation should continue after the native-unlock grace period.
    enum NativeUnlockGraceContinuation: Equatable, Sendable {
        case completeAfterExternalMount
        case attemptNormalMount
        case useEncryptedFallback
        case resumeNormalRetryPolicy
        case deferUntilLater
    }

    /// Describes whether Ejectify should enter its own encrypted-volume password fallback.
    enum EncryptedAPFSFallbackDecision: Equatable, Sendable {
        case useFallback
        case endRecovery
    }

    /// Delays used after consecutive retryable automatic remount failures.
    static let automaticRemountRetryDelays: [Duration] = [
        .seconds(3),
        .seconds(10),
        .seconds(30)
    ]

    /// Time allowed for macOS to unlock an encrypted APFS volume using its native credential handling.
    static let nativeUnlockGraceDelay: Duration = .seconds(5)

    /// Converts the helper's non-optional raw status into the optional status used by app routing.
    static func normalizedHelperStatus(success: Bool, rawStatus: Int32) -> DAReturn? {
        guard !success, rawStatus != Int32(kDAReturnSuccess) else {
            return nil
        }

        return rawStatus
    }

    /// Returns whether a helper authorization failure should retry once in the app process.
    static func shouldRetryHelperOperationLocally(
        operation: DiskArbitrationVolumeOperator.Operation,
        success: Bool,
        status: DAReturn?
    ) -> Bool {
        guard !success, status == Int32(kDAReturnNotPrivileged) else {
            return false
        }

        switch operation {
        case .mount, .unmount, .eject:
            return true
        }
    }

    /// Returns whether an automatic remount candidate should remain after a workflow event.
    static func automaticRemountCandidateDisposition(
        after event: AutomaticRemountCandidateEvent
    ) -> AutomaticRemountCandidateDisposition {
        switch event {
        case .unmountCompleted:
            // The unmount result describes only the immediate request. The volume can still
            // disappear during sleep, so its actual state must be reconciled after wake.
            return .preserve
        case .retryCancelled:
            return .preserve
        case .ejectModeEnabled, .remountSucceeded, .terminalRemountFailure, .retryExhausted:
            return .remove
        }
    }

    /// Maps disk availability and mount results onto the shared automatic remount retry behavior.
    static func automaticRemountAttemptOutcome(
        for result: AutomaticRemountAttemptResult
    ) -> AutomaticRemountAttemptOutcome {
        switch result {
        case .diskUnavailable:
            return .retryableFailure
        case .mountSucceeded:
            return .succeeded
        case .mountFailed(let status):
            guard let status else {
                return .retryableFailure
            }

            // A disk can disappear after the availability check and return while the retry sequence is still active.
            if status == Int32(kDAReturnNotFound) {
                return .retryableFailure
            }

            return status.shouldRetryAutomaticRemount ? .retryableFailure : .terminalFailure
        }
    }

    /// Returns the delay following the indexed retryable failure, or `nil` after exhaustion.
    static func automaticRemountRetryDelay(afterFailedAttemptAt index: Int) -> Duration? {
        guard automaticRemountRetryDelays.indices.contains(index) else {
            return nil
        }

        return automaticRemountRetryDelays[index]
    }

    /// Returns whether a failed normal mount should query live encrypted APFS lock state.
    static func shouldProbeEncryptedAPFSLockState(
        isEncrypted: Bool,
        isAPFS: Bool,
        ejectModeEnabled: Bool
    ) -> Bool {
        isEncrypted && isAPFS && !ejectModeEnabled
    }

    /// Returns whether a confirmed locked encrypted APFS mount failure should start its one native-unlock grace period.
    static func shouldStartNativeUnlockGrace(
        after result: AutomaticRemountAttemptResult,
        isEncrypted: Bool,
        isAPFS: Bool,
        ejectModeEnabled: Bool,
        lockState: APFSVolumeLockStateProbe.LockState,
        hasAlreadyWaited: Bool
    ) -> Bool {
        guard case .mountFailed = result else {
            return false
        }

        return shouldProbeEncryptedAPFSLockState(
            isEncrypted: isEncrypted,
            isAPFS: isAPFS,
            ejectModeEnabled: ejectModeEnabled
        ) && lockState == .locked && !hasAlreadyWaited
    }

    /// Selects the next automatic remount action from the state observed after native-unlock grace.
    static func nativeUnlockGraceContinuation(
        candidateExists: Bool,
        isReadyToMount: Bool,
        ejectModeEnabled: Bool,
        state: NativeUnlockPostGraceState
    ) -> NativeUnlockGraceContinuation {
        guard candidateExists, isReadyToMount, !ejectModeEnabled else {
            return .deferUntilLater
        }

        switch state {
        case .externallyMounted:
            return .completeAfterExternalMount
        case .unlocked:
            return .attemptNormalMount
        case .locked:
            return .useEncryptedFallback
        case .unknown, .unavailable:
            return .resumeNormalRetryPolicy
        }
    }

    /// Selects whether a confirmed locked volume should use Ejectify-managed password handling.
    static func encryptedAPFSFallbackDecision(
        unlockVolumesWhenNeeded: Bool
    ) -> EncryptedAPFSFallbackDecision {
        unlockVolumesWhenNeeded ? .useFallback : .endRecovery
    }

    /// Selects whether a revalidated encrypted APFS workflow should unlock, retry mounting, or preserve its candidate.
    static func encryptedAPFSUnlockContinuation(
        candidateExists: Bool,
        isReadyToMount: Bool,
        ejectModeEnabled: Bool,
        lockState: APFSVolumeLockStateProbe.LockState
    ) -> EncryptedAPFSUnlockContinuation {
        guard candidateExists, isReadyToMount, !ejectModeEnabled else {
            return .deferUntilLater
        }

        switch lockState {
        case .locked, .unknown:
            return .attemptUnlock
        case .unlocked:
            return .attemptNormalMount
        }
    }
}
