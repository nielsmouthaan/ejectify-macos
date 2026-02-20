//
//  Option.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 27/11/2020.
//

import Foundation
import LaunchAtLogin

class Preference {
    private static var userDefaults: UserDefaults { UserDefaults.standard }
    
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
        }
    }
    
}
