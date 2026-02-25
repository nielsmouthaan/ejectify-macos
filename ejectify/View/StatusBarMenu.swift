//
//  StatusBarMenu.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import AppKit
import OSLog

/// Builds and updates the status bar menu for volume actions and preferences.
class StatusBarMenu: NSMenu {
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "StatusBarMenu")
    
    /// Cached mounted volumes shown in the menu.
    private var volumes: [ExternalVolume]

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

    /// Starts observing mount, unmount, and rename events to keep the menu current.
    private func listenForVolumeNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumeDidRename(notification:)), name: NSWorkspace.didRenameVolumeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumeDidMount(notification:)), name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumeDidUnmount(notification:)), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    /// Handles mount notifications and logs mount metadata provided by NSWorkspace.
    @objc private func volumeDidMount(notification: Notification) {
        let localizedName = stringUserInfoValue(NSWorkspace.localizedVolumeNameUserInfoKey, from: notification)
        let volumeURL = volumePathUserInfoValue(NSWorkspace.volumeURLUserInfoKey, from: notification)
        if shouldLogVolumeEvent(notification: notification, urlKey: NSWorkspace.volumeURLUserInfoKey) {
            logger.info("Volume did mount: \(localizedName, privacy: .public) (\(volumeURL, privacy: .public)).")
        }
        refreshVolumesMenu()
    }

    /// Handles unmount notifications and logs unmount metadata provided by NSWorkspace.
    @objc private func volumeDidUnmount(notification: Notification) {
        let localizedName = stringUserInfoValue(NSWorkspace.localizedVolumeNameUserInfoKey, from: notification)
        let volumeURL = volumePathUserInfoValue(NSWorkspace.volumeURLUserInfoKey, from: notification)
        if shouldLogVolumeEvent(notification: notification, urlKey: NSWorkspace.volumeURLUserInfoKey) {
            logger.info("Volume did unmount: \(localizedName, privacy: .public) (\(volumeURL, privacy: .public)).")
        }
        refreshVolumesMenu()
    }

    /// Handles rename notifications and logs old/new metadata provided by NSWorkspace.
    @objc private func volumeDidRename(notification: Notification) {
        let shouldLogOldVolume = shouldLogVolumeEvent(notification: notification, urlKey: NSWorkspace.oldVolumeURLUserInfoKey)
        let shouldLogNewVolume = shouldLogVolumeEvent(notification: notification, urlKey: NSWorkspace.volumeURLUserInfoKey)
        if shouldLogOldVolume || shouldLogNewVolume {
            let localizedName = stringUserInfoValue(NSWorkspace.localizedVolumeNameUserInfoKey, from: notification)
            let volumeURL = volumePathUserInfoValue(NSWorkspace.volumeURLUserInfoKey, from: notification)
            let oldLocalizedName = stringUserInfoValue(NSWorkspace.oldLocalizedVolumeNameUserInfoKey, from: notification)
            let oldVolumeURL = volumePathUserInfoValue(NSWorkspace.oldVolumeURLUserInfoKey, from: notification)
            logger.info("Volume did rename: \(oldLocalizedName, privacy: .public) (\(oldVolumeURL, privacy: .public)) -> \(localizedName, privacy: .public) (\(volumeURL, privacy: .public)).")
        }
        refreshVolumesMenu()
    }

    /// Refreshes the in-memory volume list and rebuilds the status menu.
    private func refreshVolumesMenu() {
        volumes = ExternalVolume.mountedVolumes()
        updateMenu()
    }

    /// Returns a string metadata value from notification userInfo or "unknown" when absent.
    private func stringUserInfoValue(_ key: String, from notification: Notification) -> String {
        notification.userInfo?[key] as? String ?? "unknown"
    }

    /// Returns a volume path from notification userInfo URL metadata or "unknown" when absent.
    private func volumePathUserInfoValue(_ key: String, from notification: Notification) -> String {
        (notification.userInfo?[key] as? URL)?.path ?? "unknown"
    }

    /// Determines whether a notification volume URL resolves to an enabled Ejectify volume.
    private func shouldLogVolumeEvent(notification: Notification, urlKey: String) -> Bool {
        guard let url = notification.userInfo?[urlKey] as? URL,
              let volume = ExternalVolume.fromURL(url: url) else {
            return false
        }
        return volume.enabled
    }

    /// Rebuilds all top-level menu sections from current app state.
    private func updateMenu() {
        self.removeAllItems()
        buildActionsMenu()
        buildVolumesMenu()
        buildPreferencesMenu()
        buildAppMenu()
    }

    /// Builds the top "Actions" section.
    private func buildActionsMenu() {
        let titleItem = NSMenuItem(title: "Actions".localized, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        addItem(titleItem)

        let unmountAllItem = NSMenuItem(title: "Unmount all".localized, action: #selector(unmountAllClicked(menuItem:)), keyEquivalent: "")
        unmountAllItem.target = self
        addItem(unmountAllItem)
    }

    /// Builds the "Volumes" section with one toggle row per mounted volume.
    private func buildVolumesMenu() {
        addItem(NSMenuItem.separator())

        let title = volumes.count == 0 ? "No volumes".localized : "Volumes".localized
        let titleItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        addItem(titleItem)

        volumes.forEach { (volume) in
            let volumeItem = NSMenuItem(title: volume.name, action: #selector(volumeClicked(menuItem:)), keyEquivalent: "")
            volumeItem.target = self
            volumeItem.state = volume.enabled ? .on : .off
            volumeItem.representedObject = volume
            addItem(volumeItem)
        }
    }

    /// Builds user-configurable app preferences.
    private func buildPreferencesMenu() {
        addItem(NSMenuItem.separator())

        let titleItem = NSMenuItem(title: "Preferences".localized, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        addItem(titleItem)

        let launchAtLoginItem = NSMenuItem(title: "Launch at login".localized, action: #selector(launchAtLoginClicked(menuItem:)), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = Preference.launchAtLogin ? .on : .off
        addItem(launchAtLoginItem)

        let unmountWhenItem = NSMenuItem(title: "Unmount when".localized, action: nil, keyEquivalent: "")
        unmountWhenItem.submenu = buildUnmountWhenMenu()
        addItem(unmountWhenItem)

        let forceUnmountItem = NSMenuItem(title: "Force unmount".localized, action: #selector(forceUnmountClicked(menuItem:)), keyEquivalent: "")
        forceUnmountItem.target = self
        forceUnmountItem.state = Preference.forceUnmount ? .on : .off
        addItem(forceUnmountItem)
    }

    /// Converts menu state toggles to a Bool value.
    private func toggledValue(for state: NSControl.StateValue) -> Bool {
        state == .off
    }

    /// Builds the submenu for selecting the unmount trigger condition.
    private func buildUnmountWhenMenu() -> NSMenu {
        let unmountWhenMenu = NSMenu(title: "Unmount when".localized)
        unmountWhenMenu.addItem(makeUnmountWhenMenuItem(title: "Screensaver started".localized, unmountWhen: .screensaverStarted))
        unmountWhenMenu.addItem(makeUnmountWhenMenuItem(title: "Screen is locked".localized, unmountWhen: .screenIsLocked))
        unmountWhenMenu.addItem(makeUnmountWhenMenuItem(title: "Display turned off".localized, unmountWhen: .screensStartedSleeping))
        unmountWhenMenu.addItem(makeUnmountWhenMenuItem(title: "System starts sleeping".localized, unmountWhen: .systemStartsSleeping))
        
        return unmountWhenMenu
    }

    /// Creates an "Unmount when" menu entry bound to a specific preference value.
    private func makeUnmountWhenMenuItem(title: String, unmountWhen: Preference.UnmountWhen) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(unmountWhenChanged(menuItem:)), keyEquivalent: "")
        item.target = self
        item.state = Preference.unmountWhen == unmountWhen ? .on : .off
        item.representedObject = unmountWhen
        return item
    }

    /// Builds app-level actions such as About and Quit.
    private func buildAppMenu() {
        addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About Ejectify".localized, action: #selector(aboutClicked), keyEquivalent: "")
        aboutItem.target = self
        addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit Ejectify".localized, action: #selector(quitClicked), keyEquivalent: "")
        quitItem.target = self
        addItem(quitItem)
    }

    /// Unmounts all currently enabled volumes from the menu action.
    @objc private func unmountAllClicked(menuItem: NSMenuItem) {
        let enabledVolumes = volumes.filter { $0.enabled }
        logger.info("Manual unmount-all triggered: \(enabledVolumes.count, privacy: .public) enabled volumes")
        enabledVolumes.forEach { volume in
            let volumeUUID = volume.id as NSUUID
            let volumeName = volume.name
            let forceUnmount = Preference.forceUnmount
            let logger = self.logger
            Task { @MainActor in
                PrivilegedHelperManager.shared.unmount(volumeUUID: volumeUUID, volumeName: volumeName, force: forceUnmount) { success in
                    guard !success else {
                        return
                    }

                    logger.error("Privileged manual unmount failed for \(volumeName, privacy: .public)")
                }
            }
        }
        updateMenu()
    }

    /// Toggles automatic handling for a specific volume row.
    @objc private func volumeClicked(menuItem: NSMenuItem) {
        guard let volume = menuItem.representedObject as? ExternalVolume else {
            return
        }
        let newEnabledValue = toggledValue(for: menuItem.state)
        volume.enabled = newEnabledValue
        logger.info("Volume auto-unmount toggled: \(volume.name, privacy: .public) enabled=\(newEnabledValue, privacy: .public)")
        updateMenu()
    }

    /// Toggles launch-at-login preference from the menu.
    @objc private func launchAtLoginClicked(menuItem: NSMenuItem) {
        Preference.launchAtLogin = toggledValue(for: menuItem.state)
        updateMenu()
    }

    /// Updates the selected unmount trigger preference.
    @objc private func unmountWhenChanged(menuItem: NSMenuItem) {
        guard let unmountWhen = menuItem.representedObject as? Preference.UnmountWhen else {
            return
        }
        Preference.unmountWhen = unmountWhen
        updateMenu()
    }

    /// Toggles force-unmount preference from the menu.
    @objc private func forceUnmountClicked(menuItem: NSMenuItem) {
        Preference.forceUnmount = toggledValue(for: menuItem.state)
        updateMenu()
    }

    /// Opens the Ejectify website.
    @objc private func aboutClicked() {
        guard let url = URL(string: "https://ejectify.app") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Terminates the app from the menu action.
    @objc private func quitClicked() {
        Task { @MainActor in
            NSApplication.shared.terminate(nil)
        }
    }
}
