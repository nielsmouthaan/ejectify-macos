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
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "ExternalVolume")
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
        os_log("Unmount attempt started for volume '%{public}@' [id: %{public}@] [bsd: %{public}@] [force: %{public}@]", log: ExternalVolume.log, type: .default, self.name, self.id, self.bsdNameOrUnknown(), force.description)
        DADiskUnmount(disk, DADiskUnmountOptions(option), { _, dissenter, _ in
            dissenter?.log()
        }, nil)
    }

    func mount() {
        os_log("Mount attempt started for volume '%{public}@' [id: %{public}@] [bsd: %{public}@]", log: ExternalVolume.log, type: .default, self.name, self.id, self.bsdNameOrUnknown())
        if encrypted {
            if unlockEncryptedVolumeIfNeeded() {
                os_log("Encrypted volume unlock succeeded for '%{public}@' [bsd: %{public}@]", log: ExternalVolume.log, type: .default, name, bsdName)
            } else {
                os_log("Encrypted volume unlock failed for '%{public}@' [bsd: %{public}@]. Falling back to direct mount attempt.", log: ExternalVolume.log, type: .error, name, bsdName)
            }
        }

        DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), { _, dissenter, _ in
            dissenter?.log()
        }, nil)
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

        guard let name = diskInfo[kDADiskDescriptionVolumeNameKey] as? String,
              let volumeUUID = diskInfo[kDADiskDescriptionVolumeUUIDKey] as? UUID,
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

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            os_log("Failed to start diskutil unlock process for '%{public}@' [bsd: %{public}@]: %{public}@", log: ExternalVolume.log, type: .error, name, bsdName, String(describing: error))
            return false
        }

        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let output = (String(data: stdoutData, encoding: .utf8) ?? "") + (String(data: stderrData, encoding: .utf8) ?? "")
        let normalizedOutput = output.lowercased()

        if process.terminationStatus == 0 {
            return true
        }

        if normalizedOutput.contains("already unlocked") || normalizedOutput.contains("is not encrypted") {
            return true
        }

        os_log("diskutil unlock failed for '%{public}@' [bsd: %{public}@] [status: %{public}@] [output: %{public}@]", log: ExternalVolume.log, type: .error, name, bsdName, String(process.terminationStatus), output)
        return false
    }

    private func bsdNameOrUnknown() -> String {
        guard let bsdName = DADiskGetBSDName(disk) else {
            return "unknown"
        }
        return String(cString: bsdName)
    }
}
