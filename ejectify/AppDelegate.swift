//
//  AppDelegate.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import Cocoa

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    static let shared = NSApplication.shared.delegate as! AppDelegate
    var statusBar: StatusBar?
    var activityController: ActivityController?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        VolumeOperationRouter.shared.configureExecutionMode()

        statusBar = StatusBar()
        activityController = ActivityController()
    }
}
