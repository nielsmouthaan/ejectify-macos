//
//  StatusBarController.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import AppKit

class StatusBar {
    
    private var statusItem: NSStatusItem
    
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
