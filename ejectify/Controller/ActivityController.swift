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
        let name: String
        let bsdName: String

        var description: String {
            "\(name) (\(bsdName))"
        }
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "ActivityController")
    /// Retry attempt schedule in seconds since mount trigger.
    private let retryDelays: [TimeInterval] = [0, 5, 15, 30, 60]
    private let reconciliationDelay: TimeInterval = 3
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

        logger.info("Monitoring configured for trigger: \(Preference.unmountWhen.rawValue, privacy: .public)")
    }

    @objc func unmountVolumes() {
        remountTask?.cancel()
        let volumesToUnmount = ExternalVolume.mountedVolumes().filter { $0.enabled }
        logger.info("Unmount trigger received: \(volumesToUnmount.count, privacy: .public) enabled volumes queued")
        volumesToUnmount.forEach { volume in
            pendingRemountVolumesByID[volume.id] = PendingRemountVolume(id: volume.id, name: volume.name, bsdName: volume.bsdName)
            volume.unmount(force: Preference.forceUnmount)
        }
    }

    @objc func mountVolumes() {
        remountTask?.cancel()

        guard !pendingRemountVolumesByID.isEmpty else {
            logger.info("Mount trigger received with no queued volumes")
            return
        }

        logger.info("Mount trigger received: \(self.pendingRemountVolumesByID.count, privacy: .public) volumes queued: \(self.pendingVolumeDescriptions(), privacy: .public)")
        remountTask = Task { [weak self] in
            await self?.runRemountCycle()
        }
    }

    /// Retries remounting until all queued volumes are mounted or retries are exhausted.
    private func runRemountCycle() async {
        do {
            let cycleStart = Date()
            for (attemptIndex, attemptOffset) in retryDelays.enumerated() {
                if pendingRemountVolumesByID.isEmpty {
                    logger.info("Mount queue completed successfully")
                    return
                }

                let elapsedBeforeAttempt = Date().timeIntervalSince(cycleStart)
                let waitBeforeAttempt = attemptOffset - elapsedBeforeAttempt
                if waitBeforeAttempt > 0 {
                    try await sleep(seconds: waitBeforeAttempt)
                }

                logger.info("Mount attempt \(attemptIndex + 1, privacy: .public) started for \(self.pendingRemountVolumesByID.count, privacy: .public) queued volumes: \(self.pendingVolumeDescriptions(), privacy: .public)")
                pendingRemountVolumesByID.values.forEach { pendingVolume in
                    if let freshVolume = ExternalVolume.fromBSDName(pendingVolume.bsdName) {
                        freshVolume.mount()
                    } else {
                        self.logger.warning("Queued volume not found by BSD name during remount: \(pendingVolume.name, privacy: .public) (\(pendingVolume.bsdName, privacy: .public))")
                    }
                }

                try await sleep(seconds: self.reconciliationDelay)
                reconcileRemountState()

                if pendingRemountVolumesByID.isEmpty {
                    logger.info("Mount queue completed successfully")
                    return
                }
            }

            logger.error("Mount retries exhausted; pending volumes: \(self.pendingVolumeDescriptions(), privacy: .public)")
        } catch is CancellationError {
            logger.info("Mount queue cancelled")
        } catch {
            logger.error("Mount queue failed with unexpected error: \(String(describing: error), privacy: .public)")
        }
    }

    /// Removes volumes from the remount queue once they are mounted again.
    private func reconcileRemountState() {
        let pendingBeforeReconciliation = pendingRemountVolumesByID.count
        let currentlyMountedVolumeIDs = Set(ExternalVolume.mountedVolumes().map { $0.id })

        pendingRemountVolumesByID = pendingRemountVolumesByID.filter { id, _ in
            !currentlyMountedVolumeIDs.contains(id)
        }

        let remainingCount = pendingRemountVolumesByID.count
        let resolvedCount = pendingBeforeReconciliation - remainingCount
        logger.info("Remount reconciliation: \(resolvedCount, privacy: .public) resolved, \(remainingCount, privacy: .public) still pending: \(self.pendingVolumeDescriptions(), privacy: .public)")
    }

    /// Sleeps for a wall-clock duration while preserving task cancellation.
    private func sleep(seconds: TimeInterval) async throws {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    /// Returns a deterministic description of the current remount queue for diagnostics.
    private func pendingVolumeDescriptions() -> String {
        pendingRemountVolumesByID.values
            .sorted { $0.name < $1.name }
            .map(\.description)
            .joined(separator: ", ")
    }
}
