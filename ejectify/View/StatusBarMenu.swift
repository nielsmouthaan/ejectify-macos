//
//  StatusBarMenu.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import AppKit
import OSLog

class StatusBarMenu: NSMenu {
    
    private var volumes: [ExternalVolume]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "StatusBarMenu")
    
    required init(coder: NSCoder) {
        volumes = ExternalVolume.mountedVolumes()
        super.init(coder: coder)
        updateMenu()
        listenForVolumeNotifications()
    }
    
    init() {
        volumes = ExternalVolume.mountedVolumes()
        super.init(title: "Ejectify")
        updateMenu()
        listenForVolumeNotifications()
    }
    
    private func listenForVolumeNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didRenameVolumeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
    }
    
    @objc private func volumesChanged() {
        let updatedVolumes = ExternalVolume.mountedVolumes()
        let volumeDescriptions = updatedVolumes
            .map { "\($0.name) (\($0.bsdName))" }
            .joined(separator: ", ")
        logger.info("Volumes changed, available volumes: \(volumeDescriptions, privacy: .public)")
        volumes = updatedVolumes
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
        
        // Force unmount
        let forceUnmountItem = NSMenuItem(title: "Force unmount".localized, action: #selector(forceUnmountClicked(menuItem:)), keyEquivalent: "")
        forceUnmountItem.target = self
        forceUnmountItem.state = Preference.forceUnmount ? .on : .off
        addItem(forceUnmountItem)
        
    }
    
    private var unmountWhenScreensaverStartedItem: NSMenuItem?
    private var unmountWhenScreenIsLockedItem: NSMenuItem?
    private var unmountWhenScreensStartedSleepingItem: NSMenuItem?
    private var unmountWhenSystemStartsSleepingItem: NSMenuItem?

    /// Converts menu state toggles to a Bool value.
    private func toggledValue(for state: NSControl.StateValue) -> Bool {
        state == .off
    }

    private func buildUnmountWhenMenu() -> NSMenu {
        let unmountWhenMenu = NSMenu(title: "Unmount when".localized)

        let screensaverStartedItem = NSMenuItem(title: "Screensaver started".localized, action: #selector(unmountWhenChanged(menuItem:)), keyEquivalent: "")
        screensaverStartedItem.target = self
        screensaverStartedItem.state = Preference.unmountWhen == .screensaverStarted ? .on : .off
        unmountWhenScreensaverStartedItem = screensaverStartedItem
        unmountWhenMenu.addItem(screensaverStartedItem)

        let screenIsLockedItem = NSMenuItem(title: "Screen is locked".localized, action: #selector(unmountWhenChanged(menuItem:)), keyEquivalent: "")
        screenIsLockedItem.target = self
        screenIsLockedItem.state = Preference.unmountWhen == .screenIsLocked ? .on : .off
        unmountWhenScreenIsLockedItem = screenIsLockedItem
        unmountWhenMenu.addItem(screenIsLockedItem)

        let screensStartedSleepingItem = NSMenuItem(title: "Display turned off".localized, action: #selector(unmountWhenChanged(menuItem:)), keyEquivalent: "")
        screensStartedSleepingItem.target = self
        screensStartedSleepingItem.state = Preference.unmountWhen == .screensStartedSleeping ? .on : .off
        unmountWhenScreensStartedSleepingItem = screensStartedSleepingItem
        unmountWhenMenu.addItem(screensStartedSleepingItem)

        let systemStartsSleepingItem = NSMenuItem(title: "System starts sleeping".localized, action: #selector(unmountWhenChanged(menuItem:)), keyEquivalent: "")
        systemStartsSleepingItem.target = self
        systemStartsSleepingItem.state = Preference.unmountWhen == .systemStartsSleeping ? .on : .off
        unmountWhenSystemStartsSleepingItem = systemStartsSleepingItem
        unmountWhenMenu.addItem(systemStartsSleepingItem)
        
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
        let enabledVolumes = volumes.filter { $0.enabled }
        logger.info("Manual unmount-all triggered: \(enabledVolumes.count, privacy: .public) enabled volumes")
        enabledVolumes.forEach { volume in
            volume.unmount(force: Preference.forceUnmount)
        }
        updateMenu()
    }

    @objc private func volumeClicked(menuItem: NSMenuItem) {
        guard let volume = menuItem.representedObject as? ExternalVolume else {
            return
        }
        let newEnabledValue = toggledValue(for: menuItem.state)
        volume.enabled = newEnabledValue
        logger.info("Volume auto-unmount toggled: \(volume.name, privacy: .public) (\(volume.bsdName, privacy: .public)) enabled=\(newEnabledValue, privacy: .public)")
        updateMenu()
    }
    
    @objc private func launchAtLoginClicked(menuItem: NSMenuItem) {
        Preference.launchAtLogin = toggledValue(for: menuItem.state)
        updateMenu()
    }
    
    @objc private func unmountWhenChanged(menuItem: NSMenuItem) {
        if menuItem == unmountWhenScreensaverStartedItem {
            Preference.unmountWhen = .screensaverStarted
        } else if menuItem == unmountWhenScreenIsLockedItem {
            Preference.unmountWhen = .screenIsLocked
        } else if menuItem == unmountWhenScreensStartedSleepingItem {
            Preference.unmountWhen = .screensStartedSleeping
        } else if menuItem == unmountWhenSystemStartsSleepingItem {
            Preference.unmountWhen = .systemStartsSleeping
        }
        updateMenu()
    }
    
    @objc private func forceUnmountClicked(menuItem: NSMenuItem) {
        Preference.forceUnmount = toggledValue(for: menuItem.state)
        updateMenu()
    }
    
    @objc private func aboutClicked() {
        guard let url = URL(string: "https://ejectify.app") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
    
    @objc private func quitClicked() {
        Task { @MainActor in
            NSApplication.shared.terminate(nil)
        }
    }
}
