//
//  ActivityController.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 24/11/2020.
//

import AppKit
@preconcurrency import DiskArbitration

/// Responds to sleep/lock/display events by unmounting or ejecting enabled volumes and remounting when applicable.
@MainActor
final class ActivityController {


    /// Volumes still pending wake-time reconciliation after an automatic unmount attempt.
    private var remountCandidates: [Volume] = []

    /// Volume identifiers currently processing an unmount request.
    private var inFlightUnmounts: Set<String> = []

    /// Whole-disk BSD names currently processing an eject request.
    private var inFlightEjects: Set<String> = []

    /// Pending mount tasks keyed by volume identifier.
    private var pendingMountTasks: [String: Task<Void, Never>] = [:]

    /// Volume identifiers currently owned by an encrypted APFS unlock workflow.
    private var encryptedUnlocksInProgress: Set<String> = []

    /// Pending completion handlers for each in-flight unmount keyed by volume identifier.
    private var pendingUnmountCompletions: [String: [(Bool) -> Void]] = [:]

    /// Pending completion handlers for each in-flight eject keyed by whole-disk BSD name.
    private var pendingEjectCompletions: [String: [(Bool) -> Void]] = [:]

    /// Store used for encrypted APFS volume unlock passwords.
    private let encryptedVolumeCredentialStore = EncryptedVolumeCredentialStore.shared

    /// Probe used to confirm that an encrypted APFS volume is locked after a normal mount failure.
    private let encryptedVolumeLockStateProbe = APFSVolumeLockStateProbe.shared

    /// Unlocker used when an encrypted APFS volume remains locked after a normal mount failure.
    private let encryptedVolumeUnlocker = APFSEncryptedVolumeUnlocker.shared

    /// Prompt used to ask for encrypted volume passwords when needed.
    private let encryptedVolumePasswordPrompt = EncryptedVolumePasswordPrompt()

    /// Describes the final effect of encrypted APFS unlock handling on its remount candidate.
    private enum EncryptedVolumeUnlockOutcome {
        case succeeded
        case mountNormally
        case failed
        case deferred
    }

    /// Handles IOKit system sleep callbacks used to temporarily delay system sleep.
    private var systemSleepPowerObserver: SystemSleepPowerObserver?

    /// Pending system-sleep token currently held while disk-operation requests run.
    private var pendingSystemSleepToken: Int?

    /// Timeout task that enforces the maximum system sleep delay.
    private var pendingSystemSleepTimeoutTask: Task<Void, Never>?

    /// Disk-operation task started for the pending system sleep token.
    private var pendingSystemSleepDiskOperationTask: Task<Void, Never>?

    /// Tracks whether the machine is currently awake enough to permit remounting.
    private var systemAwake = true

    /// Tracks whether at least one display is awake and available.
    private var displayAwake = true

    /// Tracks whether the user session is active on the console.
    private var sessionActive = true

    /// Tracks whether the lock screen is currently active.
    private var screenLocked = false

    /// Tracks whether the screen saver is currently active.
    private var screensaverActive = false

    /// Returns whether the system is considered ready for one mount pass.
    private var isReadyToMount: Bool {
        systemAwake && displayAwake && sessionActive && !screenLocked && !screensaverActive
    }

    /// Maximum number of seconds sleep may be deferred while disk operations run.
    private static let maximumSystemSleepDelaySeconds = 10

    /// Hard cap for delaying system sleep while waiting for disk-operation completion.
    private static let maximumSystemSleepDelay: Duration = .seconds(maximumSystemSleepDelaySeconds)

    /// Distributed notification posted when the screen lock is engaged.
    private static let screenLockedNotificationName = Notification.Name("com.apple.screenIsLocked")

    /// Distributed notification posted when the screen lock is released.
    private static let screenUnlockedNotificationName = Notification.Name("com.apple.screenIsUnlocked")

    /// Distributed notification posted when the screen saver starts.
    private static let screensaverDidStartNotificationName = Notification.Name("com.apple.screensaver.didstart")

    /// Distributed notification posted when the screen saver stops.
    private static let screensaverDidStopNotificationName = Notification.Name("com.apple.screensaver.didstop")

    /// Initializes disk and power event observers.
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
        registerRemountCandidateObservers()

