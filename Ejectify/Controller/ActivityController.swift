//
//  ActivityController.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 24/11/2020.
//

import AppKit
import OSLog
@preconcurrency import DiskArbitration

/// Responds to sleep/lock/display events by unmounting and remounting enabled volumes.
@MainActor
final class ActivityController {

    /// Logger used for mount/unmount and readiness transition diagnostics.
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "ActivityController")

    /// Volumes still pending automatic remount after a successful automatic unmount.
    private var remountCandidates: [Volume] = []

    /// Volume UUIDs currently processing an unmount request.
    private var inFlightUnmounts: Set<UUID> = []

    /// Pending mount tasks keyed by volume UUID.
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

    /// Tracks whether the machine is currently awake enough to permit remounting.
    private var systemAwake = true

    /// Tracks whether at least one display is awake and available.
    private var displayAwake = true

    /// Tracks whether the user session is active on the console.
    private var sessionActive = true

    /// Tracks whether the lock screen is currently active.
    private var screenLocked = false

    /// Returns whether the system is considered ready for one mount pass.
    private var isReadyToMount: Bool {
        systemAwake && displayAwake && sessionActive && !screenLocked
    }

    /// Maximum number of seconds sleep may be deferred while unmounting.
    private static let maximumSystemSleepDelaySeconds = 10

    /// Hard cap for delaying system sleep while waiting for unmount completion.
    private static let maximumSystemSleepDelay: Duration = .seconds(maximumSystemSleepDelaySeconds)

    /// Delays used for automatic remount retries after a failed attempt.
    private static let remountRetryDelays: [Duration] = [
        .seconds(3),
        .seconds(10),
        .seconds(30)
    ]

    /// Distributed notification posted when the screen lock is engaged.
    private static let screenLockedNotificationName = Notification.Name("com.apple.screenIsLocked")

    /// Distributed notification posted when the screen lock is released.
    private static let screenUnlockedNotificationName = Notification.Name("com.apple.screenIsUnlocked")

    /// Initializes observers based on the current unmount trigger preference.
    init() {
        startMonitoring()
    }

    /// Re-registers event observers to match the current `Preference.unmountWhen` setting.
    func startMonitoring() {
        // Clear existing observers to avoid duplicate callbacks after preference changes.
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
        stopSystemSleepPowerMonitoring(reason: "Monitoring reconfigured")
        registerUnmountTriggerObserver()
        registerMountReadinessObservers()

        logger.info("Monitoring configured for trigger: \(Preference.unmountWhen.rawValue, privacy: .public)")
    }

    /// Unmounts all currently enabled volumes and tracks attempted unmounts for remount attempts.
    @objc func unmountVolumes(notification: Notification) {
        logger.info("Unmount trigger received: \(notification.name.rawValue, privacy: .public)")
        let enabledVolumes = Volume.mountedVolumes().filter(\.enabled)
        mergeRemountCandidates(with: enabledVolumes, reason: "Unmount trigger received")

        for volume in enabledVolumes {
            requestUnmount(for: volume) { _ in }
        }
    }

    /// Registers only the selected unmount trigger while remounting remains readiness-based.
    private func registerUnmountTriggerObserver() {
        switch Preference.unmountWhen {
        case .screensStartedSleeping:
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unmountVolumes(notification:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        case .systemStartsSleeping:
            if !startSystemSleepPowerMonitoring() {
                logger.warning("IOKit power monitoring unavailable; falling back to NSWorkspace.willSleepNotification")
                NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unmountVolumes(notification:)), name: NSWorkspace.willSleepNotification, object: nil)
            }
        }
    }

    /// Registers notifications that update the "ready-to-mount" state.
    private func registerMountReadinessObservers() {
        let workspaceReadinessNotifications: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]

        for name in workspaceReadinessNotifications {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleMountReadinessNotification(_:)), name: name, object: nil)
        }

        let distributedReadinessNotifications = [
            Self.screenLockedNotificationName,
            Self.screenUnlockedNotificationName
        ]
        for name in distributedReadinessNotifications {
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(handleMountReadinessNotification(_:)), name: name, object: nil)
        }
    }

    /// Applies state updates and triggers one mount pass when readiness transitions to true.
    private func updateMountReadinessState(
        systemAwake: Bool? = nil,
        displayAwake: Bool? = nil,
        sessionActive: Bool? = nil,
        screenLocked: Bool? = nil
    ) {
        let wasReadyToMount = isReadyToMount

        if let systemAwake {
            logger.info("\(systemAwake ? "System is awake" : "System is sleeping", privacy: .public)")
            self.systemAwake = systemAwake
        }

        if let displayAwake {
            logger.info("\(displayAwake ? "Display is awake" : "Display is sleeping", privacy: .public)")
            self.displayAwake = displayAwake
        }

        if let sessionActive {
            logger.info("\(sessionActive ? "Session is active" : "Session is inactive", privacy: .public)")
            self.sessionActive = sessionActive
        }

        if let screenLocked {
            logger.info("\(screenLocked ? "Screen is locked" : "Screen is unlocked", privacy: .public)")
            self.screenLocked = screenLocked
        }

        let isNowReadyToMount = self.isReadyToMount

        guard wasReadyToMount != isNowReadyToMount else {
            return
        }

        if isNowReadyToMount {
            logger.info("Mount readiness reached ready state")
            triggerMountPass()
        } else {
            logger.info("Mount readiness left ready state")
            cancelAllPendingMountTasks(reason: "Mount readiness left ready state")
        }
    }

    /// Triggers one fire-and-forget mount pass for all remount candidates.
    private func triggerMountPass() {
        guard !self.remountCandidates.isEmpty else {
            logger.info("Mount pass skipped: no remount candidates")
            return
        }

        logger.info("Mount pass triggered: \(self.remountCandidates.count, privacy: .public) candidate(s)")
        for volume in self.remountCandidates {
            scheduleMountTask(for: volume)
        }
    }

    /// Merges new automatic unmounts into the pending remount set while preserving older pending entries.
    private func mergeRemountCandidates(with volumes: [Volume], reason: String) {
        let existingCount = remountCandidates.count

        guard !volumes.isEmpty else {
            if existingCount > 0 {
                logger.info("Preserving \(existingCount, privacy: .public) pending remount candidate(s): \(reason, privacy: .public)")
            }
            return
        }

        var mergedCandidates = remountCandidates
        var addedCount = 0
        var refreshedCount = 0

        for volume in volumes {
            if let index = mergedCandidates.firstIndex(where: { $0.id == volume.id }) {
                mergedCandidates[index] = volume
                refreshedCount += 1
            } else {
                mergedCandidates.append(volume)
                addedCount += 1
            }
        }

        remountCandidates = mergedCandidates

        if existingCount > 0 {
            logger.info(
                "Merged remount candidates: preserved \(existingCount, privacy: .public), refreshed \(refreshedCount, privacy: .public), added \(addedCount, privacy: .public), total \(self.remountCandidates.count, privacy: .public): \(reason, privacy: .public)"
            )
        }
    }

    /// Returns whether the pending remount set still includes a volume ID.
    private func hasRemountCandidate(withID volumeID: UUID) -> Bool {
        remountCandidates.contains { $0.id == volumeID }
    }

    /// Removes a volume from the pending remount set.
    private func removeRemountCandidate(withID volumeID: UUID) {
        remountCandidates.removeAll { $0.id == volumeID }
    }

    /// Applies readiness-state updates from workspace and distributed notifications.
    @objc private func handleMountReadinessNotification(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.willSleepNotification:
            updateMountReadinessState(systemAwake: false)
        case NSWorkspace.didWakeNotification:
            updateMountReadinessState(systemAwake: true)
        case NSWorkspace.screensDidSleepNotification:
            updateMountReadinessState(displayAwake: false)
        case NSWorkspace.screensDidWakeNotification:
            updateMountReadinessState(displayAwake: true)
        case NSWorkspace.sessionDidResignActiveNotification:
            updateMountReadinessState(sessionActive: false)
        case NSWorkspace.sessionDidBecomeActiveNotification:
            updateMountReadinessState(sessionActive: true)
        case Self.screenLockedNotificationName:
            updateMountReadinessState(screenLocked: true)
        case Self.screenUnlockedNotificationName:
            updateMountReadinessState(screenLocked: false)
        default:
            return
        }
    }

    /// Cancels and removes any pending mount task for a volume.
    private func cancelPendingMountTask(for volumeID: UUID) {
        pendingMountTasks[volumeID]?.cancel()
        pendingMountTasks.removeValue(forKey: volumeID)
    }

    /// Cancels all currently pending mount or retry tasks.
    private func cancelAllPendingMountTasks(reason: String) {
        guard !pendingMountTasks.isEmpty else {
            return
        }

        logger.info("Cancelling \(self.pendingMountTasks.count, privacy: .public) pending mount task(s): \(reason, privacy: .public)")
        for task in pendingMountTasks.values {
            task.cancel()
        }
        pendingMountTasks.removeAll()
    }

    /// Schedules an immediate mount task for a volume when one is not already pending.
    private func scheduleMountTask(for volume: Volume) {
        let volumeID = volume.id
        guard pendingMountTasks[volumeID] == nil else {
            return
        }

        logger.info("Mount request scheduled for \(volume.logLabel, privacy: .public)")

        pendingMountTasks[volumeID] = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.pendingMountTasks.removeValue(forKey: volumeID)
            }

            var attemptIndex = 0

            while !Task.isCancelled {
                guard self.isReadyToMount else {
                    return
                }

                guard self.hasRemountCandidate(withID: volumeID) else {
                    return
                }

                guard DiskArbitrationVolumeOperator.canResolveDisk(volumeUUID: volume.id, volumeName: volume.name, bsdName: volume.bsdName) else {
                    self.logger.info("Skipping mount retry because disk is no longer available for \(volume.logLabel, privacy: .public)")
                    self.removeRemountCandidate(withID: volumeID)
                    return
                }

                let result: (success: Bool, message: String?, status: DAReturn?) = await withCheckedContinuation { continuation in
                    VolumeOperationRouter.shared.mount(volumeUUID: volumeID as NSUUID, volumeName: volume.name, bsdName: volume.bsdName) { success, message, status in
                        continuation.resume(returning: (success, message, status))
                    }
                }

                guard !Task.isCancelled else {
                    return
                }

                if result.success {
                    self.removeRemountCandidate(withID: volumeID)
                    return
                }

                if let message = result.message, !message.isEmpty {
                    self.logger.error("Mount failed for \(volume.logLabel, privacy: .public): \(message, privacy: .public)")
                } else {
                    self.logger.error("Mount failed for \(volume.logLabel, privacy: .public)")
                }

                guard result.status?.shouldRetryAutomaticRemount ?? true else {
                    self.logger.info("Mount retry skipped due to non-retryable status for \(volume.logLabel, privacy: .public)")
                    self.removeRemountCandidate(withID: volumeID)
                    return
                }

                guard attemptIndex < Self.remountRetryDelays.count else {
                    self.logger.info("Mount retry limit reached for \(volume.logLabel, privacy: .public)")
                    self.removeRemountCandidate(withID: volumeID)
                    return
                }

                let retryNumber = attemptIndex + 1
                let retryDelay = Self.remountRetryDelays[attemptIndex]
                attemptIndex += 1
                logger.info("Scheduling mount retry \(retryNumber, privacy: .public)/\(Self.remountRetryDelays.count, privacy: .public) for \(volume.logLabel, privacy: .public)")

                do {
                    try await Task.sleep(for: retryDelay)
                } catch {
                    return
                }
            }
        }
    }

    /// Starts IOKit power monitoring used to delay sleep while unmounting volumes.
    @discardableResult
    private func startSystemSleepPowerMonitoring() -> Bool {
        if systemSleepPowerObserver == nil {
            systemSleepPowerObserver = SystemSleepPowerObserver { [weak self] token in
                self?.beginSystemSleepDelay(token: token)
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
        updateMountReadinessState(systemAwake: false)
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

        /// Number of enabled volumes included in the batch request.
        let requestedCount: Int

        /// Number of volume unmount requests that reported success.
        let succeededCount: Int
    }

    /// Unmounts all enabled volumes and waits for every callback to complete.
    private func unmountEnabledVolumesAndWait() async -> UnmountBatchResult {
        let enabledVolumes = Volume.mountedVolumes().filter { $0.enabled }
        mergeRemountCandidates(with: enabledVolumes, reason: "Starting new system sleep unmount batch")

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

    /// Enqueues a routed unmount request for one volume and tracks in-flight state.
    private func requestUnmount(for volume: Volume, completion: @escaping (Bool) -> Void) {
        let volumeID = volume.id
        cancelPendingMountTask(for: volumeID)
        pendingUnmountCompletions[volumeID, default: []].append(completion)

        guard !inFlightUnmounts.contains(volumeID) else {
            logger.info("Unmount request joined existing in-flight operation: \(volume.logLabel, privacy: .public)")
            return
        }

        inFlightUnmounts.insert(volumeID)
        logger.info("Unmount request scheduled for \(volume.logLabel, privacy: .public)")
        VolumeOperationRouter.shared.unmount(volumeUUID: volume.id as NSUUID, volumeName: volume.name, bsdName: volume.bsdName, force: Preference.forceUnmount) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(success)
                    return
                }

                self.inFlightUnmounts.remove(volumeID)
                if !success {
                    self.removeRemountCandidate(withID: volumeID)
                }
                let completions = self.pendingUnmountCompletions.removeValue(forKey: volumeID) ?? []
                completions.forEach { $0(success) }
            }
        }
    }

}
