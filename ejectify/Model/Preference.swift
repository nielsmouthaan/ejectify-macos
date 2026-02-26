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
    
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "Preference")

    /// Defines which system events can trigger automatic unmounting.
    enum UnmountWhen: String {
        case screensaverStarted = "screensaverStarted"
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

    /// Controls which events should trigger automatic unmounting.
    static var unmountWhenTriggers: Set<UnmountWhen> {
        get {
            if let rawValues = UserDefaults.standard.array(forKey: "preference.unmountWhen") as? [String] {
                return Set(rawValues.compactMap(UnmountWhen.init(rawValue:)))
            }

            guard let rawValue = UserDefaults.standard.string(forKey: "preference.unmountWhen"),
                  let legacyValue = UnmountWhen(rawValue: rawValue) else {
                return [.systemStartsSleeping]
            }
            return [legacyValue]
        }
        set {
            let serializedValues = newValue.map(\.rawValue).sorted()
            UserDefaults.standard.set(serializedValues, forKey: "preference.unmountWhen")
            logger.info("Preference changed: unmountWhen=\(serializedValues.joined(separator: ","), privacy: .public)")
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

    /// Controls whether remount attempts should be delayed by five seconds after wake.
    static var mountAfterDelay: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "preference.mountAfterDelay")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "preference.mountAfterDelay")
            logger.info("Preference changed: mountAfterDelay=\(newValue, privacy: .public)")
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
