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

class Volume {
    
    static let sharedDASession: DASession? = DASessionCreate(kCFAllocatorDefault)
    
    let disk: DADisk
    let id: String
    let name: String
    let ejectable: Bool
    let removable: Bool
    
    private static var userDefaultsKeyPrefixVolume = "volume."
    var enabled: Bool {
        get {
            return UserDefaults.standard.object(forKey: Volume.userDefaultsKeyPrefixVolume + id) != nil ? UserDefaults.standard.bool(forKey: Volume.userDefaultsKeyPrefixVolume + id) : true // By default all volumes automatically unmount
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Volume.userDefaultsKeyPrefixVolume + id)
            UserDefaults.standard.synchronize()
        }
    }
    
    init(disk: DADisk, id: String, name: String, ejectable: Bool, removable: Bool) {
        self.disk = disk
        self.id = id
        self.name = name
        self.ejectable = ejectable
        self.removable = removable
    }
    
    func unmount() {
        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), nil, nil)
    }
    
    func mount() {
        DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), nil, nil)
    }
    
    static func mountedVolumes() -> [Volume] {
        guard let mountedVolumeURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:nil, options: []) else {
            return []
        }
        
        let mountedVolumes = mountedVolumeURLs.filter {
            Volume.isVolumeURL($0)
        }.compactMap {
            Volume.fromURL(url: $0)
        }
        
        return mountedVolumes
    }
    
    static func isVolumeURL(_ url: URL) -> Bool {
        url.pathComponents.count > 1 && url.pathComponents[VolumeComponent.root.rawValue] == VolumeReservedNames.Volumes.rawValue
    }
    
    static func fromURL(url: URL) -> Volume? {
        guard let session = Volume.sharedDASession else {
            return nil
        }
        
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else {
            return nil
        }
        
        if disk.isDiskImage() {
            return nil
        }
        
        return Volume.fromDisk(disk: disk)
    }
    
    static func fromDisk(disk: DADisk) -> Volume? {
        guard let diskInfo = DADiskCopyDescription(disk) as? [NSString: Any] else {
            return nil
        }
        
        guard let name = diskInfo[kDADiskDescriptionVolumeNameKey] as? String,
              let ejectable = diskInfo[kDADiskDescriptionMediaEjectableKey] as? Bool,
              let removable = diskInfo[kDADiskDescriptionMediaRemovableKey] as? Bool,
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
        
        return Volume(disk: disk, id: id as String, name: name, ejectable: ejectable, removable: removable)
    }
}
