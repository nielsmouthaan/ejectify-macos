//
//  StatusBarMenu.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import AppKit
import Carbon
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
        if let volume = managedExternalVolume(from: notification, urlKey: NSWorkspace.volumeURLUserInfoKey) {
            logger.info("Volume did mount: \(volume.logLabel, privacy: .public)")
        }
        refreshVolumesMenu()
    }

    /// Handles unmount notifications and logs unmount metadata provided by NSWorkspace.
    @objc private func volumeDidUnmount(notification: Notification) {
        if let volume = managedExternalVolume(from: notification, urlKey: NSWorkspace.volumeURLUserInfoKey) {
            logger.info("Volume did unmount: \(volume.logLabel, privacy: .public)")
        }
        refreshVolumesMenu()
    }

    /// Handles rename notifications and logs old/new metadata provided by NSWorkspace.
    @objc private func volumeDidRename(notification: Notification) {
        let newVolume = managedExternalVolume(from: notification, urlKey: NSWorkspace.volumeURLUserInfoKey)
        let oldVolume = managedExternalVolume(from: notification, urlKey: NSWorkspace.oldVolumeURLUserInfoKey)
        guard newVolume != nil || oldVolume != nil else {
            refreshVolumesMenu()
            return
        }

        let newVolumeLabel = volumeLogLabel(
            from: notification,
            urlKey: NSWorkspace.volumeURLUserInfoKey,
            nameKey: NSWorkspace.localizedVolumeNameUserInfoKey
        )
        let oldVolumeLabel = volumeLogLabel(
            from: notification,
            urlKey: NSWorkspace.oldVolumeURLUserInfoKey,
            nameKey: NSWorkspace.oldLocalizedVolumeNameUserInfoKey
        )
        logger.info("Volume did rename: \(oldVolumeLabel, privacy: .public) -> \(newVolumeLabel, privacy: .public)")
        refreshVolumesMenu()
    }

    /// Refreshes the in-memory volume list and rebuilds the status menu.
    private func refreshVolumesMenu() {
        volumes = ExternalVolume.mountedVolumes()
        updateMenu()
    }

    /// Returns a string metadata value from notification userInfo or an empty string when absent.
    private func stringUserInfoValue(_ key: String, from notification: Notification) -> String {
        notification.userInfo?[key] as? String ?? ""
    }

    /// Resolves a notification URL to a managed external volume using the same filter as `mountedVolumes`.
    private func managedExternalVolume(from notification: Notification, urlKey: String) -> ExternalVolume? {
        guard let url = notification.userInfo?[urlKey] as? URL else {
            return nil
        }

        guard ExternalVolume.isManagedMountedVolumeURL(url) else {
            return nil
        }

        return ExternalVolume.fromURL(url: url)
    }

    /// Returns a canonical log label and omits unavailable metadata when notification details are missing.
    private func volumeLogLabel(from notification: Notification, urlKey: String, nameKey: String) -> String {
        if let volume = managedExternalVolume(from: notification, urlKey: urlKey) {
            return volume.logLabel
        }

        let localizedName = stringUserInfoValue(nameKey, from: notification)
        return VolumeLogLabelFormatter.label(name: localizedName, uuidString: "", bsdName: "")
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
        let unmountAllItem = NSMenuItem(title: "Unmount all".localized, action: #selector(unmountAllClicked(menuItem:)), keyEquivalent: "")
        unmountAllItem.target = self
        unmountAllItem.isEnabled = !volumes.isEmpty
        addItem(unmountAllItem)
    }

    /// Builds the "Volumes" section with one toggle row per mounted volume.
    private func buildVolumesMenu() {
        addItem(NSMenuItem.separator())

        addItem(makeSectionHeaderItem(title: "Volumes".localized))

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

        addItem(makeSectionHeaderItem(title: "Preferences".localized))

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

        let elevatedPermissionsItem = NSMenuItem(title: "Use elevated permissions".localized, action: #selector(elevatedPermissionsClicked(menuItem:)), keyEquivalent: "")
        elevatedPermissionsItem.target = self
        elevatedPermissionsItem.state = elevatedPermissionsMenuState
        addItem(elevatedPermissionsItem)

        let muteNotificationsItem = NSMenuItem(title: "Force mute notifications".localized, action: #selector(muteNotificationsClicked(menuItem:)), keyEquivalent: "")
        muteNotificationsItem.target = self
        muteNotificationsItem.state = isForceMuteNotificationsEnabled() ? .on : .off
        addItem(muteNotificationsItem)
    }

    /// Converts menu state toggles to a Bool value.
    private func toggledValue(for state: NSControl.StateValue) -> Bool {
        state == .off
    }

    /// Represents enabled elevated permissions only when user preference and daemon state are both active.
    private var elevatedPermissionsMenuState: NSControl.StateValue {
        (Preference.useElevatedPermissions && PrivilegedHelperManager.shared.isDaemonEnabled) ? .on : .off
    }

    /// Returns whether force-muting notifications is enabled in the system Disk Arbitration plist.
    /// Any read failure or missing value is treated as unmuted (`false`).
    private func isForceMuteNotificationsEnabled() -> Bool {
        guard
            let preferences = NSDictionary(contentsOfFile: PrivilegedHelperConfiguration.diskArbitrationPreferencesPath),
            let rawValue = preferences[PrivilegedHelperConfiguration.disableEjectNotificationKey]
        else {
            return false
        }

        if let boolValue = rawValue as? Bool {
            return boolValue
        }

        if let numberValue = rawValue as? NSNumber {
            return numberValue.boolValue
        }

        if let stringValue = rawValue as? String {
            return NSString(string: stringValue).boolValue
        }

        return false
    }

    /// Creates a native AppKit section header item for menu grouping.
    private func makeSectionHeaderItem(title: String) -> NSMenuItem {
        NSMenuItem.sectionHeader(title: title)
    }

    /// Builds the submenu for selecting the unmount trigger condition.
    private func buildUnmountWhenMenu() -> NSMenu {
        let unmountWhenMenu = NSMenu(title: "Unmount when".localized)
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
            let bsdName = volume.bsdName
            let forceUnmount = Preference.forceUnmount
            Task { @MainActor in
                PrivilegedHelperManager.shared.unmount(volumeUUID: volumeUUID, volumeName: volumeName, bsdName: bsdName, force: forceUnmount) { _ in }
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
        logger.info("Volume auto-unmount toggled: \(volume.logLabel, privacy: .public) enabled=\(newEnabledValue, privacy: .public)")
        updateMenu()
    }

    /// Toggles launch-at-login preference from the menu.
    @objc private func launchAtLoginClicked(menuItem: NSMenuItem) {
        Preference.launchAtLogin = toggledValue(for: menuItem.state)
        updateMenu()
    }

    /// Toggles privileged helper registration for elevated mount and unmount attempts.
    @MainActor
    @objc private func elevatedPermissionsClicked(menuItem: NSMenuItem) {
        let shouldEnable = toggledValue(for: menuItem.state)
        let helperManager = PrivilegedHelperManager.shared
        let previousValue = Preference.useElevatedPermissions
        Preference.useElevatedPermissions = shouldEnable
        let didSucceed = helperManager.configureOperationMode()

        guard didSucceed else {
            Preference.useElevatedPermissions = previousValue
            if shouldEnable {
                showPermissionAlert(
                    messageText: "Could not enable elevated permissions.".localized,
                    informativeText: "Check System Settings if Ejectify is enabled.".localized
                )
            } else {
                showPermissionAlert(
                    messageText: "Could not disable elevated permissions.".localized
                )
            }
            updateMenu()
            return
        }

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

    /// Toggles muting of system "Disk Not Ejected Properly" notifications.
    @MainActor
    @objc private func muteNotificationsClicked(menuItem: NSMenuItem) {
        let shouldMute = toggledValue(for: menuItem.state)
        PrivilegedHelperManager.shared.setEjectNotificationsMuted(shouldMute) { [weak self] success, details in
            guard let self else {
                return
            }

            guard success else {
                showPermissionAlert(
                    messageText: shouldMute ? "Could not mute notifications".localized : "Could not unmute notifications".localized,
                    informativeText: details
                )
                updateMenu()
                return
            }

            showRestartRequiredAlert(shouldMute: shouldMute)
            updateMenu()
        }
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

    /// Shows a user-friendly alert for elevated permission registration failures.
    @MainActor
    private func showPermissionAlert(messageText: String, informativeText: String? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = informativeText ?? ""
        alert.runModal()
    }

    /// Shows a restart-required alert and optionally triggers immediate restart.
    @MainActor
    private func showRestartRequiredAlert(shouldMute: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Restart required".localized
        alert.informativeText = shouldMute
            ? "Please restart your Mac to apply the change and mute notifications.".localized
            : "Please restart your Mac to apply the change and unmute notifications.".localized
        alert.addButton(withTitle: "Restart".localized)
        alert.addButton(withTitle: "Later".localized)

        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else {
            return
        }

        requestSystemRestart()
    }

    /// Requests a soft restart by sending `kAERestart` to the system loginwindow process.
    @MainActor
    private func requestSystemRestart() {
        var targetDescriptor = AEAddressDesc()
        let targetProcessSerialNumber = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kSystemProcess))
        let targetCreateStatus = withUnsafePointer(to: targetProcessSerialNumber) { pointer in
            AECreateDesc(
                DescType(typeProcessSerialNumber),
                pointer,
                MemoryLayout<ProcessSerialNumber>.size,
                &targetDescriptor
            )
        }
        guard targetCreateStatus == noErr else {
            return
        }
        defer {
            AEDisposeDesc(&targetDescriptor)
        }

        var restartEvent = AppleEvent()
        let eventCreateStatus = AECreateAppleEvent(
            AEEventClass(kCoreEventClass),
            AEEventID(kAERestart),
            &targetDescriptor,
            AEReturnID(kAutoGenerateReturnID),
            AETransactionID(kAnyTransactionID),
            &restartEvent
        )
        guard eventCreateStatus == noErr else {
            return
        }
        defer {
            AEDisposeDesc(&restartEvent)
        }

        var eventReply = AppleEvent()
        defer {
            AEDisposeDesc(&eventReply)
        }

        let sendStatus = AESendMessage(
            &restartEvent,
            &eventReply,
            AESendMode(kAENoReply),
            kAEDefaultTimeout
        )
        guard sendStatus == noErr else {
            return
        }
    }
}
