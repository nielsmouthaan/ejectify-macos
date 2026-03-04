//
//  Preference.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 27/11/2020.
//

import Foundation
import LaunchAtLogin
import OSLog

/// Centralizes persisted user preferences used by Ejectify.
enum Preference {

    /// Logger used for preference mutation diagnostics.
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "Preference")

    /// Defines which system event triggers automatic unmounting.
    enum UnmountWhen: String {
        case screenIsLocked = "screenIsLocked"
        case screensStartedSleeping = "screensStartedSleeping"
        case systemStartsSleeping = "systemStartsSleeping"
    }

    /// Controls whether Ejectify launches automatically at user login.
    static var launchAtLogin: Bool {
        get {
            return LaunchAtLogin.isEnabled
        }
        set {
            LaunchAtLogin.isEnabled = newValue
            logger.info("Preference changed: launchAtLogin=\(newValue, privacy: .public)")
        }
    }

    /// Controls which event should trigger automatic unmounting.
    static var unmountWhen: UnmountWhen {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: "preference.unmountWhen"),
                  let value = UnmountWhen(rawValue: rawValue) else {
                return .systemStartsSleeping
            }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "preference.unmountWhen")
            logger.info("Preference changed: unmountWhen=\(newValue.rawValue, privacy: .public)")
            Task { @MainActor in
                AppDelegate.shared.activityController?.startMonitoring()
            }
        }
    }

    /// Controls whether unmount requests should use the force option.
    static var forceUnmount: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "preference.forceUnmount")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "preference.forceUnmount")
            logger.info("Preference changed: forceUnmount=\(newValue, privacy: .public)")
        }
    }

    /// Controls whether the app should keep the privileged helper daemon registered.
    static var useElevatedPermissions: Bool {
        get {
            let key = "preference.useElevatedPermissions"
            if let value = UserDefaults.standard.object(forKey: key) as? Bool {
                return value
            }

            return true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "preference.useElevatedPermissions")
            logger.info("Preference changed: useElevatedPermissions=\(newValue, privacy: .public)")
        }
    }
}
