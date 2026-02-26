//
//  ActivityController.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 24/11/2020.
//

import AppKit
import OSLog

/// Responds to sleep/lock/screen-saver events by unmounting and remounting enabled volumes.
@MainActor
class ActivityController {
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "ActivityController")
    private let privilegedHelperManager = PrivilegedHelperManager.shared
    
    /// Volumes queued for remount attempts after the paired unmount trigger has been handled.
    private var queuedRemountVolumes: [ExternalVolume] = []

    init() {
        startMonitoring()
    }

    /// Re-registers event observers to match the current `Preference.unmountWhen` setting.
    func startMonitoring() {
        // Clear existing observers to avoid duplicate callbacks after preference changes.
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)

        // Register the matching unmount/mount trigger pair for the active preference.
        switch Preference.unmountWhen {
        case .screensaverStarted:
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(unmountVolumes(notification:)), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstart"), object: nil)
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(mountVolumes(notification:)), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstop"), object: nil)
        case .screenIsLocked:
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(unmountVolumes(notification:)), name: NSNotification.Name(rawValue: "com.apple.screenIsLocked"), object: nil)
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(mountVolumes(notification:)), name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"), object: nil)
        case .screensStartedSleeping:
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unmountVolumes(notification:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(mountVolumes(notification:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        case .systemStartsSleeping:
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unmountVolumes(notification:)), name: NSWorkspace.willSleepNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(mountVolumes(notification:)), name: NSWorkspace.didWakeNotification, object: nil)
        }

        logger.info("Monitoring configured for trigger: \(Preference.unmountWhen.rawValue, privacy: .public)")
    }

    /// Unmounts all currently enabled external volumes and tracks attempted unmounts for remount attempts.
    @objc func unmountVolumes(notification: Notification) {
        queuedRemountVolumes = ExternalVolume.mountedVolumes().filter { $0.enabled }
        logger.info("Unmount trigger received: \(notification.name.rawValue, privacy: .public)")
        for volume in queuedRemountVolumes {
            privilegedHelperManager.unmount(volumeUUID: volume.id as NSUUID, volumeName: volume.name, force: Preference.forceUnmount) { [weak self] success in
                guard !success else {
                    return
                }

                self?.logger.error("Privileged unmount failed for \(volume.name, privacy: .public)")
            }
        }
    }

    /// Attempts to remount volumes queued during the prior unmount attempt when the paired remount trigger fires, then clears the queue.
    @objc func mountVolumes(notification: Notification) {
        logger.info("Mount trigger received: \(notification.name.rawValue, privacy: .public)")
        for volume in queuedRemountVolumes {
            privilegedHelperManager.mount(volumeUUID: volume.id as NSUUID, volumeName: volume.name) { [weak self] success in
                guard !success else {
                    return
                }

                self?.logger.error("Privileged mount failed for \(volume.name, privacy: .public)")
            }
        }
        queuedRemountVolumes = []
    }
}
