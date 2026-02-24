//
//  AppDelegate.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import Cocoa

/// Coordinates app startup and keeps shared controller instances alive.
@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    /// Global accessor for the active app delegate instance.
    static let shared = NSApplication.shared.delegate as! AppDelegate

    /// Owns the status bar item and its menu UI.
    var statusBar: StatusBar?
    /// Owns sleep/wake monitoring and automatic mount state.
    var activityController: ActivityController?

    /// Creates long-lived UI and activity controllers after launch completes.
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        statusBar = StatusBar()
        activityController = ActivityController()
    }
}
