//
//  PrivilegedDiskServiceProtocol.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation

/// Shared constants used by both the app and the privileged helper daemon.
enum PrivilegedHelperConfiguration {
    static let machServiceName = "nl.nielsmouthaan.Ejectify.PrivilegedHelper"
    static let launchDaemonPlistName = "nl.nielsmouthaan.Ejectify.PrivilegedHelper.plist"
}

/// XPC interface exposed by the privileged helper daemon.
@objc protocol PrivilegedDiskServiceProtocol {
    
    /// Mounts a volume identified by UUID.
    func mount(volumeUUID: NSUUID, volumeName: String, withReply reply: @escaping (Bool, String?) -> Void)

    /// Unmounts a volume identified by UUID.
    func unmount(volumeUUID: NSUUID, volumeName: String, force: Bool, withReply reply: @escaping (Bool, String?) -> Void)
}
