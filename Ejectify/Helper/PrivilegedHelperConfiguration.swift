//
//  PrivilegedHelperConfiguration.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 26/02/2026.
//

import Foundation

/// Shared constants used by both the app and the privileged helper daemon.
enum PrivilegedHelperConfiguration {

    /// Mach service name used to connect app and privileged helper via XPC.
    static let machServiceName = "nl.nielsmouthaan.Ejectify.PrivilegedHelper"

    /// Launch daemon plist identifier bundled with the app.
    static let launchDaemonPlistName = "nl.nielsmouthaan.Ejectify.PrivilegedHelper.plist"

    /// System plist path storing Disk Arbitration daemon preferences.
    static let diskArbitrationPreferencesPath = "/Library/Preferences/SystemConfiguration/com.apple.DiskArbitration.diskarbitrationd.plist"

    /// Disk Arbitration preference key controlling eject warning notifications.
    static let disableEjectNotificationKey = "DADisableEjectNotification"

    /// Darwin notification sent by the helper when it has finished starting.
    static let helperStartedNotificationName = "nl.nielsmouthaan.Ejectify.PrivilegedHelper.started"

    /// In-app notification sent when router state changes and UI should refresh.
    static let operationRouterDidChangeNotificationName = "nl.nielsmouthaan.Ejectify.VolumeOperationRouter.didChange"
}

/// Shared subsystem identifiers used for unified logging.
enum LoggingConfiguration {

    /// Main app logging subsystem.
    static let appSubsystem = "nl.nielsmouthaan.Ejectify"

    /// Privileged helper logging subsystem.
    static let privilegedHelperSubsystem = "nl.nielsmouthaan.Ejectify.PrivilegedHelper"

#if EJECTIFY_PRIVILEGED_HELPER

    /// Logging subsystem for shared code compiled into the privileged helper target.
    static let currentSubsystem = privilegedHelperSubsystem
#else

    /// Logging subsystem for shared code compiled into the app target.
    static let currentSubsystem = appSubsystem
#endif
}
