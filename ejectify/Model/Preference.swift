//
//  Option.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 27/11/2020.
//

import Foundation
import LaunchAtLogin
import OSLog

class Preference {
    private static var userDefaults: UserDefaults { UserDefaults.standard }
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "Preference")
    
    enum UnmountWhen: String {
        case screensaverStarted = "screensaverStarted"
        case screenIsLocked = "screenIsLocked"
        case screensStartedSleeping = "screensStartedSleeping"
        case systemStartsSleeping = "systemStartsSleeping"
    }
    
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
    static var unmountWhen: UnmountWhen {
        get {
            guard let rawValue = userDefaults.string(forKey: userDefaultsKeyUnmountWhen),
                  let value = UnmountWhen(rawValue: rawValue) else {
                return .systemStartsSleeping // Default
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
