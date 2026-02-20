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

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "ActivityController")
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
        logger.info("Unmount trigger received: \(volumesToUnmount.count) enabled volumes queued")
        volumesToUnmount.forEach { volume in
            pendingRemountVolumesByID[volume.id] = PendingRemountVolume(id: volume.id, bsdName: volume.bsdName)
            volume.unmount(force: Preference.forceUnmount)
        }
    }

    @objc func mountVolumes() {
        remountTask?.cancel()

        guard !pendingRemountVolumesByID.isEmpty else {
            logger.info("Mount trigger received with no queued volumes")
            return
        }

        logger.info("Mount trigger received: \(self.pendingRemountVolumesByID.count) volumes queued")
        remountTask = Task { [weak self] in
            await self?.runRemountCycle()
        }
    }

    /// Retries remounting until all queued volumes are mounted or retries are exhausted.
    private func runRemountCycle() async {
        do {
            var attemptIndex = 0
            while !pendingRemountVolumesByID.isEmpty {
                logger.info("Mount attempt \(attemptIndex + 1) started for \(self.pendingRemountVolumesByID.count) queued volumes")
                pendingRemountVolumesByID.values.forEach { pendingVolume in
                    if let freshVolume = ExternalVolume.fromBSDName(pendingVolume.bsdName) {
                        freshVolume.mount()
                    }
                }

                try await sleep(seconds: 1)
                reconcileRemountState()

                if pendingRemountVolumesByID.isEmpty {
                    logger.info("Mount queue completed successfully")
                    return
                }

                attemptIndex += 1
                if attemptIndex >= retryDelays.count {
                    logger.error("Mount retries exhausted, \(self.pendingRemountVolumesByID.count) volumes still pending")
                    return
                }

                let retryDelay = retryDelays[attemptIndex]
                if retryDelay > 0 {
                    try await sleep(seconds: retryDelay)
                }
            }
        } catch is CancellationError {
            logger.info("Mount queue cancelled")
        } catch {
            logger.error("Mount queue failed with unexpected error: \(String(describing: error))")
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
