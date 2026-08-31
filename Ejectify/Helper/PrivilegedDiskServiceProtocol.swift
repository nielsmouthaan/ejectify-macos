//
//  PrivilegedDiskServiceProtocol.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation

/// XPC interface exposed by the privileged helper daemon.
@objc protocol PrivilegedDiskServiceProtocol {

    /// Reports helper support for diskutil-backed fixed operations.
    func capabilityVersion(withReply reply: @escaping (Int) -> Void)

    /// Mounts a volume identified by optional UUID with a BSD-name resolve hint.
    func mount(volumeUUID: NSUUID?, volumeName: String, bsdName: String, withReply reply: @escaping (Bool, String?, Int32) -> Void)

    /// Unmounts a volume identified by optional UUID with a BSD-name resolve hint.
    func unmount(volumeUUID: NSUUID?, volumeName: String, bsdName: String, force: Bool, withReply reply: @escaping (Bool, String?, Int32) -> Void)

    /// Passes a volume to diskutil eject, optionally using diskutil's force option.
    func eject(volumeUUID: NSUUID?, volumeName: String, bsdName: String, forceUnmount: Bool, withReply reply: @escaping (Bool, String?, Int32) -> Void)

    /// Reads the authoritative APFS lock state for one validated volume target.
    func inspectAPFSLockState(volumeUUID: NSUUID?, bsdName: String, withReply reply: @escaping (String) -> Void)

    /// Unlocks one validated APFS volume with a passphrase supplied to diskutil through standard input.
    func unlockAPFSVolume(
        volumeUUID: NSUUID?,
        bsdName: String,
        password: String,
        withReply reply: @escaping (Bool, String, Int32, Int, NSNumber?, NSNumber?, NSNumber?) -> Void
    )

    /// Enables or disables macOS "Disk Not Ejected Properly" notifications.
    func setEjectNotificationsMuted(muted: Bool, withReply reply: @escaping (Bool, String?) -> Void)

    /// Requests the privileged helper daemon to terminate itself.
    func requestTermination(withReply reply: @escaping (Bool, String?) -> Void)

}
