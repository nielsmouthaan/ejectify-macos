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
    
    /// Volumes eligible for remount, keyed by stable volume UUID.
    private var remountCandidates: [UUID: ExternalVolume] = [:]
    
    /// Volume UUIDs currently processing an unmount request.
    private var inFlightUnmounts: Set<UUID> = []
    
    /// Pending delayed mount tasks keyed by volume UUID.
    private var pendingMountTasks: [UUID: Task<Void, Never>] = [:]

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
        let enabledVolumes = ExternalVolume.mountedVolumes().filter { $0.enabled }
        logger.info("Unmount trigger received: \(notification.name.rawValue, privacy: .public)")
        for volume in enabledVolumes {
            let volumeID = volume.id
            remountCandidates[volumeID] = volume
            cancelPendingMountTask(for: volumeID)

            guard !inFlightUnmounts.contains(volumeID) else {
                continue
            }

            inFlightUnmounts.insert(volumeID)
            privilegedHelperManager.unmount(volumeUUID: volume.id as NSUUID, volumeName: volume.name, bsdName: volume.bsdName, force: Preference.forceUnmount) { [weak self] success in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }

                    self.inFlightUnmounts.remove(volumeID)
                    guard !success else {
                        return
                    }

                    self.logger.error("Privileged unmount failed for \(volume.logLabel, privacy: .public)")
                }
            }
        }
    }

    /// Attempts to remount tracked volumes when the paired remount trigger fires.
    @objc func mountVolumes(notification: Notification) {
        logger.info("Mount trigger received: \(notification.name.rawValue, privacy: .public)")
        for volume in remountCandidates.values {
            scheduleMountTask(for: volume)
        }
    }

    /// Cancels and removes any pending delayed mount task for a volume.
    private func cancelPendingMountTask(for volumeID: UUID) {
        pendingMountTasks[volumeID]?.cancel()
        pendingMountTasks.removeValue(forKey: volumeID)
    }

    /// Schedules a delayed or immediate mount task for a volume when one is not already pending.
    private func scheduleMountTask(for volume: ExternalVolume) {
        let volumeID = volume.id
        guard pendingMountTasks[volumeID] == nil else {
            return
        }

        pendingMountTasks[volumeID] = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.pendingMountTasks.removeValue(forKey: volumeID)
            }

            if Preference.mountAfterDelay {
                try? await Task.sleep(for: .seconds(5))
            }
            guard !Task.isCancelled else {
                return
            }

            privilegedHelperManager.mount(volumeUUID: volume.id as NSUUID, volumeName: volume.name, bsdName: volume.bsdName) { [weak self] success in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }

                    if success {
                        self.remountCandidates.removeValue(forKey: volumeID)
                    } else {
                        self.logger.error("Privileged mount failed for \(volume.logLabel, privacy: .public)")
                    }
                }
            }
        }
    }
}
