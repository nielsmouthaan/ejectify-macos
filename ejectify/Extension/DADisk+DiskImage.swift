//
//  DADisk+DiskImage.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 11/01/2021.
//

import Foundation

extension DADisk {
    /// Returns `true` when Disk Arbitration reports this disk as a disk image.
    func isDiskImage() -> Bool {
        guard let description = DADiskCopyDescription(self) as? [AnyHashable: Any] else {
            return false
        }
        
        guard let deviceModel = description[kDADiskDescriptionDeviceModelKey] as? String else {
            return false
        }

        return deviceModel == "Disk Image"
    }
}
