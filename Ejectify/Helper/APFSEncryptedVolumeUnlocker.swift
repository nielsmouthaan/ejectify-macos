//
//  APFSEncryptedVolumeUnlocker.swift
//  Ejectify
//
//  Created by Codex on 05/08/2026.
//

import Foundation

/// Unlocks and mounts encrypted APFS volumes within one captured execution context.
final class APFSEncryptedVolumeUnlocker: @unchecked Sendable {

    /// Owns a short-lived mutable passphrase buffer across asynchronous execution.
    private final class PassphraseBox: @unchecked Sendable {
        var data: Data

        /// Takes ownership of bytes derived from the supplied password.
        init(data: Data) {
            self.data = data
        }

        /// Best-effort clears the owned bytes.
        func clear() {
            data.resetBytes(in: data.indices)
        }
    }

    /// Injected privileged recovery operation used to keep helper routing testable.
    typealias PrivilegedRecovery = @Sendable (UnlockRequest, Data) async -> AttemptResult

    /// Result produced by one unlock-and-mount attempt.
    enum UnlockResult: Equatable, Sendable {
        case success
        case invalidPassword
        case failed(message: String?)
    }

    /// Privacy-safe structured fields extracted from `diskutil` plist output.
    struct Diagnostics: Equatable, Sendable {
        let diskManagementErrorCode: Int?
        let rateLimitBackoff: Bool?
        let rateLimitLockout: Bool?

        /// Empty diagnostics used when no `diskutil` command was executed.
        static let unavailable = Diagnostics(
            diskManagementErrorCode: nil,
            rateLimitBackoff: nil,
            rateLimitLockout: nil
        )

        /// Stable metadata rendered into support logs without raw command output.
        var logDescription: String {
            [
                "diskManagementErrorCode=\(diskManagementErrorCode.map(String.init) ?? "unavailable")",
                "rateLimitBackoff=\(rateLimitBackoff.map(String.init) ?? "unavailable")",
                "rateLimitLockout=\(rateLimitLockout.map(String.init) ?? "unavailable")"
            ].joined(separator: "; ")
        }
    }

    /// Complete structured result for one recovery attempt.
    struct AttemptResult: Equatable, Sendable {
        let outcome: UnlockResult
        let diagnostics: Diagnostics
    }

    /// Same-process action selected after validating the live recovery target.
    enum RecoveryAction: Equatable, Sendable {
        case succeed
        case mount
        case unlock
        case fail(message: String)
    }

    /// Immutable volume metadata safe to pass to a background queue or the privileged helper.
    struct UnlockRequest: Sendable {
        let volumeUUID: UUID?
        let volumeName: String
        let bsdName: String
        let logLabel: String
        let executor: VolumeOperationExecutor

        /// Creates a recovery request from primitive volume metadata.
        init(
            volumeUUID: UUID?,
            volumeName: String,
            bsdName: String,
            logLabel: String,
            executor: VolumeOperationExecutor
        ) {
            self.volumeUUID = volumeUUID
            self.volumeName = volumeName
            self.bsdName = bsdName
            self.logLabel = logLabel
            self.executor = executor
        }

        #if !EJECTIFY_PRIVILEGED_HELPER
        /// Creates a recovery request from the main app's volume model.
        init(volume: Volume, executor: VolumeOperationExecutor) {
            self.init(
                volumeUUID: volume.diskUUID,
                volumeName: volume.name,
                bsdName: volume.bsdName,
                logLabel: volume.logLabel,
                executor: executor
            )
        }
        #endif
    }

    /// Shared unlocker instance used by automatic remount handling.
    static let shared = APFSEncryptedVolumeUnlocker()

    /// DiskManagement error code returned when APFS rejects the supplied authentication.
    private static let authenticationRejectedErrorCode = -69591

    /// Queue that keeps local `diskutil` execution off the main actor.
    private let queue = DispatchQueue(
        label: "nl.nielsmouthaan.Ejectify.APFSEncryptedVolumeUnlocker",
        qos: .userInitiated
    )

