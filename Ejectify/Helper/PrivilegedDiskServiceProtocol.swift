//
//  PrivilegedDiskServiceProtocol.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation

/// Identifies the process that actually executed a routed volume operation.
enum VolumeOperationExecutor: String, Equatable, Sendable {
    case local
    case privilegedHelper = "privileged_helper"
}

/// Primitive encrypted APFS recovery outcomes that can cross the Objective-C XPC boundary.
@objc enum PrivilegedEncryptedAPFSUnlockOutcome: Int32 {
    case success
    case invalidPassword
    case failed
}

/// XPC interface exposed by the privileged helper daemon.
@objc protocol PrivilegedDiskServiceProtocol {

    /// Pings the privileged helper to prewarm XPC routing before the first volume operation.
    func ping(withReply reply: @escaping (Bool, String?) -> Void)

    /// Mounts a volume identified by optional UUID with a BSD-name resolve hint.
    func mount(volumeUUID: NSUUID?, volumeName: String, bsdName: String, withReply reply: @escaping (Bool, String?, Int32) -> Void)

    /// Unmounts a volume identified by optional UUID with a BSD-name resolve hint.
    func unmount(volumeUUID: NSUUID?, volumeName: String, bsdName: String, force: Bool, withReply reply: @escaping (Bool, String?, Int32) -> Void)

    /// Ejects the parent whole disk, optionally force-unmounting its volumes first.
    func eject(volumeUUID: NSUUID?, volumeName: String, bsdName: String, forceUnmount: Bool, withReply reply: @escaping (Bool, String?, Int32) -> Void)

    /// Unlocks and mounts one encrypted APFS volume entirely inside the privileged helper.
    func unlockAndMountEncryptedAPFS(
        volumeUUID: NSUUID?,
        volumeName: String,
        bsdName: String,
        passphraseData: Data,
        withReply reply: @escaping (Int32, String?, Int32, Bool, Bool, Bool, Bool) -> Void
    )

    /// Enables or disables macOS "Disk Not Ejected Properly" notifications.
    func setEjectNotificationsMuted(muted: Bool, withReply reply: @escaping (Bool, String?) -> Void)

    /// Requests the privileged helper daemon to terminate itself.
    func requestTermination(withReply reply: @escaping (Bool, String?) -> Void)

}
