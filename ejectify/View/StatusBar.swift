//
//  StatusBar.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import AppKit

/// Creates and configures the app's menu bar status item.
@MainActor
class StatusBar {
    
    /// Backing status item shown in the macOS menu bar.
    private let statusItem: NSStatusItem

    /// Builds the status item with icon and menu.
    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = StatusBarMenu()
        
        if let statusBarButton = statusItem.button {
            statusBarButton.image = NSImage(named: "StatusBarIcon")
            statusBarButton.image?.size = NSSize(width: 16.0, height: 16.0)
            statusBarButton.image?.isTemplate = true
        }
    }
}
