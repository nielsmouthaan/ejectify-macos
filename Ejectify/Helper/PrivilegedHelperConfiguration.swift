//
//  PrivilegedHelperConfiguration.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 26/02/2026.
//

import Foundation

/// Shared constants used by both the app and the privileged helper daemon.
enum PrivilegedHelperConfiguration {

    /// Bundle identifier of the only app allowed to call the privileged helper.
    static let appBundleIdentifier = "nl.nielsmouthaan.Ejectify"

    /// Mach service name used to connect app and privileged helper via XPC.
    static let machServiceName = "nl.nielsmouthaan.Ejectify.PrivilegedHelper"

    /// Code-signing identifier of the privileged helper executable.
    static let helperCodeSigningIdentifier = "EjectifyPrivilegedHelper"

    /// Apple Developer team identifier shared by the app and privileged helper signatures.
    static let developmentTeamIdentifier = "DNG6HL3Y5G"

    /// Code-signing requirement for the app's current build configuration.
    static let appCodeSigningRequirement = codeSigningRequirement(identifier: appBundleIdentifier)

    /// Code-signing requirement for the helper's current build configuration.
    static let helperCodeSigningRequirement = codeSigningRequirement(identifier: helperCodeSigningIdentifier)

    /// Developer ID Application requirement used by notarized distribution builds.
    static func developerIDCodeSigningRequirement(identifier: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(developmentTeamIdentifier)\""
    }

    /// Selects a development-compatible requirement for Debug and Developer ID for Release.
    private static func codeSigningRequirement(identifier: String) -> String {
        #if DEBUG
        "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(developmentTeamIdentifier)\""
        #else
        developerIDCodeSigningRequirement(identifier: identifier)
        #endif
    }

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
}
