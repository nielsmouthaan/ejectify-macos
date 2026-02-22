//
//  ExternalVolume.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import Foundation
import OSLog

private enum VolumeComponent: Int {
    case root = 1
}

private enum VolumeReservedNames: String {
    case EFI = "EFI"
    case Volumes = "Volumes"
}

class ExternalVolume {
    private final class CallbackLogContext {
        let volumeName: String
        let bsdName: String
        let unmountModePrefix: String?

        init(volumeName: String, bsdName: String, unmountModePrefix: String? = nil) {
            self.volumeName = volumeName
            self.bsdName = bsdName
            self.unmountModePrefix = unmountModePrefix
        }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "ExternalVolume")
    private static var userDefaults: UserDefaults { UserDefaults.standard }

    private static var diskArbitrationSession: DASession? {
        DASessionCreate(kCFAllocatorDefault)
    }

    let disk: DADisk
    let id: String
    let name: String
    let bsdName: String
    let encrypted: Bool

    private static let userDefaultsKeyPrefixVolume = "volume."
    /// Tracks whether this volume should be managed automatically. Defaults to enabled.
    var enabled: Bool {
        get {
            let key = ExternalVolume.userDefaultsKeyPrefixVolume + id
            guard let value = ExternalVolume.userDefaults.object(forKey: key) as? Bool else {
                return true // By default all volumes automatically unmount.
            }
            return value
        }
        set {
            ExternalVolume.userDefaults.set(newValue, forKey: ExternalVolume.userDefaultsKeyPrefixVolume + id)
        }
    }

    init(disk: DADisk, id: String, name: String, bsdName: String, encrypted: Bool) {
        self.disk = disk
        self.id = id
        self.name = name
        self.bsdName = bsdName
        self.encrypted = encrypted
    }

    func unmount(force: Bool = false) {
        let option = force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault
        let bsdName = Self.bsdNameOrUnknown(self.disk)
        let unmountModePrefix = force ? "Forced unmount" : "Unforced unmount"
        Self.logger.info("\(unmountModePrefix) attempt started for \(self.name) (\(bsdName))")
        let context = Unmanaged.passRetained(CallbackLogContext(volumeName: self.name, bsdName: bsdName, unmountModePrefix: unmountModePrefix)).toOpaque()
        DADiskUnmount(disk, DADiskUnmountOptions(option), { _, dissenter, context in
            guard let context else {
                return
            }
            let callbackContext = Unmanaged<CallbackLogContext>.fromOpaque(context).takeRetainedValue()

            guard let dissenter else {
                ExternalVolume.logger.info("\(callbackContext.unmountModePrefix ?? "Unmount") completed for \(callbackContext.volumeName) (\(callbackContext.bsdName))")
                return
            }

            let status = DADissenterGetStatus(dissenter)
            ExternalVolume.logger.error("\(callbackContext.unmountModePrefix ?? "Unmount") failed for \(callbackContext.volumeName) (\(callbackContext.bsdName)): \(status.description)")
        }, context)
    }

    func mount() {
        let bsdName = Self.bsdNameOrUnknown(self.disk)
        Self.logger.info("Mount attempt started for \(self.name) (\(bsdName))")
        if encrypted {
            if unlockEncryptedVolumeIfNeeded() {
                Self.logger.info("Encrypted volume unlock succeeded for \(self.name) (\(self.bsdName))")
            } else {
                Self.logger.warning("Encrypted volume unlock failed for \(self.name) (\(self.bsdName))")
            }
        }

        let context = Unmanaged.passRetained(CallbackLogContext(volumeName: self.name, bsdName: bsdName)).toOpaque()
        DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), { _, dissenter, context in
            guard let context else {
                return
            }
            let callbackContext = Unmanaged<CallbackLogContext>.fromOpaque(context).takeRetainedValue()

            guard let dissenter else {
                ExternalVolume.logger.info("Mount completed for \(callbackContext.volumeName) (\(callbackContext.bsdName))")
                return
            }

            let status = DADissenterGetStatus(dissenter)
            ExternalVolume.logger.error("Mount failed for \(callbackContext.volumeName) (\(callbackContext.bsdName)): \(status.description)")
        }, context)
    }

    static func mountedVolumes() -> [ExternalVolume] {
        guard let mountedVolumeURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:nil, options: []) else {
            return []
        }

        return mountedVolumeURLs
            .filter(ExternalVolume.isVolumeURL(_:))
            .compactMap(ExternalVolume.fromURL(url:))
    }

    static func isVolumeURL(_ url: URL) -> Bool {
        url.pathComponents.count > 1 && url.pathComponents[VolumeComponent.root.rawValue] == VolumeReservedNames.Volumes.rawValue
    }

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

    static func fromDisk(disk: DADisk) -> ExternalVolume? {
        guard let diskInfo = DADiskCopyDescription(disk) as? [NSString: Any] else {
            return nil
        }

        guard let volumeUUID = ExternalVolume.volumeUUID(from: diskInfo) else {
            return nil
        }

        guard let name = diskInfo[kDADiskDescriptionVolumeNameKey] as? String,
              let bsdName = diskInfo[kDADiskDescriptionMediaBSDNameKey] as? String
        else {
            return nil
        }

        guard let internalDisk = diskInfo[kDADiskDescriptionDeviceInternalKey] as? Bool else {
            return nil
        }
        if internalDisk {
            guard let ejectable = diskInfo[kDADiskDescriptionMediaEjectableKey] as? Bool else {
                return nil
            }
            if !ejectable {
                return nil
            }
        }

        guard name != VolumeReservedNames.EFI.rawValue else {
            return nil
        }

        let id = volumeUUID.uuidString

        let encrypted = diskInfo[kDADiskDescriptionMediaEncryptedKey] as? Bool ?? false

        return ExternalVolume(disk: disk, id: id, name: name, bsdName: bsdName, encrypted: encrypted)
    }

    static func fromBSDName(_ bsdName: String) -> ExternalVolume? {
        guard let session = ExternalVolume.diskArbitrationSession else {
            return nil
        }

        return bsdName.withCString { bsdNameCStr in
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdNameCStr) else {
                return nil
            }

            return ExternalVolume.fromDisk(disk: disk)
        }
    }

    private func unlockEncryptedVolumeIfNeeded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["apfs", "unlockVolume", bsdName, "-nomount"]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Self.logger.error("Failed to start diskutil unlock process for \(self.name) (\(self.bsdName)): \(String(describing: error))")
            return false
        }

        guard process.terminationStatus == 0 else {
            Self.logger.error("diskutil unlock failed for \(self.name) (\(self.bsdName)) with status \(process.terminationStatus)")
            return false
        }

        return true
    }

    private static func bsdNameOrUnknown(_ disk: DADisk) -> String {
        guard let bsdName = DADiskGetBSDName(disk) else {
            return "unknown"
        }
        return String(cString: bsdName)
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

}
