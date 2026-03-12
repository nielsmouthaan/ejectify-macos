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
        case screensStartedSleeping = "screensStartedSleeping"
        case systemStartsSleeping = "systemStartsSleeping"

        /// Creates a trigger value from persisted defaults, mapping legacy values to supported behavior.
        init(persistedRawValue: String?) {
            switch persistedRawValue {
            case Self.screensStartedSleeping.rawValue:
                self = .screensStartedSleeping
            case Self.systemStartsSleeping.rawValue:
                self = .systemStartsSleeping
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
            logger.info("Preference changed: launchAtLogin=\(newValue, privacy: .public)")
        }
    }

    /// Controls which event should trigger automatic unmounting.
    static var unmountWhen: UnmountWhen {
        get {
            UnmountWhen(persistedRawValue: UserDefaults.standard.string(forKey: "preference.unmountWhen"))
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

    /// Tracks whether startup onboarding has already been completed.
    static var hasCompletedOnboarding: Bool {
        get {
            if UserDefaults.standard.object(forKey: "preference.hasCompletedOnboarding") != nil {
                return UserDefaults.standard.bool(forKey: "preference.hasCompletedOnboarding")
            }
            return UserDefaults.standard.bool(forKey: "preference.hasSeenOnboarding")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "preference.hasCompletedOnboarding")
            logger.info("Preference changed: hasCompletedOnboarding=\(newValue, privacy: .public)")
        }
    }
}
