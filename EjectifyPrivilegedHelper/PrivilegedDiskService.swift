//
//  PrivilegedDiskService.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation

/// Implements privileged XPC endpoints for disk and notification-muting operations.
final class PrivilegedDiskService: NSObject, PrivilegedDiskServiceProtocol {

    /// Stores XPC reply closures so they can safely cross sendable dispatch boundaries.
    private final class ReplyBox: @unchecked Sendable {

        /// Reply closure returning success, optional message, and optional status.
        let reply: (Bool, String?, Int32) -> Void

        /// Wraps one XPC reply closure.
        init(reply: @escaping (Bool, String?, Int32) -> Void) {
            self.reply = reply
        }
    }

    /// Stores encrypted recovery replies so they can safely cross sendable dispatch boundaries.
    private final class EncryptedRecoveryReplyBox: @unchecked Sendable {
        let reply: (Int32, String?, Int32, Bool, Bool, Bool, Bool) -> Void

        /// Wraps one encrypted recovery reply closure.
        init(reply: @escaping (Int32, String?, Int32, Bool, Bool, Bool, Bool) -> Void) {
            self.reply = reply
        }
    }

    /// Owns the helper's short-lived mutable passphrase buffer until recovery finishes.
    private final class PassphraseBox: @unchecked Sendable {
        var data: Data

        /// Takes ownership of passphrase bytes received over XPC.
        init(data: Data) {
            self.data = data
        }

        /// Best-effort clears the helper-owned passphrase bytes.
        func clear() {
            data.resetBytes(in: data.indices)
        }
    }

