//
//  ActivityController.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 24/11/2020.
//

import AppKit
import OSLog

/// Responds to sleep/lock/display events by unmounting and remounting enabled volumes.
@MainActor
class ActivityController {
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "ActivityController")
    private let privilegedHelperManager = PrivilegedHelperManager.shared
    
    /// Volumes eligible for remount, keyed by stable volume UUID.
    private var remountCandidates: [UUID: ExternalVolume] = [:]
    
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
        registerUnmountTriggerObserver()
        registerMountReadinessObservers()

        logger.info("Monitoring configured for trigger: \(Preference.unmountWhen.rawValue, privacy: .public)")
    }

    /// Unmounts all currently enabled external volumes and tracks attempted unmounts for remount attempts.
    @objc func unmountVolumes(notification: Notification) {
        logger.info("Unmount trigger received: \(notification.name.rawValue, privacy: .public)")
        for volume in ExternalVolume.mountedVolumes().filter({ $0.enabled }) {
            requestUnmount(for: volume) { _ in }
        }
    }

    /// Registers only the selected unmount trigger while remounting remains readiness-based.
    private func registerUnmountTriggerObserver() {
        switch Preference.unmountWhen {
        case .screenIsLocked:
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(unmountVolumes(notification:)), name: NSNotification.Name(rawValue: "com.apple.screenIsLocked"), object: nil)
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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleMountReadinessSystemWillSleep(notification:)), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleMountReadinessSystemDidWake(notification:)), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleMountReadinessScreensDidSleep(notification:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleMountReadinessScreensDidWake(notification:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleMountReadinessSessionDidResignActive(notification:)), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleMountReadinessSessionDidBecomeActive(notification:)), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        DistributedNotificationCenter.default.addObserver(self, selector: #selector(handleMountReadinessScreenLocked(notification:)), name: NSNotification.Name(rawValue: "com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default.addObserver(self, selector: #selector(handleMountReadinessScreenUnlocked(notification:)), name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"), object: nil)
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
            self.systemAwake = systemAwake
        }
        if let displayAwake {
            self.displayAwake = displayAwake
        }
        if let sessionActive {
            self.sessionActive = sessionActive
        }
        if let screenLocked {
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
        }
    }

    /// Triggers one fire-and-forget mount pass for all remount candidates.
    private func triggerMountPass() {
        guard !self.remountCandidates.isEmpty else {
            logger.info("Mount pass skipped: no remount candidates")
            return
        }

        logger.info("Mount pass triggered: \(self.remountCandidates.count, privacy: .public) candidate(s)")
        for volume in self.remountCandidates.values {
            scheduleMountTask(for: volume)
        }
    }

    /// Marks system as sleeping in readiness state.
    @objc private func handleMountReadinessSystemWillSleep(notification _: Notification) {
        updateMountReadinessState(systemAwake: false)
    }

    /// Marks system as awake in readiness state.
    @objc private func handleMountReadinessSystemDidWake(notification _: Notification) {
        updateMountReadinessState(systemAwake: true)
    }

    /// Marks displays as sleeping in readiness state.
    @objc private func handleMountReadinessScreensDidSleep(notification _: Notification) {
        updateMountReadinessState(displayAwake: false)
    }

    /// Marks displays as awake in readiness state.
    @objc private func handleMountReadinessScreensDidWake(notification _: Notification) {
        updateMountReadinessState(displayAwake: true)
    }

    /// Marks the user session as inactive in readiness state.
    @objc private func handleMountReadinessSessionDidResignActive(notification _: Notification) {
        updateMountReadinessState(sessionActive: false)
    }

    /// Marks the user session as active in readiness state.
    @objc private func handleMountReadinessSessionDidBecomeActive(notification _: Notification) {
        updateMountReadinessState(sessionActive: true)
    }

    /// Marks the lock screen as shown in readiness state.
    @objc private func handleMountReadinessScreenLocked(notification _: Notification) {
        updateMountReadinessState(screenLocked: true)
    }

    /// Marks the lock screen as dismissed in readiness state.
    @objc private func handleMountReadinessScreenUnlocked(notification _: Notification) {
        updateMountReadinessState(screenLocked: false)
    }

    /// Cancels and removes any pending mount task for a volume.
    private func cancelPendingMountTask(for volumeID: UUID) {
        pendingMountTasks[volumeID]?.cancel()
        pendingMountTasks.removeValue(forKey: volumeID)
    }

    /// Schedules an immediate mount task for a volume when one is not already pending.
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
        case .systemWillSleep(let token):
            beginSystemSleepDelay(token: token)
        case .systemHasPoweredOn:
            logger.info("System wake power message received")
            updateMountReadinessState(systemAwake: true)
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
