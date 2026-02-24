//
//  ExternalVolume.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import Foundation
import OSLog
@preconcurrency import DiskArbitration

private let volumesPathComponent = "Volumes"
private let efiVolumeName = "EFI"

/// Represents an external/ejectable volume and provides mount/unmount operations.
class ExternalVolume {
    /// Holds callback metadata until Disk Arbitration completion handlers run.
    private final class CallbackLogContext {
        let volumeName: String
        let operation: String

        /// Creates callback metadata used for structured completion logging.
        init(volumeName: String, operation: String) {
            self.volumeName = volumeName
            self.operation = operation
        }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "ExternalVolume")
    /// Shared user defaults store for per-volume preferences.
    private static var userDefaults: UserDefaults { UserDefaults.standard }

    /// Shared Disk Arbitration session retained for the lifetime of the app so asynchronous callbacks are delivered reliably.
    nonisolated(unsafe) private static let diskArbitrationSession: DASession? = {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            logger.error("Failed to create Disk Arbitration session")
            return nil
        }

        DASessionSetDispatchQueue(session, DispatchQueue.main)
        return session
    }()

    /// Disk Arbitration handle used to identify and mount/unmount this volume.
    let disk: DADisk
    /// Stable UUID-backed identifier used for persisted per-volume settings.
    let id: String
    /// Human-readable volume name displayed in UI and logs.
    let name: String

    private static let userDefaultsKeyPrefixVolume = "volume."
    /// Tracks whether this volume should be managed automatically. Defaults to enabled.
    var enabled: Bool {
        get {
            let key = ExternalVolume.userDefaultsKeyPrefixVolume + id
            guard let value = ExternalVolume.userDefaults.object(forKey: key) as? Bool else {
                // Enable auto-management by default for newly discovered volumes.
                return true
            }
            return value
        }
        set {
            ExternalVolume.userDefaults.set(newValue, forKey: ExternalVolume.userDefaultsKeyPrefixVolume + id)
        }
    }

    /// Creates a model instance for a resolved Disk Arbitration disk.
    init(disk: DADisk, id: String, name: String) {
        self.disk = disk
        self.id = id
        self.name = name
    }

    /// Requests Disk Arbitration to unmount the volume, optionally forcing it.
    func unmount(force: Bool = false) {
        let option = force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault
        let unmountModePrefix = force ? "Forced unmount" : "Unforced unmount"
        Self.logger.info("\(unmountModePrefix, privacy: .public) attempt started for \(self.name, privacy: .public)")

        guard Self.isMounted(self.disk) else {
            Self.logger.info("\(unmountModePrefix, privacy: .public) skipped because \(self.name, privacy: .public) is already unmounted")
            return
        }

        let context = Unmanaged.passRetained(CallbackLogContext(volumeName: self.name, operation: unmountModePrefix)).toOpaque()
        DADiskUnmount(disk, DADiskUnmountOptions(option), { _, dissenter, context in
            guard let context else {
                return
            }
            let callbackContext = Unmanaged<CallbackLogContext>.fromOpaque(context).takeRetainedValue()

            guard let dissenter else {
                ExternalVolume.logger.info("\(callbackContext.operation, privacy: .public) completed for \(callbackContext.volumeName, privacy: .public)")
                return
            }

            let failureStatus = ExternalVolume.formattedFailureStatus(from: dissenter)
            ExternalVolume.logger.error(
                "\(callbackContext.operation, privacy: .public) failed for \(callbackContext.volumeName, privacy: .public): \(failureStatus, privacy: .public)"
            )
        }, context)
    }

    /// Requests Disk Arbitration to mount the volume.
    func mount() {
        Self.logger.info("Mount attempt started for \(self.name, privacy: .public)")

        guard !Self.isMounted(self.disk) else {
            Self.logger.info("Mount skipped because \(self.name, privacy: .public) is already mounted")
            return
        }

        let context = Unmanaged.passRetained(CallbackLogContext(volumeName: self.name, operation: "Mount")).toOpaque()
        DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), { _, dissenter, context in
            guard let context else {
                return
            }
            let callbackContext = Unmanaged<CallbackLogContext>.fromOpaque(context).takeRetainedValue()

            guard let dissenter else {
                ExternalVolume.logger.info("Mount completed for \(callbackContext.volumeName, privacy: .public)")
                return
            }

            let failureStatus = ExternalVolume.formattedFailureStatus(from: dissenter)
            ExternalVolume.logger.error("Mount failed for \(callbackContext.volumeName, privacy: .public): \(failureStatus, privacy: .public)")
        }, context)
    }

    /// Returns currently mounted external volumes that Ejectify can manage.
    static func mountedVolumes() -> [ExternalVolume] {
        guard let mountedVolumeURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:nil, options: []) else {
            Self.logger.warning("Failed to enumerate mounted volumes from FileManager")
            return []
        }

        return mountedVolumeURLs
            .filter(ExternalVolume.isVolumeURL(_:))
            .compactMap(ExternalVolume.fromURL(url:))
    }

    /// Returns `true` when the URL points to a mounted volume under `/Volumes`.
    static func isVolumeURL(_ url: URL) -> Bool {
        url.pathComponents.count > 1 && url.pathComponents[1] == volumesPathComponent
    }

    /// Resolves a mounted volume URL to an `ExternalVolume` model when eligible.
    static func fromURL(url: URL) -> ExternalVolume? {
        guard let session = ExternalVolume.diskArbitrationSession else {
            return nil
        }

        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else {
            return nil
        }

        if disk.isDiskImage() {
            return nil
        }

        return ExternalVolume.fromDisk(disk: disk)
    }

    /// Converts a Disk Arbitration disk description into an `ExternalVolume`.
    static func fromDisk(disk: DADisk) -> ExternalVolume? {
        guard let diskInfo = DADiskCopyDescription(disk) as? [NSString: Any] else {
            return nil
        }

        guard let volumeUUID = ExternalVolume.volumeUUID(from: diskInfo) else {
            return nil
        }

        guard let name = diskInfo[kDADiskDescriptionVolumeNameKey] as? String else {
            return nil
        }

        guard let internalDisk = diskInfo[kDADiskDescriptionDeviceInternalKey] as? Bool else {
            return nil
        }
        // Exclude non-ejectable internal system disks.
        if internalDisk && (diskInfo[kDADiskDescriptionMediaEjectableKey] as? Bool != true) {
            return nil
        }

        guard name != efiVolumeName else {
            return nil
        }

        let id = volumeUUID.uuidString

        return ExternalVolume(disk: disk, id: id, name: name)
    }

    /// Determines whether Disk Arbitration currently reports a mounted filesystem path for the disk.
    private static func isMounted(_ disk: DADisk) -> Bool {
        guard let diskInfo = DADiskCopyDescription(disk) as? [NSString: Any] else {
            return false
        }

        return diskInfo[kDADiskDescriptionVolumePathKey] != nil
    }

    /// Normalizes volume UUID values returned by Disk Arbitration across Foundation and CoreFoundation bridge types.
    private static func volumeUUID(from diskInfo: [NSString: Any]) -> UUID? {
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

    /// Returns a standardized Disk Arbitration failure status string.
    private static func formattedFailureStatus(from dissenter: DADissenter) -> String {
        let status = DADissenterGetStatus(dissenter)
        let detail = DADissenterGetStatusString(dissenter) as String? ?? status.message
        return "\(status.description) (\(detail))"
    }

}
