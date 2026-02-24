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
    /// Tracks volumes that Ejectify unmounted and should mount again on wake.
    private var unmountedVolumes: [ExternalVolume] = []

    /// Starts observing the configured trigger event immediately.
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
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(unmountVolumes), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstart"), object: nil)
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(mountVolumes), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstop"), object: nil)
        case .screenIsLocked:
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(unmountVolumes), name: NSNotification.Name(rawValue: "com.apple.screenIsLocked"), object: nil)
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(mountVolumes), name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"), object: nil)
        case .screensStartedSleeping:
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unmountVolumes), name: NSWorkspace.screensDidSleepNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(mountVolumes), name: NSWorkspace.screensDidWakeNotification, object: nil)
        case .systemStartsSleeping:
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unmountVolumes), name: NSWorkspace.willSleepNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(mountVolumes), name: NSWorkspace.didWakeNotification, object: nil)
        }

        logger.info("Monitoring configured for trigger: \(Preference.unmountWhen.rawValue, privacy: .public)")
    }

    /// Unmounts all currently enabled external volumes and tracks them for remounting.
    @objc func unmountVolumes() {
        unmountedVolumes = ExternalVolume.mountedVolumes().filter { $0.enabled }
        let volumeCount = unmountedVolumes.count
        logger.info("Unmount trigger received: \(volumeCount, privacy: .public) enabled volumes queued")
        for volume in unmountedVolumes {
            volume.unmount(force: Preference.forceUnmount)
        }
    }

    /// Remounts previously tracked volumes and clears the remount queue.
    @objc func mountVolumes() {
        guard !unmountedVolumes.isEmpty else {
            logger.info("Mount trigger received with no tracked volumes")
            return
        }

        let volumeCount = unmountedVolumes.count
        logger.info("Mount trigger received: \(volumeCount, privacy: .public) volumes")
        for volume in unmountedVolumes {
            volume.mount()
        }
        unmountedVolumes = []
    }
}
