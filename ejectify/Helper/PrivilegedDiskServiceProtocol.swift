//
//  PrivilegedDiskServiceProtocol.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation

/// XPC interface exposed by the privileged helper daemon.
@objc protocol PrivilegedDiskServiceProtocol {
    
    /// Mounts a volume identified by UUID with a BSD-name resolve hint.
    func mount(volumeUUID: NSUUID, volumeName: String, bsdName: String, withReply reply: @escaping (Bool, String?) -> Void)

    /// Unmounts a volume identified by UUID with a BSD-name resolve hint.
    func unmount(volumeUUID: NSUUID, volumeName: String, bsdName: String, force: Bool, withReply reply: @escaping (Bool, String?) -> Void)

    /// Enables or disables macOS "Disk Not Ejected Properly" notifications.
    func setEjectNotificationsMuted(muted: Bool, withReply reply: @escaping (Bool, String?) -> Void)

}
