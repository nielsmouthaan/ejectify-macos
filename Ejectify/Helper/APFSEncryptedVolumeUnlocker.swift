//
//  APFSEncryptedVolumeUnlocker.swift
//  Ejectify
//
//  Created by Codex on 05/08/2026.
//

import Foundation

/// Unlocks encrypted APFS volumes by invoking `diskutil apfs unlockVolume` with the passphrase on standard input.
final class APFSEncryptedVolumeUnlocker: @unchecked Sendable {

    /// Result produced by one unlock attempt.
    enum UnlockResult: Equatable, Sendable {
        case success
        case invalidPassword
        case failed(message: String?)
    }

    /// Immutable volume metadata safe to pass to the background unlock queue.
    struct UnlockRequest: Sendable {

        /// BSD disk identifier passed to `diskutil`.
        let bsdName: String

        /// Privacy-safe correlation label used in diagnostics.
        let logLabel: String

        /// Creates a sendable request from the main-thread volume model.
        init(volume: Volume) {
            bsdName = volume.bsdName
            logLabel = volume.logLabel
        }
    }

    /// Shared unlocker instance used by automatic remount handling.
    static let shared = APFSEncryptedVolumeUnlocker()

    /// DiskManagement error code returned when APFS rejects the supplied authentication.
    private static let authenticationRejectedErrorCode = -69591

    /// Queue that keeps `diskutil` execution off the main actor.
    private let queue = DispatchQueue(
        label: "nl.nielsmouthaan.Ejectify.APFSEncryptedVolumeUnlocker",
        qos: .userInitiated
    )

    /// Attempts to unlock and mount one encrypted APFS volume.
    func unlock(request: UnlockRequest, password: String) async -> UnlockResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.performUnlock(request: request, password: password))
            }
        }
    }

    /// Runs `diskutil apfs unlockVolume` and captures output for result classification.
    private static func performUnlock(request: UnlockRequest, password: String) -> UnlockResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["apfs", "unlockVolume", request.bsdName, "-stdinpassphrase", "-plist"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(Data("\(password)\n".utf8))
            try inputPipe.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {
            Log.volumeOperations.error(error, message: "Encrypted APFS unlock process failed to run for \(request.logLabel)")
            return .failed(message: error.localizedDescription)
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let result = classifyUnlockResult(
            terminationStatus: process.terminationStatus,
            output: output,
            errorOutput: errorOutput
        )

        switch result {
        case .success:
            Log.volumeOperations.log("Encrypted APFS unlock succeeded for \(request.logLabel)")
        case .invalidPassword:
            Log.volumeOperations.warning("Encrypted APFS unlock rejected the supplied password for \(request.logLabel)")
        case .failed:
            Log.volumeOperations.error("Encrypted APFS unlock failed; terminationStatus=\(process.terminationStatus); \(request.logLabel)")
        }

        return result
    }

    /// Classifies `diskutil` plist output without matching human-readable error text.
    static func classifyUnlockResult(
        terminationStatus: Int32,
        output: Data,
        errorOutput: Data
    ) -> UnlockResult {
        guard let plist = unlockPlist(from: output) else {
            let message = sanitizedMessage(output: output, errorOutput: errorOutput)
                ?? "diskutil exited with status \(terminationStatus)"
            return .failed(message: message)
        }

        if plist["Success"] as? Bool == true {
            return .success
        }

        let rateLimitBackoff = (plist["RateLimitStateBackoff"] as? Bool) ?? false
        let rateLimitLockout = (plist["RateLimitStateLockout"] as? Bool) ?? false
        let errorCode = plist["DiskManagementErrorCode"] as? Int

        if errorCode == authenticationRejectedErrorCode && !rateLimitBackoff && !rateLimitLockout {
            return .invalidPassword
        }

        return .failed(message: unlockFailureMessage(from: plist, terminationStatus: terminationStatus))
    }

    /// Parses the plist emitted by `diskutil apfs unlockVolume -plist`.
    private static func unlockPlist(from output: Data) -> [String: Any]? {
        guard !output.isEmpty else {
            return nil
        }

        return (try? PropertyListSerialization.propertyList(from: output, options: [], format: nil)) as? [String: Any]
    }

    /// Builds a user-facing failure message from structured plist output.
    private static func unlockFailureMessage(from plist: [String: Any], terminationStatus: Int32) -> String {
        if let message = plist["LocalizedUnlockDispositionMessage"] as? String, !message.isEmpty {
            return message
        }

        if let errorCode = plist["DiskManagementErrorCode"] as? Int {
            return "diskutil exited with status \(terminationStatus) and DiskManagementErrorCode \(errorCode)"
        }

        return "diskutil exited with status \(terminationStatus)"
    }

    /// Combines command output while avoiding empty user-facing messages.
    private static func sanitizedMessage(output: Data, errorOutput: Data) -> String? {
        let outputString = String(data: output, encoding: .utf8) ?? ""
        let errorString = String(data: errorOutput, encoding: .utf8) ?? ""
        let message = [outputString, errorString]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return message.isEmpty ? nil : message
    }
}
