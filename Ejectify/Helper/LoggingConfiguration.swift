//
//  LoggingConfiguration.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 23/06/2026.
//

import Foundation

/// Shared logging constants used by code that can run in the app or privileged helper.
enum LoggingConfiguration {

    /// Logger subsystem for the current target.
    static let subsystem: String = {
        #if EJECTIFY_PRIVILEGED_HELPER
        PrivilegedHelperConfiguration.machServiceName
        #else
        Bundle.main.bundleIdentifier!
        #endif
    }()
}
