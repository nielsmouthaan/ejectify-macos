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
    enum AutomaticRemountCandidateDisposition: Equatable {
        case preserve
        case remove
    }

    /// Represents an event that can change whether an automatic remount candidate remains pending.
    enum AutomaticRemountCandidateEvent: Equatable {
        case unmountCompleted(success: Bool, status: DAReturn?)
        case ejectModeEnabled
        case remountSucceeded
        case terminalRemountFailure
        case retryExhausted
        case retryCancelled
    }

    /// Represents one immediate automatic remount attempt before retry policy is applied.
    enum AutomaticRemountAttemptResult: Equatable {
        case diskUnavailable
        case mountSucceeded
        case mountFailed(status: DAReturn?)
    }

    /// Describes how the automatic remount workflow should proceed after one attempt.
    enum AutomaticRemountAttemptOutcome: Equatable {
        case succeeded
        case retryableFailure
        case terminalFailure
    }

    /// Describes how an automatic remount terminal failure should be handled.
    enum AutomaticRemountTerminalAction: Equatable {
        case finish
        case unlockEncryptedAPFS
    }

    /// Delays used after consecutive retryable automatic remount failures.
    static let automaticRemountRetryDelays: [Duration] = [
        .seconds(3),
        .seconds(10),
        .seconds(30)
    ]

    /// Converts the helper's non-optional raw status into the optional status used by app routing.
    static func normalizedHelperStatus(success: Bool, rawStatus: Int32) -> DAReturn? {
        guard !success, rawStatus != Int32(kDAReturnSuccess) else {
            return nil
        }

        return rawStatus
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

    /// Selects encrypted APFS unlock handling only for terminal failures while unmount mode remains active.
    static func automaticRemountTerminalAction(
        isEncrypted: Bool,
        isAPFS: Bool,
        ejectModeEnabled: Bool
    ) -> AutomaticRemountTerminalAction {
        guard isEncrypted, isAPFS, !ejectModeEnabled else {
            return .finish
        }

        return .unlockEncryptedAPFS
    }
}
