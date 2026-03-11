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

    /// Owns event observation and mount/unmount orchestration.
    var activityController: ActivityController?

    /// Owns the onboarding window lifecycle while guidance is presented.
    private var onboardingWindowController: OnboardingWindowController?

    /// Bootstraps routing mode and initializes primary app controllers.
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        VolumeOperationRouter.shared.configureExecutionMode()

        statusBar = StatusBar()
        activityController = ActivityController()
        presentOnboardingIfNeeded()
    }

    /// Sends a best-effort helper shutdown request when the app is quitting.
    func applicationWillTerminate(_ notification: Notification) {
        VolumeOperationRouter.shared.requestHelperTermination()
    }

    /// Presents the onboarding window once when startup guidance for helper approval is still needed.
    private func presentOnboardingIfNeeded() {
//        guard !Preference.hasSeenOnboarding else {
//            return
//        }
//
//        guard !VolumeOperationRouter.shared.isDaemonEnabled else {
//            return
//        }

        let controller = OnboardingWindowController { [weak self] in
            self?.onboardingWindowController = nil
        }
        onboardingWindowController = controller
        controller.showCentered()
    }
}
