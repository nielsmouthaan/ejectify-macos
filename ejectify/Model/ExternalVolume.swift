//
//  ExternalVolume.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import Foundation

private enum VolumeComponent: Int {
    case root = 1
}

private enum VolumeReservedNames: String {
    case EFI = "EFI"
    case Volumes = "Volumes"
}

class ExternalVolume {
    
    static let sharedDASession: DASession? = DASessionCreate(kCFAllocatorDefault)
    
    let disk: DADisk
    let id: String
    let name: String
    
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
    
    init(disk: DADisk, id: String, name: String) {
        self.disk = disk
        self.id = id
        self.name = name
    }
    
    func unmount(force: Bool = false) {
        let option = force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault
        DADiskUnmount(disk, DADiskUnmountOptions(option), { disk, dissenter, context in
            dissenter?.log()
        }, nil)
    }
    
    func mount() {
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
        
        guard let internalDisk = diskInfo[kDADiskDescriptionDeviceInternalKey] as? Bool else {
            return nil
        }
        if internalDisk {
            return nil
        }
        
        guard let name = diskInfo[kDADiskDescriptionVolumeNameKey] as? String,
              let uuid = diskInfo[kDADiskDescriptionVolumeUUIDKey]
        else {
            return nil
        }
        
        guard name != VolumeReservedNames.EFI.rawValue else {
            return nil
        }
       
        let volumeUuid = uuid as! CFUUID
        guard let id = CFUUIDCreateString(kCFAllocatorDefault, volumeUuid) else {
            return nil
        }
        
        return ExternalVolume(disk: disk, id: id as String, name: name)
    }
}
