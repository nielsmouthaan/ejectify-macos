//
//  AppDelegate.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import Cocoa

@main
@MainActor

/// Coordinates app startup and wires core menu/activity controllers.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Shared delegate instance exposed for app-wide coordination.
    static let shared = NSApplication.shared.delegate as! AppDelegate

    /// Owns the menu bar status item and its menu lifecycle.
    var statusBar: StatusBar?

    /// Owns event observation and mount/unmount orchestration.
    var activityController: ActivityController?

    /// Bootstraps routing mode and initializes primary app controllers.
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        VolumeOperationRouter.shared.configureExecutionMode()

        statusBar = StatusBar()
        activityController = ActivityController()
    }

    /// Sends a best-effort helper shutdown request when the app is quitting.
    func applicationWillTerminate(_ notification: Notification) {
        VolumeOperationRouter.shared.requestHelperTermination()
    }
}
