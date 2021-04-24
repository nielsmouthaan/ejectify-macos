//
//  StatusBarMenu.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import AppKit

class StatusBarMenu: NSMenu {
    
    private var volumes: [Volume]
    
    required init(coder: NSCoder) {
        volumes = Volume.mountedVolumes()
        super.init(coder: coder)
        updateMenu()
        listenForDiskNotifications()
    }
    
    init() {
        volumes = Volume.mountedVolumes()
        super.init(title: "Ejectify")
        updateMenu()
        listenForDiskNotifications()
    }
    
    private func listenForDiskNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(disksChanged), name: NSWorkspace.didRenameVolumeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(disksChanged), name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(disksChanged), name: NSWorkspace.didUnmountNotification, object: nil)
    }
    
    @objc private func disksChanged() {
        volumes = Volume.mountedVolumes()
        updateMenu()
    }
    
    private func updateMenu() {
        self.removeAllItems()
        buildActionsMenu()
        buildVolumesMenu()
        buildPreferencesMenu()
        buildAppMenu()
    }
    
    private func buildActionsMenu() {
        
        // Title
        let titleItem = NSMenuItem(title: "Actions".localized, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        addItem(titleItem)
        
        // Unmount all
        let unmountAllItem = NSMenuItem(title: "Unmount all".localized, action: #selector(unmountAllClicked(menuItem:)), keyEquivalent: "")
        unmountAllItem.target = self
        addItem(unmountAllItem)
    }

    private func buildVolumesMenu() {
        addItem(NSMenuItem.separator())
        
        // Title
        let title = volumes.count == 0 ? "No volumes".localized : "Volumes".localized
        let titleItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        addItem(titleItem)
        
        // Volume items
        volumes.forEach { (volume) in
            let volumeItem = NSMenuItem(title: volume.name, action: #selector(volumeClicked(menuItem:)), keyEquivalent: "")
            volumeItem.target = self
            volumeItem.state = volume.enabled ? .on : .off
            volumeItem.representedObject = volume
            addItem(volumeItem)
        }
    }
    
    private func buildPreferencesMenu() {
        addItem(NSMenuItem.separator())
        
        // Title
        let titleItem = NSMenuItem(title: "Preferences".localized, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        addItem(titleItem)
        
        // Launch at login
        let launchAtLoginItem = NSMenuItem(title: "Launch at login".localized, action: #selector(launchAtLoginClicked(menuItem:)), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = Preference.launchAtLogin ? .on : .off
        addItem(launchAtLoginItem)
        
        // Unmount when menu
        let unmountWhenItem = NSMenuItem(title: "Unmount when".localized, action: nil, keyEquivalent: "")
        unmountWhenItem.submenu = buildUnmountWhenMenu()
        addItem(unmountWhenItem)
    }
    
    private var unmountWhenScreensaverStartedItem: NSMenuItem?
    private var unmountWhenScreenIsLocked: NSMenuItem?
    private var unmountWhenScreensStartedSleepingItem: NSMenuItem?
    private var unmountWhenSystemStartsSleepingItem: NSMenuItem?
    private func buildUnmountWhenMenu() -> NSMenu {
        let unmountWhenMenu = NSMenu(title: "Unmount when".localized)
        
        unmountWhenScreensaverStartedItem = NSMenuItem(title: "Screensaver started".localized, action: #selector(unmountWhenChanged(menuItem:)), keyEquivalent: "")
        unmountWhenScreensaverStartedItem!.target = self
        unmountWhenScreensaverStartedItem!.state = Preference.unmountWhen == .screensaverStarted ? .on : .off
        unmountWhenMenu.addItem(unmountWhenScreensaverStartedItem!)
        
        unmountWhenScreenIsLocked = NSMenuItem(title: "Screen is locked".localized, action: #selector(unmountWhenChanged(menuItem:)), keyEquivalent: "")
        unmountWhenScreenIsLocked!.target = self
        unmountWhenScreenIsLocked!.state = Preference.unmountWhen == .screenIsLocked ? .on : .off
        unmountWhenMenu.addItem(unmountWhenScreenIsLocked!)
        
        unmountWhenScreensStartedSleepingItem = NSMenuItem(title: "Display turned off".localized, action: #selector(unmountWhenChanged(menuItem:)), keyEquivalent: "")
        unmountWhenScreensStartedSleepingItem!.target = self
        unmountWhenScreensStartedSleepingItem!.state = Preference.unmountWhen == .screensStartedSleeping ? .on : .off
        unmountWhenMenu.addItem(unmountWhenScreensStartedSleepingItem!)
        
        unmountWhenSystemStartsSleepingItem = NSMenuItem(title: "System starts sleeping".localized, action: #selector(unmountWhenChanged(menuItem:)), keyEquivalent: "")
        unmountWhenSystemStartsSleepingItem!.target = self
        unmountWhenSystemStartsSleepingItem!.state = Preference.unmountWhen == .systemStartsSleeping ? .on : .off
        unmountWhenMenu.addItem(unmountWhenSystemStartsSleepingItem!)
        
        return unmountWhenMenu
    }
    
    private func buildAppMenu() {
        addItem(NSMenuItem.separator())
        
        // About
        let aboutItem = NSMenuItem(title: "About Ejectify".localized, action: #selector(aboutClicked), keyEquivalent: "")
        aboutItem.target = self
        addItem(aboutItem)
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit Ejectify".localized, action: #selector(quitClicked), keyEquivalent: "")
        quitItem.target = self
        addItem(quitItem)
    }

    @objc private func unmountAllClicked(menuItem: NSMenuItem) {
        volumes.filter { $0.enabled }
            .forEach { (volume) in
                volume.unmount()
            }
        updateMenu()
    }

    @objc private func volumeClicked(menuItem: NSMenuItem) {
        guard let volume = menuItem.representedObject as? Volume else {
            return
        }
        volume.enabled = menuItem.state == .off ? true : false
        updateMenu()
    }
    
    @objc private func launchAtLoginClicked(menuItem: NSMenuItem) {
        Preference.launchAtLogin = menuItem.state == .off ? true : false
        updateMenu()
    }
    
    @objc private func unmountWhenChanged(menuItem: NSMenuItem) {
        if menuItem == unmountWhenScreensaverStartedItem {
            Preference.unmountWhen = .screensaverStarted
        } else if menuItem == unmountWhenScreenIsLocked {
            Preference.unmountWhen = .screenIsLocked
        } else if menuItem == unmountWhenScreensStartedSleepingItem {
            Preference.unmountWhen = .screensStartedSleeping
        } else if menuItem == unmountWhenSystemStartsSleepingItem {
            Preference.unmountWhen = .systemStartsSleeping
        }
        updateMenu()
    }
    
    @objc private func aboutClicked() {
        NSWorkspace.shared.open(URL(string: "https://ejectify.app")!)
    }
    
    @objc private func quitClicked() {
        NSApplication.shared.terminate(self)
    }
}