    #if !EJECTIFY_PRIVILEGED_HELPER
    /// Attempts recovery in the process that handled the failed mount.
    func unlockAndMount(
        request: UnlockRequest,
        password: String,
        privilegedRecovery: PrivilegedRecovery
    ) async -> AttemptResult {
        let passphraseBox = PassphraseBox(data: Data(password.utf8))
        defer {
            passphraseBox.clear()
        }

        switch request.executor {
        case .local:
            return await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: Self.performRecovery(request: request, passphraseData: passphraseBox.data))
                }
            }
        case .privilegedHelper:
            return await privilegedRecovery(request, passphraseBox.data)
        }
    }
    #endif

    /// Revalidates a recovery target and completes mounting entirely in the current process.
    static func performRecovery(request: UnlockRequest, passphraseData: Data) -> AttemptResult {
        Log.volumeOperations.log("Encrypted APFS recovery started; executor=\(request.executor.rawValue); \(request.logLabel)")

        let metadata = DiskArbitrationVolumeOperator.resolvedVolumeMetadata(
            volumeUUID: request.volumeUUID,
            volumeName: request.volumeName,
            bsdName: request.bsdName
        )

        var identifiers: [String] = []
        if let volumeUUID = request.volumeUUID {
            identifiers.append(volumeUUID.uuidString)
        }
        if let metadata, identifiers.contains(metadata.bsdName) == false {
            identifiers.append(metadata.bsdName)
        }

        let lockState: APFSVolumeLockStateProbe.LockState?
        if let metadata, metadata.isMounted == false, metadata.isAPFS, metadata.isEncrypted {
            lockState = APFSVolumeLockStateProbe.lockState(identifiers: identifiers, logLabel: request.logLabel)
        } else {
            lockState = nil
        }

        switch recoveryAction(metadata: metadata, lockState: lockState) {
        case .succeed:
            return finish(
                AttemptResult(outcome: .success, diagnostics: .unavailable),
                request: request
            )
        case .unlock:
            guard let metadata else {
                return finish(
                    AttemptResult(outcome: .failed(message: "Volume is no longer available."), diagnostics: .unavailable),
                    request: request
                )
            }
            return finish(
                performUnlockCommand(
                    bsdName: metadata.bsdName,
                    passphraseData: passphraseData
                ),
                request: request
            )
        case .mount:
            guard let metadata else {
                return finish(
                    AttemptResult(outcome: .failed(message: "Volume is no longer available."), diagnostics: .unavailable),
                    request: request
                )
            }
            let mountResult = DiskArbitrationVolumeOperator.perform(
                volumeUUID: request.volumeUUID,
                volumeName: request.volumeName,
                bsdName: metadata.bsdName,
                operation: .mount
            )
            let result = mountResult.success
                ? AttemptResult(outcome: .success, diagnostics: .unavailable)
                : AttemptResult(outcome: .failed(message: mountResult.message), diagnostics: .unavailable)
            return finish(result, request: request)
        case .fail(let message):
            return finish(
                AttemptResult(outcome: .failed(message: message), diagnostics: .unavailable),
                request: request
            )
        }
    }

    /// Selects recovery behavior from resolved metadata and the live APFS lock state.
    static func recoveryAction(
        metadata: DiskArbitrationVolumeOperator.ResolvedVolumeMetadata?,
        lockState: APFSVolumeLockStateProbe.LockState?
    ) -> RecoveryAction {
        guard let metadata else {
            return .fail(message: "Volume is no longer available.")
        }
        guard metadata.isAPFS, metadata.isEncrypted else {
            return .fail(message: "Volume is not an encrypted APFS volume.")
        }
        guard metadata.isMounted == false else {
            return .succeed
        }

        switch lockState {
        case .locked:
            return .unlock
        case .unlocked:
            return .mount
        case .unknown, nil:
            return .fail(message: "The encrypted volume state could not be determined.")
        }
    }

    /// Runs `diskutil apfs unlockVolume`, which unlocks and mounts when `-nomount` is omitted.
    static func performUnlockCommand(
        bsdName: String,
        passphraseData: Data,
        executableURL: URL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    ) -> AttemptResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["apfs", "unlockVolume", bsdName, "-stdinpassphrase", "-plist"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            var terminatedPassphrase = passphraseData
            terminatedPassphrase.append(0x0A)
            inputPipe.fileHandleForWriting.write(terminatedPassphrase)
            terminatedPassphrase.resetBytes(in: terminatedPassphrase.indices)
            try inputPipe.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {
            return AttemptResult(outcome: .failed(message: error.localizedDescription), diagnostics: .unavailable)
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return classifyAttemptResult(
            terminationStatus: process.terminationStatus,
            output: output,
            errorOutput: errorOutput
        )
    }

    /// Classifies `diskutil` plist output without matching human-readable error text.
    static func classifyAttemptResult(
        terminationStatus: Int32,
        output: Data,
        errorOutput: Data
    ) -> AttemptResult {
        guard let plist = unlockPlist(from: output) else {
            return AttemptResult(
                outcome: .failed(message: "diskutil exited with status \(terminationStatus)"),
                diagnostics: .unavailable
            )
        }

        let diagnostics = Diagnostics(
            diskManagementErrorCode: plist["DiskManagementErrorCode"] as? Int,
            rateLimitBackoff: plist["RateLimitStateBackoff"] as? Bool,
            rateLimitLockout: plist["RateLimitStateLockout"] as? Bool
        )

        if plist["Success"] as? Bool == true {
            return AttemptResult(outcome: .success, diagnostics: diagnostics)
        }

        let isRateLimited = diagnostics.rateLimitBackoff == true
            || diagnostics.rateLimitLockout == true

        if diagnostics.diskManagementErrorCode == authenticationRejectedErrorCode && !isRateLimited {
            return AttemptResult(outcome: .invalidPassword, diagnostics: diagnostics)
        }

        return AttemptResult(
            outcome: .failed(message: unlockFailureMessage(from: plist, terminationStatus: terminationStatus)),
            diagnostics: diagnostics
        )
    }

    /// Preserves the previous classification API for focused unit tests and call-site compatibility.
    static func classifyUnlockResult(
        terminationStatus: Int32,
        output: Data,
        errorOutput: Data
    ) -> UnlockResult {
        classifyAttemptResult(
            terminationStatus: terminationStatus,
            output: output,
            errorOutput: errorOutput
        ).outcome
    }

    /// Returns the minimal privacy-safe metadata needed to diagnose an unlock failure.
    static func unlockDiagnosticMetadata(from output: Data) -> String {
        guard let plist = unlockPlist(from: output) else {
            return Diagnostics.unavailable.logDescription
        }

        return Diagnostics(
            diskManagementErrorCode: plist["DiskManagementErrorCode"] as? Int,
            rateLimitBackoff: plist["RateLimitStateBackoff"] as? Bool,
            rateLimitLockout: plist["RateLimitStateLockout"] as? Bool
        ).logDescription
    }

    /// Logs one final result without persisting a password or raw command output.
    private static func finish(_ result: AttemptResult, request: UnlockRequest) -> AttemptResult {
        switch result.outcome {
        case .success:
            Log.volumeOperations.log("Encrypted APFS recovery succeeded; executor=\(request.executor.rawValue); \(request.logLabel)")
        case .invalidPassword:
            Log.volumeOperations.warning("Encrypted APFS recovery rejected the supplied password; executor=\(request.executor.rawValue); \(result.diagnostics.logDescription); \(request.logLabel)")
        case .failed:
            Log.volumeOperations.error("Encrypted APFS recovery failed; executor=\(request.executor.rawValue); \(result.diagnostics.logDescription); \(request.logLabel)")
        }

        return result
    }

    /// Parses the plist emitted by `diskutil apfs unlockVolume -plist`.
    private static func unlockPlist(from output: Data) -> [String: Any]? {
        guard output.isEmpty == false else {
            return nil
        }

        return (try? PropertyListSerialization.propertyList(from: output, options: [], format: nil)) as? [String: Any]
    }

    /// Builds a user-facing failure message from structured plist output.
    private static func unlockFailureMessage(from plist: [String: Any], terminationStatus: Int32) -> String {
        if let message = plist["LocalizedUnlockDispositionMessage"] as? String, message.isEmpty == false {
            return message
        }

        if let errorCode = plist["DiskManagementErrorCode"] as? Int {
            return "diskutil exited with status \(terminationStatus) and DiskManagementErrorCode \(errorCode)"
        }

        return "diskutil exited with status \(terminationStatus)"
    }

}
