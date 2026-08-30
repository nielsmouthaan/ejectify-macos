//
//  APFSVolumeLockStateProbe.swift
//  Ejectify
//
//  Created by Codex on 06/08/2026.
//

import Foundation

/// Adapts encrypted APFS recovery to the shared routed diskutil implementation.
final class APFSVolumeLockStateProbe: @unchecked Sendable {

    enum LockState: Equatable, Sendable {
        case locked
        case unlocked
        case unknown
    }

    /// Immutable identity metadata passed across the asynchronous routing boundary.
    struct Request: Sendable {
        let identityUUID: UUID?
        let bsdName: String
        let logLabel: String

        init(volume: Volume) {
            identityUUID = volume.identityUUID
            bsdName = volume.bsdName
            logLabel = volume.logLabel
        }
    }

    static let shared = APFSVolumeLockStateProbe()

    /// Reads lock state using local or helper-backed diskutil according to router state.
    func lockState(request: Request) async -> LockState {
        let state: DiskutilOperator.LockState = await withCheckedContinuation { continuation in
            VolumeOperationRouter.shared.inspectAPFSLockState(
                identityUUID: request.identityUUID.map { $0 as NSUUID },
                bsdName: request.bsdName,
                logLabel: request.logLabel,
                completion: { continuation.resume(returning: $0) }
            )
        }
        switch state {
        case .locked: return .locked
        case .unlocked: return .unlocked
        case .unknown: return .unknown
        }
    }

    /// Classifies structured diskutil info output for deterministic tests.
    static func classifyLockState(terminationStatus: Int32, output: Data) -> LockState {
        let state = DiskutilOperator.classifyLockState(
            processResult: DiskutilOperator.ProcessResult(
                exitCode: terminationStatus,
                terminationReason: .exit,
                durationMilliseconds: 0,
                timedOut: false,
                stdout: output,
                stderr: Data()
            )
        )
        switch state {
        case .locked: return .locked
        case .unlocked: return .unlocked
        case .unknown: return .unknown
        }
    }
}
