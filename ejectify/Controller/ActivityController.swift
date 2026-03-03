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

    /// Pending completion handlers for each in-flight unmount keyed by volume UUID.
    private var pendingUnmountCompletions: [UUID: [(Bool) -> Void]] = [:]

    /// Handles IOKit system sleep callbacks used to temporarily delay system sleep.
    private var systemSleepPowerObserver: SystemSleepPowerObserver?

    /// Pending system-sleep token currently held while unmount requests run.
    private var pendingSystemSleepToken: Int?

    /// Timeout task that enforces the maximum system sleep delay.
    private var pendingSystemSleepTimeoutTask: Task<Void, Never>?

    /// Unmount task started for the pending system sleep token.
    private var pendingSystemSleepUnmountTask: Task<Void, Never>?

    /// Maximum number of seconds sleep may be deferred while unmounting.
    private static let maximumSystemSleepDelaySeconds = 5

    /// Hard cap for delaying system sleep while waiting for unmount completion.
    private static let maximumSystemSleepDelay: Duration = .seconds(maximumSystemSleepDelaySeconds)

    init() {
        startMonitoring()
    }

    /// Re-registers event observers to match the current `Preference.unmountWhen` setting.
    func startMonitoring() {
        // Clear existing observers to avoid duplicate callbacks after preference changes.
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
        stopSystemSleepPowerMonitoring(reason: "Monitoring reconfigured")

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
            if !startSystemSleepPowerMonitoring() {
                logger.warning("IOKit power monitoring unavailable; falling back to NSWorkspace.willSleepNotification")
                NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unmountVolumes(notification:)), name: NSWorkspace.willSleepNotification, object: nil)
            }
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(mountVolumes(notification:)), name: NSWorkspace.didWakeNotification, object: nil)
        }

        logger.info("Monitoring configured for trigger: \(Preference.unmountWhen.rawValue, privacy: .public)")
    }

    /// Unmounts all currently enabled external volumes and tracks attempted unmounts for remount attempts.
    @objc func unmountVolumes(notification: Notification) {
        logger.info("Unmount trigger received: \(notification.name.rawValue, privacy: .public)")
        for volume in ExternalVolume.mountedVolumes().filter({ $0.enabled }) {
            requestUnmount(for: volume) { _ in }
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
                    }
                }
            }
        }
    }

    /// Starts IOKit power monitoring used to delay sleep while unmounting volumes.
    @discardableResult
    private func startSystemSleepPowerMonitoring() -> Bool {
        if systemSleepPowerObserver == nil {
            systemSleepPowerObserver = SystemSleepPowerObserver { [weak self] powerEvent in
                self?.handleSystemPowerEvent(powerEvent)
            }
        }
        return systemSleepPowerObserver?.start() ?? false
    }

    /// Stops IOKit power monitoring and releases any pending system-sleep delay immediately.
    private func stopSystemSleepPowerMonitoring(reason: String) {
        allowPendingSystemSleepIfNeeded(reason: reason)
        cancelPendingSystemSleepTasks()
        systemSleepPowerObserver?.stop()
        systemSleepPowerObserver = nil
    }

    /// Handles typed system power events received through the power observer.
    private func handleSystemPowerEvent(_ powerEvent: SystemSleepPowerObserver.Event) {
        switch powerEvent {
        case .canSystemSleep(let token):
            logger.info("System sleep check received; allowing sleep for token \(token, privacy: .public)")
            systemSleepPowerObserver?.allowPowerChange(for: token)
        case .systemWillSleep(let token):
            beginSystemSleepDelay(token: token)
        case .systemHasPoweredOn:
            logger.info("System wake power message received")
        }
    }

    /// Delays system sleep while unmounting and automatically releases sleep after success or timeout.
    private func beginSystemSleepDelay(token: Int) {
        if let pendingToken = pendingSystemSleepToken {
            if pendingToken == token {
                logger.info("Duplicate system sleep token received: \(token, privacy: .public)")
                return
            }

            logger.warning("Ignoring overlapping system sleep token \(token, privacy: .public) while waiting on token \(pendingToken, privacy: .public)")
            systemSleepPowerObserver?.allowPowerChange(for: token)
            return
        }

        pendingSystemSleepToken = token
        logger.info("System will sleep received; delaying sleep for up to \(Self.maximumSystemSleepDelaySeconds, privacy: .public) seconds to unmount enabled volumes")

        pendingSystemSleepTimeoutTask?.cancel()
        pendingSystemSleepTimeoutTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await Task.sleep(for: Self.maximumSystemSleepDelay)
            } catch {
                return
            }
            guard pendingSystemSleepToken == token else {
                return
            }
            logger.warning("System sleep delay reached \(Self.maximumSystemSleepDelaySeconds, privacy: .public)-second cap")
            allowSystemSleepIfNeeded(for: token, reason: "\(Self.maximumSystemSleepDelaySeconds)-second timeout reached")
        }

        pendingSystemSleepUnmountTask?.cancel()
        pendingSystemSleepUnmountTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let batchResult = await unmountEnabledVolumesAndWait()
            guard pendingSystemSleepToken == token else {
                logger.info("Ignoring unmount completion for stale system sleep token \(token, privacy: .public)")
                return
            }
            logger.info("System sleep unmount batch finished: \(batchResult.succeededCount, privacy: .public)/\(batchResult.requestedCount, privacy: .public) succeeded")
            allowSystemSleepIfNeeded(for: token, reason: "unmount batch completed")
        }
    }

    /// Allows system sleep for the pending token exactly once.
    private func allowPendingSystemSleepIfNeeded(reason: String) {
        guard let token = pendingSystemSleepToken else {
            return
        }
        allowSystemSleepIfNeeded(for: token, reason: reason)
    }

    /// Allows system sleep for a specific token when it still matches the pending request.
    private func allowSystemSleepIfNeeded(for token: Int, reason: String) {
        guard pendingSystemSleepToken == token else {
            return
        }
        pendingSystemSleepToken = nil
        cancelPendingSystemSleepTasks()
        logger.info("Allowing system sleep for token \(token, privacy: .public): \(reason, privacy: .public)")
        systemSleepPowerObserver?.allowPowerChange(for: token)
    }

    /// Cancels and clears pending timeout/unmount tasks for an active system-sleep delay.
    private func cancelPendingSystemSleepTasks() {
        pendingSystemSleepTimeoutTask?.cancel()
        pendingSystemSleepTimeoutTask = nil
        pendingSystemSleepUnmountTask?.cancel()
        pendingSystemSleepUnmountTask = nil
    }

    /// Represents the completion summary for one unmount batch.
    private struct UnmountBatchResult {
        let requestedCount: Int
        let succeededCount: Int
    }

    /// Unmounts all enabled volumes and waits for every callback to complete.
    private func unmountEnabledVolumesAndWait() async -> UnmountBatchResult {
        let enabledVolumes = ExternalVolume.mountedVolumes().filter { $0.enabled }
        guard !enabledVolumes.isEmpty else {
            return UnmountBatchResult(requestedCount: 0, succeededCount: 0)
        }

        return await withCheckedContinuation { continuation in
            var pendingCallbacks = enabledVolumes.count
            var succeededCount = 0
            var didResume = false

            func completeIfNeeded() {
                guard !didResume, pendingCallbacks == 0 else {
                    return
                }
                didResume = true
                continuation.resume(returning: UnmountBatchResult(requestedCount: enabledVolumes.count, succeededCount: succeededCount))
            }

            for volume in enabledVolumes {
                requestUnmount(for: volume) { success in
                    if success {
                        succeededCount += 1
                    }
                    pendingCallbacks -= 1
                    completeIfNeeded()
                }
            }

            completeIfNeeded()
        }
    }

    /// Enqueues a privileged unmount request for one volume and tracks in-flight state.
    private func requestUnmount(for volume: ExternalVolume, completion: @escaping (Bool) -> Void) {
        let volumeID = volume.id
        remountCandidates[volumeID] = volume
        cancelPendingMountTask(for: volumeID)
        pendingUnmountCompletions[volumeID, default: []].append(completion)

        guard !inFlightUnmounts.contains(volumeID) else {
            logger.info("Unmount request joined existing in-flight operation: \(volume.logLabel, privacy: .public)")
            return
        }

        inFlightUnmounts.insert(volumeID)
        privilegedHelperManager.unmount(volumeUUID: volume.id as NSUUID, volumeName: volume.name, bsdName: volume.bsdName, force: Preference.forceUnmount) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(success)
                    return
                }

                self.inFlightUnmounts.remove(volumeID)
                let completions = self.pendingUnmountCompletions.removeValue(forKey: volumeID) ?? []
                completions.forEach { $0(success) }
            }
        }
    }

}
