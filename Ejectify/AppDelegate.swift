//
//  AppDelegate.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import Cocoa

@MainActor

/// Coordinates app startup and wires core menu/activity controllers.
final class AppDelegate: NSObject, NSApplicationDelegate {


    /// Shared delegate instance exposed for app-wide coordination.
    static let shared = NSApplication.shared.delegate as! AppDelegate

    /// Owns the menu bar status item and its menu lifecycle.
    var statusBar: StatusBar?

    /// Owns event observation and disk-operation orchestration.
    var activityController: ActivityController?

    /// Owns global hotkey registration and dispatch for the configured all-volumes action.
    private var globalHotKeyController: GlobalHotKeyController?

    /// Owns Sparkle updater lifecycle and manual update actions.
    private var updateController: UpdateController?

    /// Owns diagnostics report generation and export UI.
    private let diagnosticsReportController = DiagnosticsReportController()

    /// Owns the onboarding window lifecycle while guidance is presented.
    private var onboardingWindowController: OnboardingWindowController?

    /// Returns whether the global all-volumes action hotkey is currently registered.
    var isUnmountAllHotKeyRegistered: Bool {
        globalHotKeyController?.isRegistered ?? false
    }

    /// Bootstraps routing mode, applies one-time first-run setup, and initializes primary app controllers.
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let isFirstLaunch = !Preference.hasSeenOnboarding
        VolumeOperationRouter.shared.configureExecutionMode()
        Volume.startDiscovery()

        if isFirstLaunch {
            Preference.launchAtLogin = true

            // First launch is the only automatic registration attempt so macOS can surface helper approval once; later retries only happen after explicit user action.
            VolumeOperationRouter.shared.requestPrivilegedExecutionMode()
        }

        globalHotKeyController = GlobalHotKeyController { [weak self] in
            self?.performManualUnmountAll(trigger: .hotkey)
        }
        statusBar = StatusBar()
        activityController = ActivityController()
        let updateController = UpdateController()
        self.updateController = updateController
        updateController.start()

        if isFirstLaunch {
            showOnboarding()
        }
    }

    /// Starts a user-initiated Sparkle update check.
    func checkForUpdates() {
        updateController?.checkForUpdates()
    }

    /// Starts a user-initiated diagnostics report save flow.
    func saveDiagnosticsReport() {
        diagnosticsReportController.saveDiagnosticsReport()
    }

    /// Handles all enabled volumes using the configured user-initiated action.
    func performManualUnmountAll(trigger: VolumeOperationTrigger = .manual) {
        let enabledVolumes = Volume.mountedVolumes().filter(\.enabled)
        let operationName = Preference.ejectInsteadOfUnmount ? "eject" : "unmount"
        Log.app.log("Manual volume operation triggered; trigger=\(trigger.rawValue); operation=\(operationName); count=\(enabledVolumes.count)")

        if Preference.ejectInsteadOfUnmount {
            activityController?.clearRemountStateForEjectMode()
        }

        for volume in enabledVolumes {
            if Preference.ejectInsteadOfUnmount {
                VolumeOperationRouter.shared.eject(
                    identityUUID: volume.identityUUID.map { $0 as NSUUID },
                    bsdName: volume.bsdName,
                    logLabel: volume.logLabel,
                    force: Preference.forceUnmount,
                    trigger: trigger
                ) { _ in }
            } else {
                VolumeOperationRouter.shared.unmount(
                    identityUUID: volume.identityUUID.map { $0 as NSUUID },
                    bsdName: volume.bsdName,
                    logLabel: volume.logLabel,
                    force: Preference.forceUnmount,
                    trigger: trigger
                ) { _ in }
            }
        }
    }

    /// Sends a best-effort helper shutdown request when the app is quitting.
    func applicationWillTerminate(_ notification: Notification) {
        VolumeOperationRouter.shared.requestHelperTermination()
    }

    /// Presents the onboarding window.
    private func showOnboarding() {
        onboardingWindowController = OnboardingWindowController { [weak self] in
            self?.onboardingWindowController = nil
        }
        onboardingWindowController?.showCentered()
    }
}
