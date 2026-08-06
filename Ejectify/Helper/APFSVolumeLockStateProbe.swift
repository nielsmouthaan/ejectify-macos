//
//  APFSVolumeLockStateProbe.swift
//  Ejectify
//
//  Created by Codex on 06/08/2026.
//

import Foundation

/// Reads the live locked state of an encrypted APFS volume using structured `diskutil` output.
final class APFSVolumeLockStateProbe: @unchecked Sendable {

    /// Represents the live APFS lock state when it can be determined safely.
    enum LockState: Equatable, Sendable {
        case locked
        case unlocked
        case unknown
    }

    /// Immutable volume metadata safe to pass to the background probe queue.
    struct Request: Sendable {

        /// Volume identifiers tried in priority order.
        let identifiers: [String]

        /// Privacy-safe correlation label used in diagnostics.
        let logLabel: String

        /// Creates a request that prefers the stable volume UUID and falls back to the BSD name.
        init(volume: Volume) {
            var identifiers: [String] = []

            if let diskUUID = volume.diskUUID {
                identifiers.append(diskUUID.uuidString)
            }

            if !identifiers.contains(volume.bsdName) {
                identifiers.append(volume.bsdName)
            }

            self.identifiers = identifiers
            logLabel = volume.logLabel
        }
    }

    /// Shared probe used by automatic remount handling.
    static let shared = APFSVolumeLockStateProbe()

    /// Queue that keeps `diskutil` execution off the main actor.
    private let queue = DispatchQueue(
        label: "nl.nielsmouthaan.Ejectify.APFSVolumeLockStateProbe",
        qos: .userInitiated
    )

    /// Returns the live encrypted APFS lock state for one volume.
    func lockState(request: Request) async -> LockState {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.performProbe(request: request))
            }
        }
    }

    /// Tries each identifier until structured volume state can be classified.
    private static func performProbe(request: Request) -> LockState {
        for (index, identifier) in request.identifiers.enumerated() {
            let result = runDiskutilInfo(identifier: identifier)

            switch result {
            case .locked:
                if index > 0 {
                    Log.volumeOperations.info("Encrypted APFS lock-state probe used BSD-name fallback for \(request.logLabel)")
                }
                Log.volumeOperations.log("Encrypted APFS volume is locked after mount failure for \(request.logLabel)")
                return .locked
            case .unlocked:
                if index > 0 {
                    Log.volumeOperations.info("Encrypted APFS lock-state probe used BSD-name fallback for \(request.logLabel)")
                }
                Log.volumeOperations.info("Encrypted APFS volume is already unlocked after mount failure for \(request.logLabel)")
                return .unlocked
            case .unknown:
                continue
            }
        }

        Log.volumeOperations.warning("Encrypted APFS lock state could not be determined after mount failure for \(request.logLabel)")
        return .unknown
    }

    /// Runs one structured `diskutil info` query without retaining raw command output.
    private static func runDiskutilInfo(identifier: String) -> LockState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", identifier]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .unknown
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return classifyLockState(terminationStatus: process.terminationStatus, output: output)
    }

    /// Classifies structured `diskutil info -plist` output without matching localized text.
    static func classifyLockState(terminationStatus: Int32, output: Data) -> LockState {
        guard terminationStatus == 0,
              let plist = (try? PropertyListSerialization.propertyList(from: output, options: [], format: nil)) as? [String: Any],
              (plist["FilesystemType"] as? String)?.lowercased() == "apfs",
              plist["Encryption"] as? Bool == true,
              let isLocked = plist["Locked"] as? Bool else {
            return .unknown
        }

        return isLocked ? .locked : .unlocked
    }
}
