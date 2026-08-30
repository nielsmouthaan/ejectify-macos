//
//  APFSEncryptedVolumeUnlocker.swift
//  Ejectify
//
//  Created by Codex on 05/08/2026.
//

import Foundation

/// Adapts encrypted APFS recovery to the shared routed diskutil implementation.
final class APFSEncryptedVolumeUnlocker: @unchecked Sendable {

    enum UnlockResult: Equatable, Sendable {
        case success
        case invalidPassword
        case failed(message: String?)
    }

    /// Immutable identity metadata passed across the asynchronous routing boundary.
    struct UnlockRequest: Sendable {
        let identityUUID: UUID?
        let bsdName: String
        let logLabel: String

        init(volume: Volume) {
            identityUUID = volume.identityUUID
            bsdName = volume.bsdName
            logLabel = volume.logLabel
        }
    }

    static let shared = APFSEncryptedVolumeUnlocker()

    /// Unlocks one encrypted APFS volume through the active execution location.
    func unlock(request: UnlockRequest, password: String) async -> UnlockResult {
        let result: DiskutilOperator.UnlockResult = await withCheckedContinuation { continuation in
            VolumeOperationRouter.shared.unlockAPFSVolume(
                identityUUID: request.identityUUID.map { $0 as NSUUID },
                bsdName: request.bsdName,
                logLabel: request.logLabel,
                password: password,
                completion: { continuation.resume(returning: $0) }
            )
        }
        switch result.outcome {
        case .succeeded:
            return .success
        case .invalidPassword:
            return .invalidPassword
        case .failed, .timedOut, .launchFailed, .targetUnavailable, .targetAmbiguous, .invalidTarget:
            return .failed(message: result.outcome.rawValue)
        }
    }

    /// Classifies structured unlock output without using localized text.
    static func classifyUnlockResult(terminationStatus: Int32, output: Data, errorOutput _: Data) -> UnlockResult {
        let plist = DiskutilOperator.propertyList(from: output)
        let metadata = DiskutilOperator.apfsMetadata(from: plist)
        if terminationStatus == 0, (plist?["Success"] as? Bool) != false {
            return .success
        }
        if metadata.diskManagementErrorCode == -69591,
           metadata.rateLimitBackoff != true,
           metadata.rateLimitLockout != true {
            return .invalidPassword
        }
        if let errorCode = metadata.diskManagementErrorCode {
            return .failed(message: "diskutil exited with status \(terminationStatus) and DiskManagementErrorCode \(errorCode)")
        }
        return .failed(message: "diskutil exited with status \(terminationStatus)")
    }

    /// Formats the structured APFS fields retained for diagnostics.
    static func unlockDiagnosticMetadata(from output: Data) -> String {
        let metadata = DiskutilOperator.apfsMetadata(from: DiskutilOperator.propertyList(from: output))
        return [
            "diskManagementErrorCode=\(metadata.diskManagementErrorCode.map(String.init) ?? "unavailable")",
            "rateLimitBackoff=\(metadata.rateLimitBackoff.map(String.init) ?? "unavailable")",
            "rateLimitLockout=\(metadata.rateLimitLockout.map(String.init) ?? "unavailable")"
        ].joined(separator: "; ")
    }
}
