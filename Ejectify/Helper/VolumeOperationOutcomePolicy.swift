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

    /// Describes whether an automatic remount candidate remains pending after unmount completion.
    enum AutomaticRemountCandidateDisposition: Equatable {
        case preserve
        case remove
    }

    /// Represents an event that can change whether an automatic remount candidate remains pending.
    enum AutomaticRemountCandidateEvent: Equatable {
        case unmountCompleted(success: Bool, status: DAReturn?)
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
        case .unmountCompleted(let success, let status):
            return success || status == nil ? .preserve : .remove
        case .retryCancelled:
            return .preserve
        case .remountSucceeded, .terminalRemountFailure, .retryExhausted:
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
}
