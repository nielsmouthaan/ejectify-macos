//
//  PrivilegedDiskService.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation

/// Implements authenticated privileged endpoints for fixed diskutil and notification-muting operations.
final class PrivilegedDiskService: NSObject, PrivilegedDiskServiceProtocol {

    /// Stores XPC replies so they can cross sendable dispatch boundaries.
    private final class OperationReplyBox: @unchecked Sendable {
        let reply: (Bool, String?, Int32) -> Void

        init(reply: @escaping (Bool, String?, Int32) -> Void) {
            self.reply = reply
        }
    }

    /// Stores lock-state replies so they can cross sendable dispatch boundaries.
    private final class LockStateReplyBox: @unchecked Sendable {
        let reply: (String) -> Void

        init(reply: @escaping (String) -> Void) {
            self.reply = reply
        }
    }

    /// Stores unlock replies so they can cross sendable dispatch boundaries.
    private final class UnlockReplyBox: @unchecked Sendable {
        let reply: (Bool, String, Int32, Int, NSNumber?, NSNumber?, NSNumber?) -> Void

        init(reply: @escaping (Bool, String, Int32, Int, NSNumber?, NSNumber?, NSNumber?) -> Void) {
            self.reply = reply
        }
    }

    /// Queue used to execute diskutil requests concurrently.
    private let operationQueue = DispatchQueue(
        label: "nl.nielsmouthaan.Ejectify.PrivilegedHelper.Diskutil",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Reports support for the current fixed diskutil protocol.
    func capabilityVersion(withReply reply: @escaping (Int) -> Void) {
        reply(PrivilegedHelperConfiguration.diskutilCapabilityVersion)
    }

    /// Runs diskutil mount for one validated volume identity.
    func mount(volumeUUID: NSUUID?, volumeName _: String, bsdName: String, withReply reply: @escaping (Bool, String?, Int32) -> Void) {
        perform(operation: .mount, identityUUID: volumeUUID.map { $0 as UUID }, bsdName: bsdName, reply: reply)
    }

    /// Runs diskutil unmount for one validated volume identity.
    func unmount(volumeUUID: NSUUID?, volumeName _: String, bsdName: String, force: Bool, withReply reply: @escaping (Bool, String?, Int32) -> Void) {
        perform(operation: .unmount(force: force), identityUUID: volumeUUID.map { $0 as UUID }, bsdName: bsdName, reply: reply)
    }

    /// Runs diskutil eject for one validated volume identity.
    func eject(volumeUUID: NSUUID?, volumeName _: String, bsdName: String, forceUnmount: Bool, withReply reply: @escaping (Bool, String?, Int32) -> Void) {
        perform(operation: .eject(force: forceUnmount), identityUUID: volumeUUID.map { $0 as UUID }, bsdName: bsdName, reply: reply)
    }

    /// Reads encrypted APFS lock state through the shared diskutil operator.
    func inspectAPFSLockState(volumeUUID: NSUUID?, bsdName: String, withReply reply: @escaping (String) -> Void) {
        let replyBox = LockStateReplyBox(reply: reply)
        let identityUUID = volumeUUID.map { $0 as UUID }
        guard DiskutilOperator.isValidBSDName(bsdName) else {
            Log.privilegedHelper.error("Rejected APFS lock-state request with invalid BSD target")
            reply(DiskutilOperator.LockState.unknown.rawValue)
            return
        }

        operationQueue.async {
            let state = DiskutilOperator.lockState(identityUUID: identityUUID, bsdName: bsdName)
            Log.privilegedHelper.log("diskutil APFS lock-state completed; state=\(state.rawValue); \(VolumeLogLabelFormatter.label(uuid: identityUUID, bsdName: bsdName))")
            replyBox.reply(state.rawValue)
        }
    }

    /// Unlocks encrypted APFS through the shared diskutil operator.
    func unlockAPFSVolume(
        volumeUUID: NSUUID?,
        bsdName: String,
        password: String,
        withReply reply: @escaping (Bool, String, Int32, Int, NSNumber?, NSNumber?, NSNumber?) -> Void
    ) {
        let replyBox = UnlockReplyBox(reply: reply)
        let identityUUID = volumeUUID.map { $0 as UUID }
        guard DiskutilOperator.isValidBSDName(bsdName) else {
            Log.privilegedHelper.error("Rejected APFS unlock request with invalid BSD target")
            reply(false, DiskutilOperator.UnlockOutcome.invalidTarget.rawValue, Int32.min, 0, nil, nil, nil)
            return
        }

        operationQueue.async {
            let result = DiskutilOperator.unlock(
                identityUUID: identityUUID,
                bsdName: bsdName,
                password: password
            )
            let metadata = result.metadata
            let label = VolumeLogLabelFormatter.label(uuid: identityUUID, bsdName: bsdName)
            let details = "outcome=\(result.outcome.rawValue); exitCode=\(result.exitCode.map(String.init) ?? "none"); terminationReason=\(result.terminationReason.rawValue); durationMilliseconds=\(result.durationMilliseconds); timeout=\(result.timedOut); diskManagementErrorCode=\(metadata.diskManagementErrorCode.map(String.init) ?? "none"); rateLimitBackoff=\(metadata.rateLimitBackoff.map(String.init) ?? "none"); rateLimitLockout=\(metadata.rateLimitLockout.map(String.init) ?? "none"); \(label)"
            if result.success {
                Log.privilegedHelper.log("diskutil APFS unlock completed; \(details)")
            } else {
                Log.privilegedHelper.error("diskutil APFS unlock failed; \(details)")
            }
            replyBox.reply(
                result.success,
                result.outcome.rawValue,
                result.exitCode ?? Int32.min,
                result.durationMilliseconds,
                metadata.diskManagementErrorCode.map(NSNumber.init(value:)),
                metadata.rateLimitBackoff.map(NSNumber.init(value:)),
                metadata.rateLimitLockout.map(NSNumber.init(value:))
            )
        }
    }

    /// Updates Disk Arbitration eject-notification muting through defaults.
    func setEjectNotificationsMuted(muted: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        let arguments = muted
            ? ["write", PrivilegedHelperConfiguration.diskArbitrationPreferencesPath, PrivilegedHelperConfiguration.disableEjectNotificationKey, "-bool", "YES"]
            : ["write", PrivilegedHelperConfiguration.diskArbitrationPreferencesPath, PrivilegedHelperConfiguration.disableEjectNotificationKey, "-bool", "NO"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.privilegedHelper.error(error, message: "Failed to launch defaults while changing eject notification setting")
            reply(false, "launchFailed")
            return
        }

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            Log.privilegedHelper.error("Failed to change Disk Arbitration eject notification setting; exitCode=\(process.terminationStatus)")
            reply(false, "failed")
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

    /// Executes one fixed diskutil mutation and returns the compatible XPC reply.
    private func perform(
        operation: DiskutilOperator.Operation,
        identityUUID: UUID?,
        bsdName: String,
        reply: @escaping (Bool, String?, Int32) -> Void
    ) {
        let replyBox = OperationReplyBox(reply: reply)
        guard DiskutilOperator.isValidBSDName(bsdName) else {
            Log.privilegedHelper.error("Rejected diskutil request with invalid BSD target")
            reply(false, DiskutilOperator.Outcome.invalidTarget.rawValue, Int32.min)
            return
        }

        let label = VolumeLogLabelFormatter.label(uuid: identityUUID, bsdName: bsdName)
        operationQueue.async {
            let result = DiskutilOperator.perform(
                identityUUID: identityUUID,
                bsdName: bsdName,
                operation: operation
            )
            let details = "operation=\(operation.operationName); force=\(operation.isForced); outcome=\(result.outcome.rawValue); exitCode=\(result.exitCode.map(String.init) ?? "none"); terminationReason=\(result.terminationReason.rawValue); durationMilliseconds=\(result.durationMilliseconds); timeout=\(result.timedOut); \(label)"
            if result.success {
                Log.privilegedHelper.log("diskutil operation completed; \(details)")
            } else {
                Log.privilegedHelper.error("diskutil operation failed; \(details)")
            }
            replyBox.reply(result.success, result.outcome.rawValue, result.exitCode ?? Int32.min)
        }
    }
}
