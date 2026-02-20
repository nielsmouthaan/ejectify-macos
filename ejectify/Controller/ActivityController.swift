//
//  ActivityController.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 24/11/2020.
//

import AppKit
import OSLog

class ActivityController {
    private struct PendingRemountVolume {
        let id: String
        let bsdName: String
    }

    private let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "ActivityController")
    private let retryDelays: [TimeInterval] = [0, 1, 2, 4, 8, 15]
    private var pendingRemountVolumesByID: [String: PendingRemountVolume] = [:]
    private var remountWorkItem: DispatchWorkItem?

    init() {
        startMonitoring()
    }

    func startMonitoring() {

        // Stop observing first
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)

        // Start observing based on preference
        switch Preference.unmountWhen {
        case .screensaverStarted:
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(unmountVolumes), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstart"), object: nil)
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(mountVolumes), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstop"), object: nil)
            break
        case .screenIsLocked:
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(unmountVolumes), name: NSNotification.Name(rawValue: "com.apple.screenIsLocked"), object: nil)
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(mountVolumes), name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"), object: nil)
            break
        case .screensStartedSleeping:
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unmountVolumes), name: NSWorkspace.screensDidSleepNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(mountVolumes), name: NSWorkspace.screensDidWakeNotification, object: nil)
            break
        case .systemStartsSleeping:
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unmountVolumes), name: NSWorkspace.willSleepNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(mountVolumes), name: NSWorkspace.didWakeNotification, object: nil)
        }
    }

    @objc func unmountVolumes() {
        let volumesToUnmount = ExternalVolume.mountedVolumes().filter { $0.enabled }
        os_log("Unmount trigger received. %{public}@ enabled volumes queued.", log: self.log, type: .default, String(volumesToUnmount.count))
        volumesToUnmount.forEach { volume in
            pendingRemountVolumesByID[volume.id] = PendingRemountVolume(id: volume.id, bsdName: volume.bsdName)
            volume.unmount(force: Preference.forceUnmount)
        }
    }

    @objc func mountVolumes() {
        remountWorkItem?.cancel()

        guard !pendingRemountVolumesByID.isEmpty else {
            os_log("Mount trigger received with no queued volumes.", log: self.log, type: .default)
            return
        }

        let initialDelay: TimeInterval = Preference.mountAfterDelay ? 5 : 0
        os_log("Mount trigger received. %{public}@ volumes queued. Delay: %{public}@s.", log: self.log, type: .default, String(self.pendingRemountVolumesByID.count), String(Int(initialDelay)))
        scheduleRemountAttempt(index: 0, delay: initialDelay)
    }

    private func scheduleRemountAttempt(index: Int, delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.performRemountAttempt(index: index)
        }

        remountWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func performRemountAttempt(index: Int) {
        guard !pendingRemountVolumesByID.isEmpty else {
            return
        }

        os_log("Mount attempt %{public}@ started for %{public}@ queued volumes.", log: self.log, type: .default, String(index + 1), String(self.pendingRemountVolumesByID.count))
        pendingRemountVolumesByID.values.forEach { pendingVolume in
            if let freshVolume = ExternalVolume.fromBSDName(pendingVolume.bsdName) {
                freshVolume.mount()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.reconcileRemountState(afterAttemptAt: index)
        }
    }

    private func reconcileRemountState(afterAttemptAt index: Int) {
        let currentlyMountedVolumeIDs = Set(ExternalVolume.mountedVolumes().map { $0.id })

        pendingRemountVolumesByID = pendingRemountVolumesByID.filter { id, _ in
            !currentlyMountedVolumeIDs.contains(id)
        }

        if pendingRemountVolumesByID.isEmpty {
            os_log("Mount queue completed successfully.", log: self.log, type: .default)
            return
        }

        let nextAttemptIndex = index + 1
        if nextAttemptIndex >= retryDelays.count {
            os_log("Mount retries exhausted. %{public}@ volumes still pending.", log: self.log, type: .error, String(self.pendingRemountVolumesByID.count))
            return
        }

        scheduleRemountAttempt(index: nextAttemptIndex, delay: retryDelays[nextAttemptIndex])
    }
}
