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

    enum Operation {
        case mount
        case unmount(force: Bool)

        var operationName: String {
            switch self {
            case .mount:
                return "mount"
            case .unmount(let force):
                return force ? "forced unmount" : "unmount"
            }
        }
    }

    private final class CallbackState {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Bool, String?) = (false, "No response from Disk Arbitration callback")
    }

    private static let logger = Logger(subsystem: "nl.nielsmouthaan.Ejectify", category: "DiskArbitrationVolumeOperator")

    /// Shared callback queue used by the shared Disk Arbitration session.
    private static let callbackQueue = DispatchQueue(
        label: "nl.nielsmouthaan.Ejectify.DiskArbitrationVolumeOperator",
        qos: .userInitiated
    )

    /// Shared Disk Arbitration session for mount/unmount operations.
    nonisolated(unsafe) private static let diskArbitrationSession: DASession? = DiskArbitrationSessionFactory.makeSession(dispatchQueue: callbackQueue)

    /// Executes a Disk Arbitration mount/unmount operation and waits for callback completion.
    /// The BSD name is used as a fast-path resolve hint before UUID scanning.
    static func perform(
        volumeUUID: UUID,
        volumeName: String,
        bsdName: String,
        operation: Operation,
        timeout: TimeInterval = 15
    ) -> (Bool, String?) {
        guard let session = diskArbitrationSession else {
            return (false, "Disk Arbitration session unavailable")
        }

        guard let disk = resolveDisk(volumeUUID: volumeUUID, volumeName: volumeName, bsdName: bsdName, session: session) else {
            return (false, "Disk for requested volume not found")
        }

        if case .mount = operation, isMounted(disk: disk) {
            return (true, "Volume already mounted")
        }
        if case .unmount = operation, !isMounted(disk: disk) {
            return (true, "Volume already unmounted")
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
            return (false, "\(operation.operationName) timed out")
        }

        return callbackState.result
    }

    /// Returns whether Disk Arbitration currently reports a mounted volume path for this disk.
    private static func isMounted(disk: DADisk) -> Bool {
        guard let diskInfo = DADiskCopyDescription(disk) as? [NSString: Any] else {
            return false
        }
        return diskInfo[kDADiskDescriptionVolumePathKey] != nil
    }

    /// Resolves a Disk Arbitration disk, trying the provided BSD name first and falling back to UUID scan.
    private static func resolveDisk(volumeUUID: UUID, volumeName: String, bsdName: String, session: DASession) -> DADisk? {
        let targetVolumeLabel = VolumeLogLabelFormatter.label(
            name: volumeName,
            uuid: volumeUUID,
            bsdName: bsdName
        )

        if !bsdName.isEmpty {
            if let disk = resolveDiskByBSDName(bsdName, volumeUUID: volumeUUID, session: session) {
                logger.info("Disk resolved for \(targetVolumeLabel, privacy: .public) based on BSD name")
                return disk
            }
        }

        if let disk = resolveDiskByVolumeUUIDScan(volumeUUID: volumeUUID, session: session) {
            logger.info("Disk resolved for \(targetVolumeLabel, privacy: .public) by scanning devices")
            return disk
        }

        logger.error("Disk resolve failed for \(targetVolumeLabel, privacy: .public)")
        return nil
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

    /// Converts a Disk Arbitration dissenter into a success/failure tuple.
    private static func callbackResult(for dissenter: DADissenter?) -> (Bool, String?) {
        guard let dissenter else {
            return (true, nil)
        }

        let status = DADissenterGetStatus(dissenter)
        return (false, "Disk Arbitration status: \(status.statusDescription)")
    }
}
