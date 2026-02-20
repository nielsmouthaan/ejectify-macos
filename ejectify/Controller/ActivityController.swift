//
//  ActivityController.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 24/11/2020.
//

import AppKit
import OSLog

@MainActor
class ActivityController {
    /// Tracks volumes that should be remounted after wake.
    private struct PendingRemountVolume {
        let id: String
        let bsdName: String
    }

    private let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "ActivityController")
    private let retryDelays: [TimeInterval] = [0, 1, 2, 4, 8, 15]
    private var pendingRemountVolumesByID: [String: PendingRemountVolume] = [:]
    private var remountTask: Task<Void, Never>?

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
        remountTask?.cancel()
        let volumesToUnmount = ExternalVolume.mountedVolumes().filter { $0.enabled }
        os_log("Unmount trigger received. %{public}@ enabled volumes queued.", log: self.log, type: .default, String(volumesToUnmount.count))
        volumesToUnmount.forEach { volume in
            pendingRemountVolumesByID[volume.id] = PendingRemountVolume(id: volume.id, bsdName: volume.bsdName)
            volume.unmount(force: Preference.forceUnmount)
        }
    }

    @objc func mountVolumes() {
        remountTask?.cancel()

        guard !pendingRemountVolumesByID.isEmpty else {
            os_log("Mount trigger received with no queued volumes.", log: self.log, type: .default)
            return
        }

        os_log("Mount trigger received. %{public}@ volumes queued.", log: self.log, type: .default, String(self.pendingRemountVolumesByID.count))
        remountTask = Task { [weak self] in
            await self?.runRemountCycle()
        }
    }

    /// Retries remounting until all queued volumes are mounted or retries are exhausted.
    private func runRemountCycle() async {
        do {
            var attemptIndex = 0
            while !pendingRemountVolumesByID.isEmpty {
                os_log("Mount attempt %{public}@ started for %{public}@ queued volumes.", log: self.log, type: .default, String(attemptIndex + 1), String(self.pendingRemountVolumesByID.count))
                pendingRemountVolumesByID.values.forEach { pendingVolume in
                    if let freshVolume = ExternalVolume.fromBSDName(pendingVolume.bsdName) {
                        freshVolume.mount()
                    }
                }

                try await sleep(seconds: 1)
                reconcileRemountState()

                if pendingRemountVolumesByID.isEmpty {
                    os_log("Mount queue completed successfully.", log: self.log, type: .default)
                    return
                }

                attemptIndex += 1
                if attemptIndex >= retryDelays.count {
                    os_log("Mount retries exhausted. %{public}@ volumes still pending.", log: self.log, type: .error, String(self.pendingRemountVolumesByID.count))
                    return
                }

                let retryDelay = retryDelays[attemptIndex]
                if retryDelay > 0 {
                    try await sleep(seconds: retryDelay)
                }
            }
        } catch is CancellationError {
            os_log("Mount queue cancelled.", log: self.log, type: .default)
        } catch {
            os_log("Mount queue failed with unexpected error: %{public}@", log: self.log, type: .error, String(describing: error))
        }
    }

    /// Removes volumes from the remount queue once they are mounted again.
    private func reconcileRemountState() {
        let currentlyMountedVolumeIDs = Set(ExternalVolume.mountedVolumes().map { $0.id })

        pendingRemountVolumesByID = pendingRemountVolumesByID.filter { id, _ in
            !currentlyMountedVolumeIDs.contains(id)
        }
    }

    /// Sleeps for a wall-clock duration while preserving task cancellation.
    private func sleep(seconds: TimeInterval) async throws {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
