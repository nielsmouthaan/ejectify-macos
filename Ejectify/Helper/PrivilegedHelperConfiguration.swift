//
//  PrivilegedHelperConfiguration.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 26/02/2026.
//

import Foundation

/// Shared constants used by both the app and the privileged helper daemon.
enum PrivilegedHelperConfiguration {

    /// Capability level required for diskutil-backed helper operations.
    static let diskutilCapabilityVersion = 2

    /// Mach service name used to connect app and privileged helper via XPC.
    static let machServiceName = "nl.nielsmouthaan.Ejectify.PrivilegedHelper"

    /// Launch daemon plist identifier bundled with the app.
    static let launchDaemonPlistName = "\(machServiceName).plist"

    /// System plist path storing Disk Arbitration daemon preferences.
    static let diskArbitrationPreferencesPath = "/Library/Preferences/SystemConfiguration/com.apple.DiskArbitration.diskarbitrationd.plist"

    /// Disk Arbitration preference key controlling eject warning notifications.
    static let disableEjectNotificationKey = "DADisableEjectNotification"

    /// Darwin notification sent by the helper when it has finished starting.
    static let helperStartedNotificationName = "\(machServiceName).started"

    /// In-app notification sent when router state changes and UI should refresh.
    static let operationRouterDidChangeNotificationName = "nl.nielsmouthaan.Ejectify.VolumeOperationRouter.didChange"

    /// Signing requirement accepted by the helper for XPC clients.
    static let appSigningRequirement = "anchor apple generic and identifier \"nl.nielsmouthaan.Ejectify\" and certificate leaf[subject.OU] = \"DNG6HL3Y5G\""
}
