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
final class StatusBarMenu: NSMenu {

    /// Logger used for menu-driven actions and volume notifications.
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "StatusBarMenu")

    /// Destination URL used by the Help action.
    private let helpURL = URL(string: "https://ejectify.app/help")!

    /// Cached mounted volumes shown in the menu.
    private var volumes: [Volume]

    /// Required initializer for storyboard/nib usage.
    required init(coder: NSCoder) {
        volumes = Volume.mountedVolumes()
        super.init(coder: coder)
        listenForOperationRouterNotifications()
        updateMenu()
        listenForVolumeNotifications()
    }

    /// Initializes the menu, loads mounted volumes, and starts notifications.
    init() {
        volumes = Volume.mountedVolumes()
        super.init(title: "Ejectify")
        listenForOperationRouterNotifications()
        updateMenu()
        listenForVolumeNotifications()
    }

    /// Removes registered workspace observers before deallocation.
    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self, name: .volumeOperationRouterDidChange, object: VolumeOperationRouter.shared)
    }

    /// Starts observing mount, unmount, and rename events to keep the menu current.
    private func listenForVolumeNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumeDidRename(notification:)), name: NSWorkspace.didRenameVolumeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumeDidMount(notification:)), name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumeDidUnmount(notification:)), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    /// Observes router state changes so the menu can reflect daemon availability updates.
    private func listenForOperationRouterNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(operationRouterDidChange(_:)), name: .volumeOperationRouterDidChange, object: VolumeOperationRouter.shared)
    }

    /// Rebuilds the menu whenever operation routing availability changes.
    @objc private func operationRouterDidChange(_ notification: Notification) {
        if Thread.isMainThread {
            updateMenu()
            return
        }

        performSelector(onMainThread: #selector(updateMenuFromMainThread), with: nil, waitUntilDone: false)
    }

    /// Rebuilds the menu from the main thread when observer callbacks arrive off-main.
    @objc private func updateMenuFromMainThread() {
        updateMenu()
    }

    /// Handles mount notifications and logs mount metadata provided by NSWorkspace.
    @objc private func volumeDidMount(notification: Notification) {
        if let volume = managedVolume(from: notification, urlKey: NSWorkspace.volumeURLUserInfoKey) {
            logger.info("Volume did mount: \(volume.logLabel, privacy: .public)")
        }
        refreshVolumesMenu()
    }

    /// Handles unmount notifications and logs unmount metadata provided by NSWorkspace.
    @objc private func volumeDidUnmount(notification: Notification) {
        if let volume = cachedVolume(from: notification, urlKey: NSWorkspace.volumeURLUserInfoKey) {
            logger.info("Volume did unmount: \(volume.logLabel, privacy: .public)")
        }
        refreshVolumesMenu()
    }

    /// Handles rename notifications and logs old/new metadata provided by NSWorkspace.
    @objc private func volumeDidRename(notification: Notification) {
        if let volume = cachedVolume(from: notification, urlKey: NSWorkspace.oldVolumeURLUserInfoKey) {
            let newVolumeName = notification.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String ?? ""
            let newVolumeLabel = VolumeLogLabelFormatter.label(name: newVolumeName, uuid: volume.id, bsdName: volume.bsdName)
            logger.info("Volume did rename: \(volume.logLabel, privacy: .public) -> \(newVolumeLabel, privacy: .public)")
        }
        refreshVolumesMenu()
    }

    /// Refreshes the in-memory volume list and rebuilds the status menu.
    private func refreshVolumesMenu() {
        volumes = Volume.mountedVolumes()
        updateMenu()
    }

    /// Returns a volume from cached `volumes` by matching a notification URL path.
    private func cachedVolume(from notification: Notification, urlKey: String) -> Volume? {
        guard let url = notification.userInfo?[urlKey] as? URL else {
            return nil
        }

        let targetPath = url.standardizedFileURL.path
        return volumes.first(where: { $0.url.standardizedFileURL.path == targetPath })
    }

    /// Resolves a notification URL to a managed volume using the same filter as `mountedVolumes`.
    private func managedVolume(from notification: Notification, urlKey: String) -> Volume? {
        guard let url = notification.userInfo?[urlKey] as? URL else {
            return nil
        }

        return Volume.fromURL(url: url)
    }

    /// Rebuilds all top-level menu sections from current app state.
    private func updateMenu() {
        guard Thread.isMainThread else {
            performSelector(onMainThread: #selector(updateMenuFromMainThread), with: nil, waitUntilDone: false)
            return
        }

        removeAllItems()
        buildActionsMenu()
        buildVolumesMenu()
        buildPreferencesMenu()
        buildAppMenu()
    }

    /// Builds the top "Actions" section.
    private func buildActionsMenu() {
        let unmountAllItem = NSMenuItem(title: String(localized: "Unmount all"), action: #selector(unmountAllClicked(menuItem:)), keyEquivalent: "")
        unmountAllItem.target = self
        unmountAllItem.isEnabled = !volumes.isEmpty
        addItem(unmountAllItem)
    }

    /// Builds the "Volumes" section with one toggle row per mounted volume.
    private func buildVolumesMenu() {
        addItem(NSMenuItem.separator())

        addVolumeSection(title: String(localized: "Internal"), category: .internalVolume)
        addVolumeSection(title: String(localized: "External"), category: .external)
        addVolumeSection(title: String(localized: "Disk Images"), category: .diskImage)
    }

    /// Adds one grouped volume section in the configured category order.
    private func addVolumeSection(title: String, category: Volume.Category) {
        let volumesForCategory = volumes.filter { $0.category == category }
        guard !volumesForCategory.isEmpty else {
            return
        }

        addItem(NSMenuItem.sectionHeader(title: title))
        for volume in volumesForCategory {
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

        addItem(NSMenuItem.sectionHeader(title: String(localized: "Preferences")))

        let launchAtLoginItem = NSMenuItem(title: String(localized: "Launch at login"), action: #selector(launchAtLoginClicked(menuItem:)), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = Preference.launchAtLogin ? .on : .off
        addItem(launchAtLoginItem)

        let unmountWhenItem = NSMenuItem(title: String(localized: "Unmount when"), action: nil, keyEquivalent: "")
        unmountWhenItem.submenu = buildUnmountWhenMenu()
        addItem(unmountWhenItem)

        let forceUnmountItem = NSMenuItem(title: String(localized: "Force unmount"), action: #selector(forceUnmountClicked(menuItem:)), keyEquivalent: "")
        forceUnmountItem.target = self
        forceUnmountItem.state = Preference.forceUnmount ? .on : .off
        addItem(forceUnmountItem)

        let elevatedPermissionsItem = NSMenuItem(title: String(localized: "Use elevated permissions"), action: #selector(elevatedPermissionsClicked(menuItem:)), keyEquivalent: "")
        elevatedPermissionsItem.target = self
        elevatedPermissionsItem.state = elevatedPermissionsMenuState
        addItem(elevatedPermissionsItem)

        let muteNotificationsItem = NSMenuItem(title: String(localized: "Force mute notifications"), action: #selector(muteNotificationsClicked(menuItem:)), keyEquivalent: "")
        muteNotificationsItem.target = self
        muteNotificationsItem.state = isForceMuteNotificationsEnabled() ? .on : .off
        addItem(muteNotificationsItem)
    }

    /// Converts menu state toggles to a Bool value.
    private func toggledValue(for state: NSControl.StateValue) -> Bool {
        state == .off
    }

    /// Represents enabled elevated permissions when the privileged helper is approved and enabled.
    private var elevatedPermissionsMenuState: NSControl.StateValue {
        VolumeOperationRouter.shared.isDaemonEnabled ? .on : .off
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

    /// Builds the submenu for selecting the unmount trigger condition.
    private func buildUnmountWhenMenu() -> NSMenu {
        let unmountWhenMenu = NSMenu(title: String(localized: "Unmount when"))
        unmountWhenMenu.addItem(makeUnmountWhenMenuItem(title: String(localized: "Display turned off"), unmountWhen: .screensStartedSleeping))
        unmountWhenMenu.addItem(makeUnmountWhenMenuItem(title: String(localized: "System starts sleeping"), unmountWhen: .systemStartsSleeping))

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

    /// Builds app-level actions such as Help and Quit.
    private func buildAppMenu() {
        addItem(NSMenuItem.separator())

        let helpItem = NSMenuItem(title: String(localized: "About Ejectify"), action: #selector(helpClicked), keyEquivalent: "")
        helpItem.target = self
        addItem(helpItem)

        let checkForUpdatesItem = NSMenuItem(title: String(localized: "Check for Updates…"), action: #selector(checkForUpdatesClicked), keyEquivalent: "")
        checkForUpdatesItem.target = self
        addItem(checkForUpdatesItem)

        let quitItem = NSMenuItem(title: String(localized: "Quit Ejectify"), action: #selector(quitClicked), keyEquivalent: "")
        quitItem.target = self
        addItem(quitItem)
    }

    /// Unmounts all currently enabled volumes from the menu action.
    @objc private func unmountAllClicked(menuItem _: NSMenuItem) {
        let enabledVolumes = volumes.filter { $0.enabled }
        logger.info("Manual unmount-all triggered: \(enabledVolumes.count, privacy: .public) enabled volumes")
        for volume in enabledVolumes {
            VolumeOperationRouter.shared.unmount(
                volumeUUID: volume.id as NSUUID,
                volumeName: volume.name,
                bsdName: volume.bsdName,
                force: Preference.forceUnmount
            ) { _ in }
        }
        updateMenu()
    }

    /// Toggles automatic handling for a specific volume row.
    @objc private func volumeClicked(menuItem: NSMenuItem) {
        guard let volume = menuItem.representedObject as? Volume else {
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
        let operationRouter = VolumeOperationRouter.shared
        let didSucceed: Bool

        if shouldEnable {
            didSucceed = operationRouter.requestPrivilegedExecutionMode()
            guard !didSucceed else {
                updateMenu()
                return
            }

            showPermissionAlert(
                messageText: String(localized: "Could not enable elevated permissions."),
                informativeText: String(localized: "Check System Settings if Ejectify is enabled.")
            )
            updateMenu()
            return
        }

        didSucceed = operationRouter.disablePrivilegedExecutionMode()
        guard didSucceed else {
            showPermissionAlert(
                messageText: String(localized: "Could not disable elevated permissions.")
            )
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
        VolumeOperationRouter.shared.setEjectNotificationsMuted(shouldMute) { [weak self] success, details in
            guard let self else {
                return
            }

            guard success else {
                showPermissionAlert(
                    messageText: shouldMute ? String(localized: "Could not mute notifications") : String(localized: "Could not unmute notifications"),
                    informativeText: details
                )
                updateMenu()
                return
            }

            showRestartRequiredAlert(shouldMute: shouldMute)
            updateMenu()
        }
    }

    /// Opens the Ejectify Help Center website.
    @objc private func helpClicked() {
        NSWorkspace.shared.open(helpURL)
    }

    /// Starts a manual Sparkle update check from the status menu.
    @MainActor
    @objc private func checkForUpdatesClicked() {
        AppDelegate.shared.checkForUpdates()
    }

    /// Terminates the app from the menu action.
    @MainActor
    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
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
        alert.messageText = String(localized: "Restart required")
        alert.informativeText = shouldMute
            ? String(localized: "Please restart your Mac to apply the change and mute notifications.")
            : String(localized: "Please restart your Mac to apply the change and unmute notifications.")
        alert.addButton(withTitle: String(localized: "Restart"))
        alert.addButton(withTitle: String(localized: "Later"))

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
            logger.error("Failed to create restart target descriptor: status=\(targetCreateStatus, privacy: .public)")
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
            logger.error("Failed to create restart Apple Event: status=\(eventCreateStatus, privacy: .public)")
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
            logger.error("Failed to send restart Apple Event: status=\(sendStatus, privacy: .public)")
            return
        }
    }
}