        Log.powerEvents.log("Monitoring configured; trigger=\(Preference.unmountWhen.rawValue)")
    }

    /// Handles all currently enabled volumes using the configured automatic disk operation.
    @objc func unmountVolumes(notification: Notification) {
        Log.powerEvents.log("Disk operation trigger received; notification=\(notification.name.rawValue)")
        let enabledVolumes = Volume.mountedVolumes().filter(\.enabled)

        guard !Preference.ejectInsteadOfUnmount else {
            clearRemountStateForEjectMode()
            let representatives = Volume.uniqueWholeDiskRepresentatives(from: enabledVolumes)
            Log.volumeOperations.log("Automatic eject batch started: \(representatives.count) whole disk(s) for \(enabledVolumes.count) enabled volume(s)")

            for volume in representatives {
                requestEject(for: volume) { _ in }
            }
            return
        }

        mergeRemountCandidates(with: enabledVolumes, reason: "Unmount trigger received")

        for volume in enabledVolumes {
            requestUnmount(for: volume) { _ in }
        }
    }

    /// Cancels pending mounts and clears remount candidates because ejected disks cannot be remounted automatically.
    func clearRemountStateForEjectMode() {
        let candidateCount = remountCandidates.count
        cancelAllPendingMountTasks(reason: "Eject mode enabled")
        remountCandidates.removeAll()

        guard candidateCount > 0 else {
            return
        }

        Log.volumeOperations.log("Remount candidates cleared because eject mode is enabled: count=\(candidateCount)")
    }

    /// Registers only the selected unmount trigger while remounting remains readiness-based.
    private func registerUnmountTriggerObserver() {
        switch Preference.unmountWhen {
        case .systemStartsSleeping:
            if !startSystemSleepPowerMonitoring() {
                Log.powerEvents.warning("IOKit power monitoring unavailable; fallback=NSWorkspace.willSleepNotification")
                NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unmountVolumes(notification:)), name: NSWorkspace.willSleepNotification, object: nil)
            }
        case .screensStartedSleeping:
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unmountVolumes(notification:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        case .screenIsLocked:
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(unmountVolumes(notification:)), name: Self.screenLockedNotificationName, object: nil)
        case .screensaverStarted:
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(unmountVolumes(notification:)), name: Self.screensaverDidStartNotificationName, object: nil)
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
            Self.screenUnlockedNotificationName,
            Self.screensaverDidStartNotificationName,
            Self.screensaverDidStopNotificationName
        ]
        for name in distributedReadinessNotifications {
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(handleMountReadinessNotification(_:)), name: name, object: nil)
        }
    }

    /// Registers notifications that reconcile remount candidates when volumes reappear outside the app's own mount flow.
    private func registerRemountCandidateObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleManagedVolumeDidMount(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
    }

    /// Applies state updates and triggers one mount pass when readiness transitions to true.
    private func updateMountReadinessState(
        systemAwake: Bool? = nil,
        displayAwake: Bool? = nil,
        sessionActive: Bool? = nil,
        screenLocked: Bool? = nil,
        screensaverActive: Bool? = nil
    ) {
        let wasReadyToMount = isReadyToMount

        if let systemAwake {
            Log.powerEvents.info("System wake state changed; isAwake=\(systemAwake)")
            self.systemAwake = systemAwake
        }

        if let displayAwake {
            Log.powerEvents.info("Display wake state changed; isAwake=\(displayAwake)")
            self.displayAwake = displayAwake
        }

        if let sessionActive {
            Log.powerEvents.info("Session activity changed; isActive=\(sessionActive)")
            self.sessionActive = sessionActive
        }

        if let screenLocked {
            Log.powerEvents.info("Screen lock state changed; isLocked=\(screenLocked)")
            self.screenLocked = screenLocked
        }

        if let screensaverActive {
            Log.powerEvents.info("Screensaver state changed; isActive=\(screensaverActive)")
            self.screensaverActive = screensaverActive
        }

        let isNowReadyToMount = self.isReadyToMount

        guard wasReadyToMount != isNowReadyToMount else {
            return
        }

        if isNowReadyToMount {
            Log.powerEvents.info("Mount readiness changed; isReady=true")
            triggerMountPass()
        } else {
            Log.powerEvents.info("Mount readiness changed; isReady=false")
            cancelAllPendingMountTasks(reason: "Mount readiness left ready state")
        }
    }

    /// Triggers one fire-and-forget mount pass for all remount candidates.
    private func triggerMountPass() {
        guard !Preference.ejectInsteadOfUnmount else {
            clearRemountStateForEjectMode()
            Log.volumeOperations.info("Mount pass skipped because eject mode is enabled")
            return
        }

        guard !self.remountCandidates.isEmpty else {
            Log.volumeOperations.info("Mount pass skipped: no remount candidates")
            return
        }

        Log.volumeOperations.log("Mount pass triggered: \(self.remountCandidates.count) candidate(s)")
        for volume in self.remountCandidates {
            scheduleMountTask(for: volume)
        }
    }

    /// Merges new automatic unmounts into the pending remount set while preserving older pending entries.
    private func mergeRemountCandidates(with volumes: [Volume], reason: String) {
        let existingCount = remountCandidates.count

        guard !volumes.isEmpty else {
            if existingCount > 0 {
                Log.volumeOperations.info("Preserving \(existingCount) pending remount candidate(s): \(reason)")
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
            Log.volumeOperations.info(
                "Merged remount candidates: preserved \(existingCount), refreshed \(refreshedCount), added \(addedCount), total \(self.remountCandidates.count): \(reason)"
            )
        }
    }

    /// Returns whether the pending remount set still includes a volume ID.
    private func hasRemountCandidate(withID volumeID: String) -> Bool {
        remountCandidates.contains { $0.id == volumeID }
    }

    /// Removes a volume from the pending remount set.
    private func removeRemountCandidate(withID volumeID: String) {
        remountCandidates.removeAll { $0.id == volumeID }
    }

    /// Applies the shared candidate-retention policy after an automatic remount workflow event.
    @discardableResult
    private func applyRemountCandidateDisposition(
        after event: VolumeOperationOutcomePolicy.AutomaticRemountCandidateEvent,
        volumeID: String
    ) -> VolumeOperationOutcomePolicy.AutomaticRemountCandidateDisposition {
        let disposition = VolumeOperationOutcomePolicy.automaticRemountCandidateDisposition(after: event)
        if disposition == .remove {
            removeRemountCandidate(withID: volumeID)
        }

        return disposition
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
        case Self.screensaverDidStartNotificationName:
            updateMountReadinessState(screensaverActive: true)
        case Self.screensaverDidStopNotificationName:
            updateMountReadinessState(screensaverActive: false)
        default:
            return
        }
    }

    /// Clears any pending automatic remount state when macOS reports the volume has already mounted.
    @objc private func handleManagedVolumeDidMount(_ notification: Notification) {
        guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              let volume = Volume.fromURL(url: volumeURL),
              hasRemountCandidate(withID: volume.id) else {
            return
        }

        cancelPendingMountTask(for: volume.id)
        removeRemountCandidate(withID: volume.id)
        Log.volumeOperations.info("Remount candidate cleared after external mount notification for \(volume.logLabel)")
    }

    /// Cancels and removes any pending mount task for a volume.
    private func cancelPendingMountTask(for volumeID: String) {
        pendingMountTasks[volumeID]?.cancel()
        pendingMountTasks.removeValue(forKey: volumeID)
    }

    /// Cancels all currently pending mount or retry tasks.
    private func cancelAllPendingMountTasks(reason: String) {
        guard !pendingMountTasks.isEmpty else {
            return
        }

        Log.volumeOperations.info("Cancelling \(self.pendingMountTasks.count) pending mount task(s): \(reason)")
        for task in pendingMountTasks.values {
            task.cancel()
        }
        pendingMountTasks.removeAll()
    }

    /// Schedules an immediate automatic remount sequence for a volume when one is not already pending.
    private func scheduleMountTask(for volume: Volume) {
        let volumeID = volume.id
        guard pendingMountTasks[volumeID] == nil else {
            return
        }

        Log.volumeOperations.log("Automatic remount sequence scheduled for \(volume.logLabel)")

        pendingMountTasks[volumeID] = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.pendingMountTasks.removeValue(forKey: volumeID)
            }

            var attemptIndex = 0
            var hasWaitedForNativeUnlock = false

            while !Task.isCancelled {
                guard !Preference.ejectInsteadOfUnmount else {
                    self.clearRemountStateForEjectMode()
                    return
                }

                guard self.isReadyToMount else {
                    return
                }

                guard self.hasRemountCandidate(withID: volumeID) else {
                    return
                }

                let attemptResult: VolumeOperationOutcomePolicy.AutomaticRemountAttemptResult

                if DiskArbitrationVolumeOperator.canResolveDisk(volumeUUID: volume.diskUUID, volumeName: volume.name, bsdName: volume.bsdName) {
                    let result: (success: Bool, message: String?, status: DAReturn?) = await withCheckedContinuation { continuation in
                        VolumeOperationRouter.shared.mount(volumeUUID: volume.diskUUID.map { $0 as NSUUID }, volumeName: volume.name, bsdName: volume.bsdName) { success, message, status in
                            continuation.resume(returning: (success, message, status))
                        }
                    }

                    guard !Task.isCancelled else {
                        return
                    }

                    if result.success {
                        attemptResult = .mountSucceeded
                    } else {
                        if let message = result.message, !message.isEmpty {
                            Log.volumeOperations.error("Mount failed for \(volume.logLabel): \(message)")
                        } else {
                            Log.volumeOperations.error("Mount failed for \(volume.logLabel)")
                        }

                        attemptResult = .mountFailed(status: result.status)
                    }
                } else {
                    let attemptNumber = attemptIndex + 1
                    Log.volumeOperations.warning("Disk unavailable during automatic remount attempt; attempt=\(attemptNumber); \(volume.logLabel)")
                    attemptResult = .diskUnavailable
                }

                if case .mountFailed = attemptResult,
                   VolumeOperationOutcomePolicy.shouldProbeEncryptedAPFSLockState(
                       isEncrypted: volume.isEncrypted,
                       isAPFS: volume.isAPFS,
                       ejectModeEnabled: Preference.ejectInsteadOfUnmount
                   ) {
                    let lockState = await self.encryptedVolumeLockStateProbe.lockState(
                        request: APFSVolumeLockStateProbe.Request(volume: volume)
                    )

                    guard !Task.isCancelled,
                          !Preference.ejectInsteadOfUnmount,
                          self.hasRemountCandidate(withID: volumeID) else {
                        return
                    }

                    var shouldUseEncryptedFallback = false

                    if VolumeOperationOutcomePolicy.shouldStartNativeUnlockGrace(
                        after: attemptResult,
                        isEncrypted: volume.isEncrypted,
                        isAPFS: volume.isAPFS,
                        ejectModeEnabled: Preference.ejectInsteadOfUnmount,
                        lockState: lockState,
                        hasAlreadyWaited: hasWaitedForNativeUnlock
                    ) {
                        hasWaitedForNativeUnlock = true
                        Log.volumeOperations.log("Native unlock grace started; delaySeconds=5; \(volume.logLabel)")

                        do {
                            try await Task.sleep(for: VolumeOperationOutcomePolicy.nativeUnlockGraceDelay)
                        } catch {
                            Log.volumeOperations.info("Native unlock grace cancelled; reason=task_cancelled; \(volume.logLabel)")
                            return
                        }

                        guard !Task.isCancelled else {
                            Log.volumeOperations.info("Native unlock grace cancelled; reason=task_cancelled; \(volume.logLabel)")
                            return
                        }

                        let postGraceState: VolumeOperationOutcomePolicy.NativeUnlockPostGraceState
                        if self.isVolumeMounted(withID: volumeID) {
                            postGraceState = .externallyMounted
                        } else if !DiskArbitrationVolumeOperator.canResolveDisk(
                            volumeUUID: volume.diskUUID,
                            volumeName: volume.name,
                            bsdName: volume.bsdName
                        ) {
                            postGraceState = .unavailable
                        } else {
                            let postGraceLockState = await self.encryptedVolumeLockStateProbe.lockState(
                                request: APFSVolumeLockStateProbe.Request(volume: volume)
                            )

                            switch postGraceLockState {
                            case .unlocked:
                                postGraceState = .unlocked
                            case .locked:
                                postGraceState = .locked
                            case .unknown:
                                postGraceState = .unknown
                            }
                        }

                        let graceContinuation = VolumeOperationOutcomePolicy.nativeUnlockGraceContinuation(
                            candidateExists: self.hasRemountCandidate(withID: volumeID),
                            isReadyToMount: self.isReadyToMount,
                            ejectModeEnabled: Preference.ejectInsteadOfUnmount,
                            state: postGraceState
                        )

                        switch graceContinuation {
                        case .completeAfterExternalMount:
                            Log.volumeOperations.log("Native unlock grace completed; state=externally_mounted; \(volume.logLabel)")
                            self.applyRemountCandidateDisposition(after: .remountSucceeded, volumeID: volumeID)
                            return
                        case .attemptNormalMount:
                            Log.volumeOperations.log("Native unlock grace completed; state=unlocked; action=resume_normal_mount; \(volume.logLabel)")
                            continue
                        case .useEncryptedFallback:
                            Log.volumeOperations.warning("Native unlock grace expired; state=locked; \(volume.logLabel)")
                            shouldUseEncryptedFallback = true
                        case .resumeNormalRetryPolicy:
                            let stateDescription = postGraceState == .unavailable ? "unavailable" : "unknown"
                            Log.volumeOperations.warning("Native unlock grace expired; state=\(stateDescription); action=resume_normal_retry_policy; \(volume.logLabel)")
                        case .deferUntilLater:
                            Log.volumeOperations.info("Native unlock grace cancelled; reason=stale_remount_state; \(volume.logLabel)")
                            return
                        }
                    } else if lockState == .locked, hasWaitedForNativeUnlock {
                        shouldUseEncryptedFallback = true
                    }

                    if shouldUseEncryptedFallback {
                        switch VolumeOperationOutcomePolicy.encryptedAPFSFallbackDecision(
                            unlockVolumesWhenNeeded: Preference.unlockVolumesWhenNeeded
                        ) {
                        case .useFallback:
                            break
                        case .endRecovery:
                            Log.volumeOperations.log("Encrypted APFS fallback skipped; reason=preference_disabled; \(volume.logLabel)")
                            self.applyRemountCandidateDisposition(after: .terminalRemountFailure, volumeID: volumeID)
                            return
                        }

                        switch await self.unlockEncryptedVolume(for: volume) {
                        case .succeeded:
                            self.applyRemountCandidateDisposition(after: .remountSucceeded, volumeID: volumeID)
                        case .mountNormally:
                            Log.volumeOperations.log("Normal mounting resumed after encrypted APFS state became unlocked; \(volume.logLabel)")
                            continue
                        case .failed:
                            self.applyRemountCandidateDisposition(after: .terminalRemountFailure, volumeID: volumeID)
                        case .deferred:
                            Log.volumeOperations.info("Encrypted APFS unlock deferred while preserving remount candidate for \(volume.logLabel)")
                        }
                        return
                    }
                }

                switch VolumeOperationOutcomePolicy.automaticRemountAttemptOutcome(for: attemptResult) {
                case .succeeded:
                    self.applyRemountCandidateDisposition(after: .remountSucceeded, volumeID: volumeID)
                    return
                case .terminalFailure:
                    Log.volumeOperations.info("Automatic remount stopped due to non-retryable status for \(volume.logLabel)")
                    self.applyRemountCandidateDisposition(after: .terminalRemountFailure, volumeID: volumeID)
                    return
                case .retryableFailure:
                    guard let retryDelay = VolumeOperationOutcomePolicy.automaticRemountRetryDelay(afterFailedAttemptAt: attemptIndex) else {
                        Log.volumeOperations.warning("Automatic remount retry limit reached for \(volume.logLabel)")
                        self.applyRemountCandidateDisposition(after: .retryExhausted, volumeID: volumeID)
                        return
                    }

                    let retryNumber = attemptIndex + 1
                    attemptIndex += 1
                    Log.volumeOperations.info("Scheduling automatic remount retry \(retryNumber)/\(VolumeOperationOutcomePolicy.automaticRemountRetryDelays.count) for \(volume.logLabel)")

                    do {
                        try await Task.sleep(for: retryDelay)
                    } catch {
                        self.applyRemountCandidateDisposition(after: .retryCancelled, volumeID: volumeID)
                        Log.volumeOperations.info("Automatic remount retry cancelled; preserving candidate for \(volume.logLabel)")
                        return
                    }
                }
            }
        }
    }

    /// Returns whether the current mounted-volume inventory includes a volume identifier.
    private func isVolumeMounted(withID volumeID: String) -> Bool {
        Volume.mountedVolumes().contains { $0.id == volumeID }
    }

    /// Attempts to unlock and mount an encrypted APFS volume using Keychain first, then a user prompt.
    private func unlockEncryptedVolume(for volume: Volume) async -> EncryptedVolumeUnlockOutcome {
        guard !Preference.ejectInsteadOfUnmount, !Task.isCancelled else {
            return .deferred
        }

        guard encryptedUnlocksInProgress.insert(volume.id).inserted else {
            Log.volumeOperations.info("Duplicate encrypted APFS unlock suppressed for \(volume.logLabel)")
            return .deferred
        }

        defer {
            encryptedUnlocksInProgress.remove(volume.id)
        }

        do {
            if let savedPassword = try encryptedVolumeCredentialStore.password(for: volume.id) {
                Log.volumeOperations.log("Encrypted APFS fallback selected; source=saved_credential; \(volume.logLabel)")

                switch await encryptedUnlockContinuation(for: volume) {
                case .attemptUnlock:
                    break
                case .attemptNormalMount:
                    return .mountNormally
                case .deferUntilLater:
                    return .deferred
                }

                let result = await encryptedVolumeUnlocker.unlock(
                    request: APFSEncryptedVolumeUnlocker.UnlockRequest(volume: volume),
                    password: savedPassword
                )

                switch result {
                case .success:
                    return .succeeded
                case .invalidPassword:
                    Log.volumeOperations.warning("Saved encrypted APFS password was rejected for \(volume.logLabel)")
                    deleteEncryptedVolumePassword(for: volume)
                    return await promptForEncryptedVolumePassword(for: volume)
                case .failed(let message):
                    showEncryptedVolumeUnlockFailure(for: volume, details: message)
                    return .failed
                }
            }
        } catch {
            Log.volumeOperations.error(error, message: "Encrypted APFS password could not be read from Keychain for \(volume.logLabel)")
            return await promptForEncryptedVolumePassword(for: volume)
        }

        return await promptForEncryptedVolumePassword(for: volume)
    }

    /// Prompts for an encrypted APFS password until unlock succeeds or the user ends the recovery cycle.
    private func promptForEncryptedVolumePassword(for volume: Volume) async -> EncryptedVolumeUnlockOutcome {
        Log.volumeOperations.log("Encrypted APFS fallback selected; source=prompt; \(volume.logLabel)")
        while !Preference.ejectInsteadOfUnmount {
            Log.volumeOperations.log("Encrypted APFS password prompt presented for \(volume.logLabel)")
            let outcome = encryptedVolumePasswordPrompt.requestPassword(for: volume)

            switch outcome {
            case .notNow:
                Log.volumeOperations.info("Encrypted APFS password prompt action selected; action=not_now; \(volume.logLabel)")
                return .failed
            case .unlock(let response):
                Log.volumeOperations.info("Encrypted APFS password prompt action selected; action=unlock; saveRequested=\(response.shouldSaveInKeychain); \(volume.logLabel)")

                switch await encryptedUnlockContinuation(for: volume) {
                case .attemptUnlock:
                    break
                case .attemptNormalMount:
                    Log.volumeOperations.info("Stale encrypted APFS prompt skipped because normal mounting can resume for \(volume.logLabel)")
                    return .mountNormally
                case .deferUntilLater:
                    Log.volumeOperations.info("Stale encrypted APFS prompt response ignored for \(volume.logLabel)")
                    return .deferred
                }

                let result = await encryptedVolumeUnlocker.unlock(
                    request: APFSEncryptedVolumeUnlocker.UnlockRequest(volume: volume),
                    password: response.password
                )

                switch result {
                case .success:
                    updateEncryptedVolumePassword(
                        response.password,
                        shouldSave: response.shouldSaveInKeychain,
                        volume: volume
                    )
                    return .succeeded
                case .invalidPassword:
                    Log.volumeOperations.warning("Entered encrypted APFS password was rejected for \(volume.logLabel)")
                case .failed(let message):
                    showEncryptedVolumeUnlockFailure(for: volume, details: message)
                    return .failed
                }
            }
        }

        return .deferred
    }

    /// Revalidates the candidate and live lock state before invoking encrypted APFS unlock handling.
    private func encryptedUnlockContinuation(
        for volume: Volume
    ) async -> VolumeOperationOutcomePolicy.EncryptedAPFSUnlockContinuation {
        guard !Preference.ejectInsteadOfUnmount,
              isReadyToMount,
              hasRemountCandidate(withID: volume.id) else {
            return .deferUntilLater
        }

        let lockState = await encryptedVolumeLockStateProbe.lockState(
            request: APFSVolumeLockStateProbe.Request(volume: volume)
        )

        return VolumeOperationOutcomePolicy.encryptedAPFSUnlockContinuation(
            candidateExists: hasRemountCandidate(withID: volume.id),
            isReadyToMount: isReadyToMount,
            ejectModeEnabled: Preference.ejectInsteadOfUnmount,
            lockState: lockState
        )
    }

    /// Saves or removes an encrypted volume password after a successful unlock.
    private func updateEncryptedVolumePassword(_ password: String, shouldSave: Bool, volume: Volume) {
        guard shouldSave else {
            deleteEncryptedVolumePassword(for: volume)
            return
        }

        do {
            try encryptedVolumeCredentialStore.savePassword(password, for: volume.id)
            Log.volumeOperations.log("Encrypted APFS password saved in Keychain for \(volume.logLabel)")
        } catch {
            Log.volumeOperations.error(error, message: "Encrypted APFS password could not be saved in Keychain for \(volume.logLabel)")
            showEncryptedVolumeKeychainSaveFailure(for: volume)
        }
    }

    /// Deletes an encrypted volume password while preserving failure diagnostics.
    private func deleteEncryptedVolumePassword(for volume: Volume) {
        do {
            try encryptedVolumeCredentialStore.deletePassword(for: volume.id)
        } catch {
            Log.volumeOperations.error(error, message: "Encrypted APFS password could not be deleted from Keychain for \(volume.logLabel)")
        }
    }

    /// Presents a terminal encrypted APFS unlock failure without persisting command output to diagnostics.
    private func showEncryptedVolumeUnlockFailure(for volume: Volume, details: String?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Could not unlock volume")
        let baseMessage = String(localized: "Could not unlock \"\(volume.name)\".")
        alert.informativeText = details.map { "\(baseMessage)\n\n\($0)" } ?? baseMessage
        alert.runModal()
    }

    /// Presents a warning when an unlocked volume password could not be saved.
    private func showEncryptedVolumeKeychainSaveFailure(for volume: Volume) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Could not save password")
        alert.informativeText = String(
            localized: "Ejectify unlocked \"\(volume.name)\", but could not save its password in Keychain."
        )
        alert.runModal()
    }

    /// Starts IOKit power monitoring used to delay sleep while handling volumes.
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

    /// Delays system sleep while handling volumes and automatically releases sleep after success or timeout.
    private func beginSystemSleepDelay(token: Int) {
        if let pendingToken = pendingSystemSleepToken {
            if pendingToken == token {
                Log.powerEvents.info("Duplicate system sleep token received; token=\(token)")
                return
            }

            Log.powerEvents.warning("Overlapping system sleep token ignored; token=\(token); pendingToken=\(pendingToken)")
            systemSleepPowerObserver?.allowPowerChange(for: token)
            return
        }

        pendingSystemSleepToken = token
        updateMountReadinessState(systemAwake: false)
        Log.powerEvents.log("System sleep delayed for disk operations; maximumDelaySeconds=\(Self.maximumSystemSleepDelaySeconds)")

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
            Log.powerEvents.warning("System sleep delay reached cap; maximumDelaySeconds=\(Self.maximumSystemSleepDelaySeconds)")
            allowSystemSleepIfNeeded(for: token, reason: "\(Self.maximumSystemSleepDelaySeconds)-second timeout reached")
        }

        pendingSystemSleepDiskOperationTask?.cancel()
        pendingSystemSleepDiskOperationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let batchResult = await handleEnabledVolumesAndWait()
            guard pendingSystemSleepToken == token else {
                Log.powerEvents.info("Stale system sleep disk operation completion ignored; token=\(token)")
                return
            }
            Log.powerEvents.log("System sleep disk operation batch finished; succeededCount=\(batchResult.succeededCount); requestedCount=\(batchResult.requestedCount)")
            allowSystemSleepIfNeeded(for: token, reason: "disk operation batch completed")
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
        Log.powerEvents.log("System sleep release requested; token=\(token); reason=\(reason)")
        systemSleepPowerObserver?.allowPowerChange(for: token)
    }

    /// Cancels and clears pending timeout and disk-operation tasks for an active system-sleep delay.
    private func cancelPendingSystemSleepTasks() {
        pendingSystemSleepTimeoutTask?.cancel()
        pendingSystemSleepTimeoutTask = nil
        pendingSystemSleepDiskOperationTask?.cancel()
        pendingSystemSleepDiskOperationTask = nil
    }

    /// Represents the completion summary for one disk-operation batch.
    private struct DiskOperationBatchResult {

        /// Number of disk operations included in the batch request.
        let requestedCount: Int

        /// Number of disk operations that reported success.
        let succeededCount: Int
    }

    /// Handles all enabled volumes using the configured operation and waits for every callback.
    private func handleEnabledVolumesAndWait() async -> DiskOperationBatchResult {
        let enabledVolumes = Volume.mountedVolumes().filter { $0.enabled }

        guard !Preference.ejectInsteadOfUnmount else {
            clearRemountStateForEjectMode()
            let representatives = Volume.uniqueWholeDiskRepresentatives(from: enabledVolumes)
            Log.volumeOperations.log("System sleep eject batch started: \(representatives.count) whole disk(s) for \(enabledVolumes.count) enabled volume(s)")

            return await performDiskOperationBatch(volumes: representatives) { volume, completion in
                self.requestEject(for: volume, completion: completion)
            }
        }

        mergeRemountCandidates(with: enabledVolumes, reason: "Starting new system sleep unmount batch")

        return await performDiskOperationBatch(volumes: enabledVolumes) { volume, completion in
            self.requestUnmount(for: volume, completion: completion)
        }
    }

    /// Performs one asynchronous disk operation per volume and summarizes callback results.
    private func performDiskOperationBatch(
        volumes: [Volume],
        operation: (Volume, @escaping (Bool) -> Void) -> Void
    ) async -> DiskOperationBatchResult {
        guard !volumes.isEmpty else {
            return DiskOperationBatchResult(requestedCount: 0, succeededCount: 0)
        }

        return await withCheckedContinuation { continuation in
            var pendingCallbacks = volumes.count
            var succeededCount = 0
            var didResume = false

            func completeIfNeeded() {
                guard !didResume, pendingCallbacks == 0 else {
                    return
                }
                didResume = true
                continuation.resume(returning: DiskOperationBatchResult(requestedCount: volumes.count, succeededCount: succeededCount))
            }

            for volume in volumes {
                operation(volume) { success in
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

    /// Enqueues a routed eject request for one whole disk and tracks in-flight state.
    private func requestEject(for volume: Volume, completion: @escaping (Bool) -> Void) {
        let wholeDiskBSDName = volume.wholeDiskBSDName
        pendingEjectCompletions[wholeDiskBSDName, default: []].append(completion)

        guard inFlightEjects.insert(wholeDiskBSDName).inserted else {
            Log.volumeOperations.info("Eject request joined existing in-flight operation: wholeDiskBSDName=\(wholeDiskBSDName)")
            return
        }

        Log.volumeOperations.log("Eject request scheduled: wholeDiskBSDName=\(wholeDiskBSDName); \(volume.logLabel)")
        VolumeOperationRouter.shared.eject(
            volumeUUID: volume.diskUUID.map { $0 as NSUUID },
            volumeName: volume.name,
            bsdName: volume.bsdName,
            forceUnmount: Preference.forceUnmount
        ) { [weak self] success, _, _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(success)
                    return
                }

                self.inFlightEjects.remove(wholeDiskBSDName)
                let completions = self.pendingEjectCompletions.removeValue(forKey: wholeDiskBSDName) ?? []
                completions.forEach { $0(success) }
            }
        }
    }

    /// Enqueues a routed unmount request for one volume and tracks in-flight state.
    private func requestUnmount(for volume: Volume, completion: @escaping (Bool) -> Void) {
        let volumeID = volume.id
        cancelPendingMountTask(for: volumeID)
        pendingUnmountCompletions[volumeID, default: []].append(completion)

        guard !inFlightUnmounts.contains(volumeID) else {
            Log.volumeOperations.info("Unmount request joined existing in-flight operation: \(volume.logLabel)")
            return
        }

        inFlightUnmounts.insert(volumeID)
        Log.volumeOperations.log("Unmount request scheduled for \(volume.logLabel)")
        VolumeOperationRouter.shared.unmount(volumeUUID: volume.diskUUID.map { $0 as NSUUID }, volumeName: volume.name, bsdName: volume.bsdName, force: Preference.forceUnmount) { [weak self] success, _, status in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(success)
                    return
                }

                self.inFlightUnmounts.remove(volumeID)
                self.applyRemountCandidateDisposition(
                    after: .unmountCompleted(success: success, status: status),
                    volumeID: volumeID
                )
                if !success {
                    let statusDescription = status?.statusDescription ?? "none"
                    Log.volumeOperations.info("Automatic unmount failed; preserving candidate for wake reconciliation; status=\(statusDescription); \(volume.logLabel)")
                }
                let completions = self.pendingUnmountCompletions.removeValue(forKey: volumeID) ?? []
                completions.forEach { $0(success) }
            }
        }
    }

}
