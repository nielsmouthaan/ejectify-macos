//
//  PrivilegedDiskService.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation
import OSLog

/// Implements privileged XPC endpoints for mount/unmount and notification muting operations.
final class PrivilegedDiskService: NSObject, PrivilegedDiskServiceProtocol {

    /// Logger used for privileged helper operation diagnostics.
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify.PrivilegedHelper", category: "PrivilegedDiskService")

    /// Confirms helper reachability for startup routing checks.
    func ping(withReply reply: @escaping (Bool, String?) -> Void) {
        reply(true, nil)
    }

    /// Performs a privileged mount for the provided volume metadata.
    func mount(volumeUUID: NSUUID, volumeName: String, bsdName: String, withReply reply: @escaping (Bool, String?, Int32) -> Void) {
        perform(operation: .mount, volumeUUID: volumeUUID as UUID, volumeName: volumeName, bsdName: bsdName, reply: reply)
    }

    /// Performs a privileged unmount for the provided volume metadata.
    func unmount(volumeUUID: NSUUID, volumeName: String, bsdName: String, force: Bool, withReply reply: @escaping (Bool, String?, Int32) -> Void) {
        perform(operation: .unmount(force: force), volumeUUID: volumeUUID as UUID, volumeName: volumeName, bsdName: bsdName, reply: reply)
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

        logger.info("Disk Arbitration eject notifications muted=\(muted, privacy: .public)")
        reply(true, nil)
    }

    /// Terminates the helper process on app request.
    func requestTermination(withReply _: @escaping (Bool, String?) -> Void) {
        logger.info("Received helper termination request from app")
        exit(EXIT_SUCCESS)
    }

    /// Executes a shared Disk Arbitration operation and returns the result through XPC.
    private func perform(
        operation: DiskArbitrationVolumeOperator.Operation,
        volumeUUID: UUID,
        volumeName: String,
        bsdName: String,
        reply: @escaping (Bool, String?, Int32) -> Void
    ) {
        let result = DiskArbitrationVolumeOperator.perform(volumeUUID: volumeUUID, volumeName: volumeName, bsdName: bsdName, operation: operation)
        reply(result.success, result.message, result.status ?? 0)
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
