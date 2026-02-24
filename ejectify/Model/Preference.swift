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
class Preference {
    /// Shared user defaults store for custom preference keys.
    private static var userDefaults: UserDefaults { UserDefaults.standard }
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "Preference")

    /// Defines which system event triggers automatic unmounting.
    enum UnmountWhen: String {
        /// Trigger when the screen saver starts.
        case screensaverStarted = "screensaverStarted"
        /// Trigger when the session is locked.
        case screenIsLocked = "screenIsLocked"
        /// Trigger when attached displays start sleeping.
        case screensStartedSleeping = "screensStartedSleeping"
        /// Trigger when the system is about to sleep.
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

    private static let userDefaultsKeyUnmountWhen = "preference.unmountWhen"
    /// Controls which event should trigger automatic unmounting.
    static var unmountWhen: UnmountWhen {
        get {
            guard let rawValue = userDefaults.string(forKey: userDefaultsKeyUnmountWhen),
                  let value = UnmountWhen(rawValue: rawValue) else {
                // Fall back to system sleep when the stored value is missing or invalid.
                return .systemStartsSleeping
            }
            return value
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: userDefaultsKeyUnmountWhen)
            logger.info("Preference changed: unmountWhen=\(newValue.rawValue, privacy: .public)")
            Task { @MainActor in
                AppDelegate.shared.activityController?.startMonitoring()
            }
        }
    }

    private static let userDefaultsKeyForceUnmount = "preference.forceUnmount"
    /// Controls whether unmount requests should use the force option.
    static var forceUnmount: Bool {
        get {
            return userDefaults.bool(forKey: userDefaultsKeyForceUnmount)
        }
        set {
            userDefaults.set(newValue, forKey: userDefaultsKeyForceUnmount)
            logger.info("Preference changed: forceUnmount=\(newValue, privacy: .public)")
        }
    }
}
