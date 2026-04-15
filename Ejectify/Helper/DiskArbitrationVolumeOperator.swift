//
//  DiskArbitrationVolumeOperator.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation
import OSLog
@preconcurrency import DiskArbitration

/// Performs mount and unmount requests via Disk Arbitration for a volume UUID.
enum DiskArbitrationVolumeOperator {

    /// Creates configured Disk Arbitration sessions for shared app/helper usage.
    enum DiskArbitrationSessionFactory {

        /// Creates a Disk Arbitration session and binds callback delivery to the provided queue.
        static func makeSession(dispatchQueue: DispatchQueue) -> DASession? {
            guard let session = DASessionCreate(kCFAllocatorDefault) else {
                return nil
            }

            DASessionSetDispatchQueue(session, dispatchQueue)
            return session
        }
    }

    /// Converts volume UUID values from Disk Arbitration descriptions into Foundation UUID values.
    enum VolumeUUIDResolver {

        /// Extracts and normalizes a volume UUID from a disk description dictionary.
        static func volumeUUID(from diskInfo: [NSString: Any]) -> UUID? {
            guard let rawVolumeUUID = diskInfo[kDADiskDescriptionVolumeUUIDKey] else {
                return nil
            }

            if let volumeUUID = rawVolumeUUID as? UUID {
                return volumeUUID
            }

            if let volumeUUIDString = rawVolumeUUID as? String {
                return UUID(uuidString: volumeUUIDString)
            }

            let rawCoreFoundationValue = rawVolumeUUID as CFTypeRef
            if CFGetTypeID(rawCoreFoundationValue) == CFUUIDGetTypeID() {
                let coreFoundationUUID = rawCoreFoundationValue as! CFUUID
                let volumeUUIDString = CFUUIDCreateString(kCFAllocatorDefault, coreFoundationUUID) as String
                return UUID(uuidString: volumeUUIDString)
            }

            return nil
        }
    }

    /// Represents the supported mount-state operations routed through Disk Arbitration.
    enum Operation {
        case mount
        case unmount(force: Bool)

        /// Human-readable operation name used in logs and error messages.
        var operationName: String {
            switch self {
            case .mount:
                return "mount"
            case .unmount(let force):
                return force ? "forced unmount" : "unmount"
            }
        }
    }

    /// Captures the outcome of a Disk Arbitration operation.
    struct OperationResult {

        /// Indicates whether the requested operation succeeded.
        let success: Bool

        /// Optional descriptive message for logging and diagnostics.
        let message: String?

        /// Optional Disk Arbitration status returned by a dissenter on failure.
        let status: DAReturn?
    }

    /// Holds callback completion state for a single asynchronous Disk Arbitration request.
    private final class CallbackState {

        /// Signals when the asynchronous callback has produced a result.
        let semaphore = DispatchSemaphore(value: 0)

        /// Operation result populated by the callback closure.
        var result = OperationResult(success: false, message: "No response from Disk Arbitration callback", status: nil)
    }

    /// Logger shared by all disk operation paths.
    private static let logger = Logger(subsystem: "nl.nielsmouthaan.Ejectify", category: "DiskArbitrationVolumeOperator")

    /// Shared callback queue used by the shared Disk Arbitration session.
    private static let callbackQueue = DispatchQueue(
        label: "nl.nielsmouthaan.Ejectify.DiskArbitrationVolumeOperator",
        qos: .userInitiated
    )

    /// Shared Disk Arbitration session for mount/unmount operations.
    nonisolated(unsafe) private static let diskArbitrationSession: DASession? = DiskArbitrationSessionFactory.makeSession(dispatchQueue: callbackQueue)

