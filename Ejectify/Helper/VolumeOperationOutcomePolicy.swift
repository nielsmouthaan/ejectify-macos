//
//  VolumeOperationOutcomePolicy.swift
//  Ejectify
//
//  Created by Codex on 28/07/2026.
//

import Foundation

/// Normalizes routed operation results and defines automatic remount retry decisions.
enum VolumeOperationOutcomePolicy {

    /// Represents one immediate automatic remount attempt before retry policy is applied.
    enum AutomaticRemountAttemptResult: Equatable, Sendable {
        case mountSucceeded
        case mountFailed(outcome: DiskutilOperator.Outcome)
    }

    /// Describes how the automatic remount workflow should proceed after one attempt.
    enum AutomaticRemountAttemptOutcome: Equatable, Sendable {
        case succeeded
        case retryableFailure
        case terminalFailure
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

    /// Maps disk availability and mount results onto the shared automatic remount retry behavior.
    static func automaticRemountAttemptOutcome(
        for result: AutomaticRemountAttemptResult
    ) -> AutomaticRemountAttemptOutcome {
        switch result {
        case .mountSucceeded:
            return .succeeded
        case .mountFailed(let outcome):
            switch outcome {
            case .invalidTarget, .targetAmbiguous:
                return .terminalFailure
            case .succeeded:
                return .succeeded
            case .failed, .timedOut, .launchFailed, .targetUnavailable:
                return .retryableFailure
            }
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

    /// Selects whether a confirmed locked volume should use Ejectify-managed password handling.
    static func encryptedAPFSFallbackDecision(
        unlockVolumesWhenNeeded: Bool
    ) -> EncryptedAPFSFallbackDecision {
        unlockVolumesWhenNeeded ? .useFallback : .endRecovery
    }

}