    /// Queue used to execute disk-operation requests concurrently.
    private let operationQueue = DispatchQueue(
        label: "nl.nielsmouthaan.Ejectify.PrivilegedHelper.DiskOperation",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Confirms helper reachability for startup routing checks.
    func ping(withReply reply: @escaping (Bool, String?) -> Void) {
        reply(true, nil)
    }

    /// Performs a privileged mount for the provided volume metadata.
    func mount(volumeUUID: NSUUID?, volumeName: String, bsdName: String, withReply reply: @escaping (Bool, String?, Int32) -> Void) {
        perform(operation: .mount, volumeUUID: volumeUUID.map { $0 as UUID }, volumeName: volumeName, bsdName: bsdName, reply: reply)
    }

    /// Performs a privileged unmount for the provided volume metadata.
    func unmount(volumeUUID: NSUUID?, volumeName: String, bsdName: String, force: Bool, withReply reply: @escaping (Bool, String?, Int32) -> Void) {
        perform(operation: .unmount(force: force), volumeUUID: volumeUUID.map { $0 as UUID }, volumeName: volumeName, bsdName: bsdName, reply: reply)
    }

    /// Performs a privileged eject, optionally force-unmounting the whole disk first.
    func eject(volumeUUID: NSUUID?, volumeName: String, bsdName: String, forceUnmount: Bool, withReply reply: @escaping (Bool, String?, Int32) -> Void) {
        perform(operation: .eject(forceUnmount: forceUnmount), volumeUUID: volumeUUID.map { $0 as UUID }, volumeName: volumeName, bsdName: bsdName, reply: reply)
    }

    /// Revalidates, unlocks, and mounts an encrypted APFS volume inside the helper process.
    func unlockAndMountEncryptedAPFS(
        volumeUUID: NSUUID?,
        volumeName: String,
        bsdName: String,
        passphraseData: Data,
        withReply reply: @escaping (Int32, String?, Int32, Bool, Bool, Bool, Bool) -> Void
    ) {
        let uuid = volumeUUID.map { $0 as UUID }
        let logLabel = VolumeLogLabelFormatter.label(uuid: uuid, bsdName: bsdName)
        let request = APFSEncryptedVolumeUnlocker.UnlockRequest(
            volumeUUID: uuid,
            volumeName: volumeName,
            bsdName: bsdName,
            logLabel: logLabel,
            executor: .privilegedHelper
        )
        let replyBox = EncryptedRecoveryReplyBox(reply: reply)
        let passphraseBox = PassphraseBox(data: passphraseData)

        operationQueue.async {
            defer {
                passphraseBox.clear()
            }

            let result = APFSEncryptedVolumeUnlocker.performRecovery(
                request: request,
                passphraseData: passphraseBox.data
            )
            let outcome: PrivilegedEncryptedAPFSUnlockOutcome
            let message: String?

            switch result.outcome {
            case .success:
                outcome = .success
                message = nil
            case .invalidPassword:
                outcome = .invalidPassword
                message = nil
            case .failed(let details):
                outcome = .failed
                message = details
            }

            let errorCode = result.diagnostics.diskManagementErrorCode
            let hasRateLimitState = result.diagnostics.rateLimitBackoff != nil
                || result.diagnostics.rateLimitLockout != nil
            replyBox.reply(
                outcome.rawValue,
                message,
                Int32(errorCode ?? 0),
                errorCode != nil,
                hasRateLimitState,
                result.diagnostics.rateLimitBackoff ?? false,
                result.diagnostics.rateLimitLockout ?? false
            )
        }
    }

    /// Updates Disk Arbitration eject-notification muting through `defaults`.
    func setEjectNotificationsMuted(muted: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        let plistPath = PrivilegedHelperConfiguration.diskArbitrationPreferencesPath
        let key = PrivilegedHelperConfiguration.disableEjectNotificationKey
        let defaultsArguments = muted
            ? ["write", plistPath, key, "-bool", "YES"]
            : ["write", plistPath, key, "-bool", "NO"]
        let defaultsResult = runProcess(executableURL: URL(fileURLWithPath: "/usr/bin/defaults"), arguments: defaultsArguments)
        if defaultsResult.exitCode != 0 {
            reply(false, defaultsResult.output)
            return
        }

        Log.privilegedHelper.log("Disk Arbitration eject notification setting changed; muted=\(muted)")
        reply(true, nil)
    }

    /// Terminates the helper process on app request.
    func requestTermination(withReply _: @escaping (Bool, String?) -> Void) {
        Log.privilegedHelper.log("Helper termination request received")
        exit(EXIT_SUCCESS)
    }

    /// Executes a shared Disk Arbitration operation and returns the result through XPC.
    private func perform(
        operation: DiskArbitrationVolumeOperator.Operation,
        volumeUUID: UUID?,
        volumeName: String,
        bsdName: String,
        reply: @escaping (Bool, String?, Int32) -> Void
    ) {
        let replyBox = ReplyBox(reply: reply)
        let volumeLabel = VolumeLogLabelFormatter.label(uuid: volumeUUID, bsdName: bsdName)
        Log.volumeOperations.log("Privileged helper \(operation.operationName) queued for \(volumeLabel)")

        operationQueue.async {
            Log.volumeOperations.info("Privileged helper \(operation.operationName) started for \(volumeLabel)")
            let result = DiskArbitrationVolumeOperator.perform(
                volumeUUID: volumeUUID,
                volumeName: volumeName,
                bsdName: bsdName,
                operation: operation
            )

            if result.success {
                if let message = result.message, !message.isEmpty {
                    Log.volumeOperations.log("Privileged helper \(operation.operationName) finished for \(volumeLabel): \(message)")
                } else {
                    Log.volumeOperations.log("Privileged helper \(operation.operationName) finished for \(volumeLabel)")
                }
            } else {
                if let message = result.message, !message.isEmpty {
                    Log.volumeOperations.error("Privileged helper \(operation.operationName) failed for \(volumeLabel): \(message)")
                } else {
                    Log.volumeOperations.error("Privileged helper \(operation.operationName) failed for \(volumeLabel)")
                }
            }

            replyBox.reply(result.success, result.message, result.status ?? 0)
        }
    }

    /// Executes a system process and returns its exit status with any output.
    private func runProcess(executableURL: URL, arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (1, error.localizedDescription)
        }
    }
}