    /// Executes a Disk Arbitration mount/unmount operation and waits for callback completion, using the BSD name as a fast-path resolve hint before UUID scanning.
    static func perform(
        volumeUUID: UUID,
        volumeName: String,
        bsdName: String,
        operation: Operation,
        timeout: TimeInterval = 15
    ) -> OperationResult {
        guard let session = diskArbitrationSession else {
            return OperationResult(success: false, message: "Disk Arbitration session unavailable", status: nil)
        }

        guard let disk = resolveDisk(volumeUUID: volumeUUID, volumeName: volumeName, bsdName: bsdName, session: session) else {
            return OperationResult(success: false, message: "Disk for requested volume not found", status: Int32(kDAReturnNotFound))
        }

        if case .mount = operation, isMounted(disk: disk) {
            return OperationResult(success: true, message: "Volume already mounted", status: nil)
        }
        if case .unmount = operation, !isMounted(disk: disk) {
            return OperationResult(success: true, message: "Volume already unmounted", status: nil)
        }

        let callbackState = CallbackState()
        let callbackContext = Unmanaged.passRetained(callbackState).toOpaque()

        switch operation {
        case .mount:
            DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), { _, dissenter, context in
                guard let context else {
                    return
                }

                let callbackState = Unmanaged<CallbackState>.fromOpaque(context).takeRetainedValue()
                callbackState.result = DiskArbitrationVolumeOperator.callbackResult(for: dissenter)
                callbackState.semaphore.signal()
            }, callbackContext)
        case .unmount(let force):
            let option = force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault
            DADiskUnmount(disk, DADiskUnmountOptions(option), { _, dissenter, context in
                guard let context else {
                    return
                }

                let callbackState = Unmanaged<CallbackState>.fromOpaque(context).takeRetainedValue()
                callbackState.result = DiskArbitrationVolumeOperator.callbackResult(for: dissenter)
                callbackState.semaphore.signal()
            }, callbackContext)
        }

        let waitResult = callbackState.semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            return OperationResult(success: false, message: "\(operation.operationName) timed out", status: nil)
        }

        return callbackState.result
    }

    /// Returns whether the requested volume is currently resolvable via Disk Arbitration.
    static func canResolveDisk(volumeUUID: UUID, volumeName: String, bsdName: String) -> Bool {
        guard let session = diskArbitrationSession else {
            return false
        }

        return resolveDisk(volumeUUID: volumeUUID, volumeName: volumeName, bsdName: bsdName, session: session, logFailures: false) != nil
    }

    /// Returns whether Disk Arbitration currently reports a mounted volume path for this disk.
    private static func isMounted(disk: DADisk) -> Bool {
        guard let diskInfo = DADiskCopyDescription(disk) as? [NSString: Any] else {
            return false
        }
        return diskInfo[kDADiskDescriptionVolumePathKey] != nil
    }

    /// Resolves a Disk Arbitration disk, trying the provided BSD name first and falling back to UUID scan.
    private static func resolveDisk(
        volumeUUID: UUID,
        volumeName: String,
        bsdName: String,
        session: DASession,
        logFailures: Bool = true
    ) -> DADisk? {
        let requestedVolumeLabel = VolumeLogLabelFormatter.label(
            name: volumeName,
            uuid: volumeUUID,
            bsdName: bsdName
        )

        if !bsdName.isEmpty {
            if let disk = resolveDiskByBSDName(bsdName, volumeUUID: volumeUUID, session: session) {
                let resolvedVolumeLabel = resolvedVolumeLabel(
                    for: disk,
                    fallbackName: volumeName,
                    fallbackUUID: volumeUUID,
                    fallbackBSDName: bsdName
                )
                logger.info("Disk resolved for \(resolvedVolumeLabel, privacy: .public) based on BSD name")
                return disk
            }
        }

        if let disk = resolveDiskByVolumeUUIDScan(volumeUUID: volumeUUID, session: session) {
            let resolvedVolumeLabel = resolvedVolumeLabel(
                for: disk,
                fallbackName: volumeName,
                fallbackUUID: volumeUUID,
                fallbackBSDName: bsdName
            )
            logger.info("Disk resolved for \(resolvedVolumeLabel, privacy: .public) by scanning devices")
            return disk
        }

        if logFailures {
            logger.error("Disk resolve failed for \(requestedVolumeLabel, privacy: .public)")
        }
        return nil
    }

    /// Builds a log label from the resolved disk metadata, falling back to the originally requested identifiers when needed.
    private static func resolvedVolumeLabel(
        for disk: DADisk,
        fallbackName: String,
        fallbackUUID: UUID,
        fallbackBSDName: String
    ) -> String {
        guard let diskInfo = DADiskCopyDescription(disk) as? [NSString: Any] else {
            return VolumeLogLabelFormatter.label(name: fallbackName, uuid: fallbackUUID, bsdName: fallbackBSDName)
        }

        let resolvedName = (diskInfo[kDADiskDescriptionVolumeNameKey] as? String) ?? fallbackName
        let resolvedUUID = VolumeUUIDResolver.volumeUUID(from: diskInfo) ?? fallbackUUID
        let resolvedBSDName = (diskInfo[kDADiskDescriptionMediaBSDNameKey] as? String) ?? fallbackBSDName

        return VolumeLogLabelFormatter.label(name: resolvedName, uuid: resolvedUUID, bsdName: resolvedBSDName)
    }

    /// Resolves a disk using a BSD name when it matches the requested volume UUID.
    private static func resolveDiskByBSDName(_ bsdName: String, volumeUUID targetVolumeUUID: UUID, session: DASession) -> DADisk? {
        let matchedDisk = bsdName.withCString { rawBSDName in
            DADiskCreateFromBSDName(kCFAllocatorDefault, session, rawBSDName)
        }

        guard let disk = matchedDisk,
              let diskInfo = DADiskCopyDescription(disk) as? [NSString: Any],
              let resolvedUUID = VolumeUUIDResolver.volumeUUID(from: diskInfo),
              resolvedUUID == targetVolumeUUID else {
            return nil
        }

        return disk
    }

    /// Resolves a disk by scanning `/dev` and matching each disk description's volume UUID.
    private static func resolveDiskByVolumeUUIDScan(volumeUUID targetVolumeUUID: UUID, session: DASession) -> DADisk? {
        let devURL = URL(fileURLWithPath: "/dev", isDirectory: true)
        let deviceNames = (try? FileManager.default.contentsOfDirectory(atPath: devURL.path)) ?? []

        for deviceName in deviceNames where deviceName.range(of: "^disk[0-9]+(s[0-9]+)?$", options: .regularExpression) != nil {
            let matchedDisk = deviceName.withCString { bsdName in
                DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName)
            }

            guard let disk = matchedDisk,
                  let diskInfo = DADiskCopyDescription(disk) as? [NSString: Any],
                  let resolvedUUID = VolumeUUIDResolver.volumeUUID(from: diskInfo),
                  resolvedUUID == targetVolumeUUID else {
                continue
            }

            return disk
        }

        return nil
    }

    /// Converts a Disk Arbitration dissenter into an operation result.
    private static func callbackResult(for dissenter: DADissenter?) -> OperationResult {
        guard let dissenter else {
            return OperationResult(success: true, message: nil, status: nil)
        }

        let status = DADissenterGetStatus(dissenter)
        let statusReason = DADissenterGetStatusString(dissenter) as String?

        let message: String
        if let statusReason, !statusReason.isEmpty {
            message = "Disk Arbitration status: \(status.statusDescription) (\(statusReason))"
        } else {
            message = "Disk Arbitration status: \(status.statusDescription)"
        }

        return OperationResult(success: false, message: message, status: status)
    }
}
