//
//  DiskArbitrationVolumeOperator.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation
@preconcurrency import DiskArbitration

/// Performs mount, unmount, and whole-disk eject requests via Disk Arbitration.
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

    /// Converts Disk Arbitration UUID values into Foundation UUID values.
    enum DiskUUIDResolver {

        /// Extracts and normalizes the best available UUID from a disk description dictionary.
        static func diskUUID(from diskInfo: [NSString: Any]) -> UUID? {
            uuid(for: kDADiskDescriptionVolumeUUIDKey, from: diskInfo) ?? uuid(for: kDADiskDescriptionMediaUUIDKey, from: diskInfo)
        }

        /// Extracts and normalizes a UUID for the given Disk Arbitration description key.
        private static func uuid(for key: CFString, from diskInfo: [NSString: Any]) -> UUID? {
            guard let rawUUID = diskInfo[key] else {
                return nil
            }

            if let uuid = rawUUID as? UUID {
                return uuid
            }

            if let uuidString = rawUUID as? String {
                return UUID(uuidString: uuidString)
            }

            let rawCoreFoundationValue = rawUUID as CFTypeRef
            if CFGetTypeID(rawCoreFoundationValue) == CFUUIDGetTypeID() {
                let coreFoundationUUID = rawCoreFoundationValue as! CFUUID
                let uuidString = CFUUIDCreateString(kCFAllocatorDefault, coreFoundationUUID) as String
                return UUID(uuidString: uuidString)
            }

            return nil
        }
    }

    /// Represents the supported mount-state operations routed through Disk Arbitration.
    enum Operation {
        case mount
        case unmount(force: Bool)
        case eject(forceUnmount: Bool)

        /// Human-readable operation name used in logs and error messages.
        var operationName: String {
            switch self {
            case .mount:
                return "mount"
            case .unmount(let force):
                return force ? "forced unmount" : "unmount"
            case .eject(let forceUnmount):
                return forceUnmount ? "eject with forced unmount" : "eject"
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

    /// Callback signature shared by Disk Arbitration mount, unmount, and eject requests.
    private typealias DiskOperationCallback = @convention(c) (DADisk, DADissenter?, UnsafeMutableRawPointer?) -> Void

    /// Completes a pending synchronous wait with the result of a Disk Arbitration callback.
    private static let diskOperationCallback: DiskOperationCallback = { _, dissenter, context in
        guard let context else {
            return
        }

        let callbackState = Unmanaged<CallbackState>.fromOpaque(context).takeRetainedValue()
        callbackState.result = DiskArbitrationVolumeOperator.callbackResult(for: dissenter)
        callbackState.semaphore.signal()
    }

    /// Options matching `diskutil eject force` preparation by force-unmounting every volume on the whole disk.
    static let forcedEjectUnmountOptions = DADiskUnmountOptions(kDADiskUnmountOptionForce | kDADiskUnmountOptionWhole)

    /// Shared callback queue used by the shared Disk Arbitration session.
    private static let callbackQueue = DispatchQueue(
        label: "nl.nielsmouthaan.Ejectify.DiskArbitrationVolumeOperator",
        qos: .userInitiated
    )

    /// Shared Disk Arbitration session for mount-state operations.
    nonisolated(unsafe) private static let diskArbitrationSession: DASession? = DiskArbitrationSessionFactory.makeSession(dispatchQueue: callbackQueue)

    /// Executes a Disk Arbitration mount-state operation and waits for callback completion, using the BSD name as a fast-path resolve hint before UUID scanning.
    static func perform(
        volumeUUID: UUID?,
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

        switch operation {
        case .mount:
            return performRequest(operationName: operation.operationName, timeout: timeout) { callback, context in
                DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), callback, context)
            }
        case .eject(let forceUnmount):
            guard let wholeDisk = DADiskCopyWholeDisk(disk) else {
                return OperationResult(
                    success: false,
                    message: "Whole disk for requested volume not found",
                    status: Int32(kDAReturnNotFound)
                )
            }

            return performEjectSequence(
                forceUnmount: forceUnmount,
                unmountWholeDisk: {
                    performRequest(operationName: "forced whole-disk unmount", timeout: timeout) { callback, context in
                        DADiskUnmount(wholeDisk, forcedEjectUnmountOptions, callback, context)
                    }
                },
                eject: {
                    performRequest(operationName: "eject", timeout: timeout) { callback, context in
                        DADiskEject(wholeDisk, DADiskEjectOptions(kDADiskEjectOptionDefault), callback, context)
                    }
                }
            )
        case .unmount(let force):
            let option = force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault
            return performRequest(operationName: operation.operationName, timeout: timeout) { callback, context in
                DADiskUnmount(disk, DADiskUnmountOptions(option), callback, context)
            }
        }
    }

    /// Performs optional forced-unmount preparation followed by a normal eject request.
    static func performEjectSequence(
        forceUnmount: Bool,
        unmountWholeDisk: () -> OperationResult,
        eject: () -> OperationResult
    ) -> OperationResult {
        guard forceUnmount else {
            return eject()
        }

        let unmountResult = unmountWholeDisk()
        guard unmountResult.success else {
            return unmountResult.withMessagePrefix("Forced whole-disk unmount before eject failed")
        }

        let ejectResult = eject()
        guard ejectResult.success else {
            return ejectResult.withMessagePrefix("Eject after forced whole-disk unmount failed")
        }

        return OperationResult(
            success: true,
            message: "Forced whole-disk unmount completed before eject",
            status: nil
        )
    }

    /// Starts one Disk Arbitration request and waits synchronously for its callback or timeout.
    private static func performRequest(
        operationName: String,
        timeout: TimeInterval,
        request: (DiskOperationCallback, UnsafeMutableRawPointer) -> Void
    ) -> OperationResult {
        let callbackState = CallbackState()
        let callbackContext = Unmanaged.passRetained(callbackState).toOpaque()
        request(diskOperationCallback, callbackContext)

        let waitResult = callbackState.semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            return OperationResult(success: false, message: "\(operationName) timed out", status: nil)
        }

        return callbackState.result
    }

    /// Returns whether the requested volume is currently resolvable via Disk Arbitration.
    static func canResolveDisk(volumeUUID: UUID?, volumeName: String, bsdName: String) -> Bool {
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
        volumeUUID: UUID?,
        volumeName: String,
        bsdName: String,
        session: DASession,
        logFailures: Bool = true
    ) -> DADisk? {
        let requestedVolumeLabel = VolumeLogLabelFormatter.label(
            uuid: volumeUUID,
            bsdName: bsdName
        )

        if !bsdName.isEmpty {
            if let disk = resolveDiskByBSDName(bsdName, volumeUUID: volumeUUID, volumeName: volumeName, session: session) {
                let resolvedVolumeLabel = resolvedVolumeLabel(
                    for: disk,
                    fallbackUUID: volumeUUID,
                    fallbackBSDName: bsdName
                )
                Log.volumeOperations.info("Disk resolved for \(resolvedVolumeLabel) based on BSD name")
                return disk
            }
        }

        if let volumeUUID,
           let disk = resolveDiskByVolumeUUIDScan(volumeUUID: volumeUUID, session: session) {
            let resolvedVolumeLabel = resolvedVolumeLabel(
                for: disk,
                fallbackUUID: volumeUUID,
                fallbackBSDName: bsdName
            )
            Log.volumeOperations.info("Disk resolved for \(resolvedVolumeLabel) by scanning devices")
            return disk
        }

        if logFailures {
            Log.volumeOperations.error("Disk resolve failed for \(requestedVolumeLabel)")
        }
        return nil
    }

    /// Builds a log label from the resolved disk metadata, falling back to the originally requested identifiers when needed.
    private static func resolvedVolumeLabel(
        for disk: DADisk,
        fallbackUUID: UUID?,
        fallbackBSDName: String
    ) -> String {
        guard let diskInfo = DADiskCopyDescription(disk) as? [NSString: Any] else {
            return VolumeLogLabelFormatter.label(uuid: fallbackUUID, bsdName: fallbackBSDName)
        }

        let resolvedUUID = DiskUUIDResolver.diskUUID(from: diskInfo) ?? fallbackUUID
        let resolvedBSDName = (diskInfo[kDADiskDescriptionMediaBSDNameKey] as? String) ?? fallbackBSDName

        return VolumeLogLabelFormatter.label(uuid: resolvedUUID, bsdName: resolvedBSDName)
    }

    /// Resolves a disk using a BSD name, validating UUID metadata when it is available.
    private static func resolveDiskByBSDName(
        _ bsdName: String,
        volumeUUID targetVolumeUUID: UUID?,
        volumeName targetVolumeName: String,
        session: DASession
    ) -> DADisk? {
        let matchedDisk = bsdName.withCString { rawBSDName in
            DADiskCreateFromBSDName(kCFAllocatorDefault, session, rawBSDName)
        }

        guard let disk = matchedDisk,
              let diskInfo = DADiskCopyDescription(disk) as? [NSString: Any] else {
            return nil
        }

        if let targetVolumeUUID {
            guard let resolvedUUID = DiskUUIDResolver.diskUUID(from: diskInfo),
                  resolvedUUID == targetVolumeUUID else {
                return nil
            }
        } else if let resolvedName = diskInfo[kDADiskDescriptionVolumeNameKey] as? String,
                  !resolvedName.isEmpty,
                  resolvedName != targetVolumeName {
            return nil
        }

        return disk
    }

    /// Resolves a disk by scanning `/dev` and matching each disk description's UUID.
    private static func resolveDiskByVolumeUUIDScan(volumeUUID targetVolumeUUID: UUID, session: DASession) -> DADisk? {
        let devURL = URL(fileURLWithPath: "/dev", isDirectory: true)
        let deviceNames = (try? FileManager.default.contentsOfDirectory(atPath: devURL.path)) ?? []

        for deviceName in deviceNames where deviceName.range(of: "^disk[0-9]+(s[0-9]+)?$", options: .regularExpression) != nil {
            let matchedDisk = deviceName.withCString { bsdName in
                DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName)
            }

            guard let disk = matchedDisk,
                  let diskInfo = DADiskCopyDescription(disk) as? [NSString: Any],
                  let resolvedUUID = DiskUUIDResolver.diskUUID(from: diskInfo),
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

private extension DiskArbitrationVolumeOperator.OperationResult {

    /// Returns this result with stage context prepended to its diagnostic message.
    func withMessagePrefix(_ prefix: String) -> Self {
        let details = message.map { "\(prefix): \($0)" } ?? prefix
        return Self(success: success, message: details, status: status)
    }
}
