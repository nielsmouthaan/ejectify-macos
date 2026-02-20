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

    static let sharedDASession: DASession? = DASessionCreate(kCFAllocatorDefault)

    let disk: DADisk
    let id: String
    let name: String
    let bsdName: String
    let encrypted: Bool

    private static var userDefaultsKeyPrefixVolume = "volume."
    var enabled: Bool {
        get {
            return UserDefaults.standard.object(forKey: ExternalVolume.userDefaultsKeyPrefixVolume + id) != nil ? UserDefaults.standard.bool(forKey: ExternalVolume.userDefaultsKeyPrefixVolume + id) : true // By default all volumes automatically unmount
        }
        set {
            UserDefaults.standard.set(newValue, forKey: ExternalVolume.userDefaultsKeyPrefixVolume + id)
            UserDefaults.standard.synchronize()
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
        DADiskUnmount(disk, DADiskUnmountOptions(option), { disk, dissenter, context in
            dissenter?.log()
        }, nil)
    }

    func mount() {
        if encrypted {
            if unlockEncryptedVolumeIfNeeded() {
                os_log("Encrypted volume unlock succeeded for '%{public}@' [bsd: %{public}@]", log: ExternalVolume.log, type: .default, name, bsdName)
            } else {
                os_log("Encrypted volume unlock failed for '%{public}@' [bsd: %{public}@]. Falling back to direct mount attempt.", log: ExternalVolume.log, type: .error, name, bsdName)
            }
        }

        DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), { disk, dissenter, context in
            dissenter?.log()
        }, nil)
    }

    static func mountedVolumes() -> [ExternalVolume] {
        guard let mountedVolumeURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:nil, options: []) else {
            return []
        }

        let mountedVolumes = mountedVolumeURLs.filter {
            ExternalVolume.isVolumeURL($0)
        }.compactMap {
            ExternalVolume.fromURL(url: $0)
        }

        return mountedVolumes
    }

    static func isVolumeURL(_ url: URL) -> Bool {
        url.pathComponents.count > 1 && url.pathComponents[VolumeComponent.root.rawValue] == VolumeReservedNames.Volumes.rawValue
    }

    static func fromURL(url: URL) -> ExternalVolume? {
        guard let session = ExternalVolume.sharedDASession else {
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
              let uuid = diskInfo[kDADiskDescriptionVolumeUUIDKey],
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

        let volumeUuid = uuid as! CFUUID
        guard let id = CFUUIDCreateString(kCFAllocatorDefault, volumeUuid) else {
            return nil
        }

        let encrypted: Bool
        if #available(macOS 10.14.4, *) {
            encrypted = diskInfo[kDADiskDescriptionMediaEncryptedKey] as? Bool ?? false
        } else {
            encrypted = false
        }

        return ExternalVolume(disk: disk, id: id as String, name: name, bsdName: bsdName, encrypted: encrypted)
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
}
