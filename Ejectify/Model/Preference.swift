//
//  Preference.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 27/11/2020.
//

import Foundation
import LaunchAtLogin

/// Centralizes persisted user preferences used by Ejectify.
enum Preference {


    /// Defines which system event triggers automatic unmounting.
    enum UnmountWhen: String {
        case systemStartsSleeping = "systemStartsSleeping"
        case screensStartedSleeping = "screensStartedSleeping"
        case screenIsLocked = "screenIsLocked"
        case screensaverStarted = "screensaverStarted"

        /// Creates a trigger value from persisted defaults, including restored Ejectify 1 trigger values.
        init(persistedRawValue: String?) {
            switch persistedRawValue {
            case Self.systemStartsSleeping.rawValue:
                self = .systemStartsSleeping
            case Self.screensStartedSleeping.rawValue:
                self = .screensStartedSleeping
            case Self.screenIsLocked.rawValue:
                self = .screenIsLocked
            case Self.screensaverStarted.rawValue:
                self = .screensaverStarted
            default:
                self = .systemStartsSleeping
            }
        }
    }

    /// Controls whether Ejectify launches automatically at user login.
    static var launchAtLogin: Bool {
        get {
            return LaunchAtLogin.isEnabled
        }
        set {
            LaunchAtLogin.isEnabled = newValue
            Log.preferences.log("Preference changed: launchAtLogin=\(newValue)")
        }
    }

    /// Controls which event should trigger automatic unmounting.
    static var unmountWhen: UnmountWhen {
        get {
            UnmountWhen(persistedRawValue: UserDefaults.standard.string(forKey: "preference.unmountWhen"))
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "preference.unmountWhen")
            Log.preferences.log("Preference changed: unmountWhen=\(newValue.rawValue)")
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
            Log.preferences.log("Preference changed: forceUnmount=\(newValue)")
        }
    }

    /// Tracks whether the one-time onboarding window has already been shown.
    static var hasSeenOnboarding: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "preference.hasSeenOnboarding")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "preference.hasSeenOnboarding")
            Log.preferences.info("Preference changed: hasSeenOnboarding=\(newValue)")
        }
    }
}
