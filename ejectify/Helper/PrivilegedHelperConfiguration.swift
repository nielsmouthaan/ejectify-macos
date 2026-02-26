//
//  PrivilegedHelperConfiguration.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 26/02/2026.
//

import Foundation

/// Shared constants used by both the app and the privileged helper daemon.
enum PrivilegedHelperConfiguration {
    static let machServiceName = "nl.nielsmouthaan.Ejectify.PrivilegedHelper"
    static let launchDaemonPlistName = "nl.nielsmouthaan.Ejectify.PrivilegedHelper.plist"
}
