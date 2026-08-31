//
//  ActivityController.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 24/11/2020.
//

import AppKit

/// Responds to sleep, lock, and display events by unmounting or ejecting enabled volumes.
@MainActor
final class ActivityController {


    /// Volumes targeted by automatic unmounting that remain pending for wake-time remounting.
    private var remountCandidates: [String: Volume] = [:]

    /// Pending mount tasks keyed by volume identifier.
    private var pendingMountTasks: [String: Task<Void, Never>] = [:]

    /// Volume identifiers currently owned by an encrypted APFS unlock workflow.
    private var encryptedUnlocksInProgress: Set<String> = []

    /// Pending completion handlers for each in-flight mutation.
    private var pendingOperationCompletions: [OperationKey: [(Bool) -> Void]] = [:]

    /// Store used for encrypted APFS volume unlock passwords.
    private let encryptedVolumeCredentialStore = EncryptedVolumeCredentialStore.shared

    /// Prompt used to ask for encrypted volume passwords when needed.
    private let encryptedVolumePasswordPrompt = EncryptedVolumePasswordPrompt()

    /// Mutation types tracked for request joining.
    private enum RequestedVolumeOperation: Hashable {
        case unmount
        case eject

        var operationName: String {
            switch self {
            case .unmount: "unmount"
            case .eject: "eject"
            }
        }
    }

    /// Stable key for joining duplicate in-flight requests without mixing mutation types.
    private struct OperationKey: Hashable {
        let volumeID: String
        let operation: RequestedVolumeOperation
    }

    /// Describes the final effect of encrypted APFS unlock handling on its remount candidate.
    private enum EncryptedVolumeUnlockOutcome {
        case succeeded
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

    /// Number of volume operations still running after a system-sleep request.
    private var pendingSystemSleepOperationCount = 0

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

    /// Handles all currently enabled volumes using the configured automatic operation.
    @objc func unmountVolumes(notification: Notification) {
        Log.powerEvents.log("Disk operation trigger received; notification=\(notification.name.rawValue)")

        let trigger = operationTrigger(for: notification)
        let enabledVolumes = Volume.mountedVolumes().filter(\.enabled)

        guard !Preference.ejectInsteadOfUnmount else {
            clearRemountStateForEjectMode()
            Log.volumeOperations.log("Automatic eject batch started: \(enabledVolumes.count) enabled volume(s)")

            for volume in enabledVolumes {
                requestEject(for: volume, trigger: trigger) { _ in }
            }
            return
        }

        mergeRemountCandidates(with: enabledVolumes, reason: "Unmount trigger received")

        for volume in enabledVolumes {
            requestUnmount(for: volume, trigger: trigger) { _ in }
        }
    }

    /// Maps workspace and distributed notifications to stable diagnostic trigger values.
    private func operationTrigger(for notification: Notification) -> VolumeOperationTrigger {
        if notification.name == NSWorkspace.screensDidSleepNotification {
            return .display
        }
        if notification.name == NSWorkspace.willSleepNotification {
            return .systemSleep
        }
        return .session
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

    /// Registers notifications that clear remount candidates when volumes reappear outside the app's own mount flow.
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
        for volume in self.remountCandidates.values {
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

        var addedCount = 0
        var refreshedCount = 0

        for volume in volumes {
            if remountCandidates.updateValue(volume, forKey: volume.id) != nil {
                refreshedCount += 1
            } else {
                addedCount += 1
            }
        }

        if existingCount > 0 {
            Log.volumeOperations.info(
                "Merged remount candidates: preserved \(existingCount), refreshed \(refreshedCount), added \(addedCount), total \(self.remountCandidates.count): \(reason)"
            )
        }
    }

    /// Returns whether the pending remount set still includes a volume ID.
    private func hasRemountCandidate(withID volumeID: String) -> Bool {
        remountCandidates[volumeID] != nil
    }

    /// Removes a volume from the pending remount set.
    private func removeRemountCandidate(withID volumeID: String) {
        remountCandidates.removeValue(forKey: volumeID)
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

                let result = await VolumeOperationRouter.shared.mount(
                    identityUUID: volume.identityUUID.map { $0 as NSUUID },
                    bsdName: volume.bsdName,
                    trigger: .automaticRemount
                )

                guard !Task.isCancelled else {
                    return
                }

                let attemptResult: VolumeOperationOutcomePolicy.AutomaticRemountAttemptResult = result.success
                    ? .mountSucceeded
                    : .mountFailed(outcome: result.outcome)
                let attemptOutcome = VolumeOperationOutcomePolicy.automaticRemountAttemptOutcome(for: attemptResult)

                switch attemptOutcome {
                case .succeeded:
                    self.removeRemountCandidate(withID: volumeID)
                    return
                case .terminalFailure:
                    Log.volumeOperations.info("Automatic remount stopped due to non-retryable status for \(volume.logLabel)")
                    self.removeRemountCandidate(withID: volumeID)
                    return
                case .retryableFailure:
                    if VolumeOperationOutcomePolicy.shouldProbeEncryptedAPFSLockState(
                           isEncrypted: volume.isEncrypted,
                           isAPFS: volume.isAPFS,
                           ejectModeEnabled: Preference.ejectInsteadOfUnmount
                       ) {
                        let lockState = await VolumeOperationRouter.shared.inspectAPFSLockState(
                            identityUUID: volume.identityUUID.map { $0 as NSUUID },
                            bsdName: volume.bsdName
                        )

                        guard !Task.isCancelled,
                              !Preference.ejectInsteadOfUnmount,
                              self.isReadyToMount,
                              self.hasRemountCandidate(withID: volumeID) else {
                            return
                        }

                        if lockState == .locked {
                            switch VolumeOperationOutcomePolicy.encryptedAPFSFallbackDecision(
                                unlockVolumesWhenNeeded: Preference.unlockVolumesWhenNeeded
                            ) {
                            case .useFallback:
                                break
                            case .endRecovery:
                                Log.volumeOperations.log("Encrypted APFS fallback skipped; reason=preference_disabled; \(volume.logLabel)")
                                self.removeRemountCandidate(withID: volumeID)
                                return
                            }

                            switch await self.unlockEncryptedVolume(for: volume) {
                            case .succeeded:
                                self.removeRemountCandidate(withID: volumeID)
                            case .failed:
                                self.removeRemountCandidate(withID: volumeID)
                            case .deferred:
                                Log.volumeOperations.info("Encrypted APFS unlock deferred while preserving remount candidate for \(volume.logLabel)")
                            }
                            return
                        }

                        Log.volumeOperations.info("Encrypted APFS lock-state check completed; state=\(lockState.rawValue); action=resume_normal_retry_policy; \(volume.logLabel)")
                    }

                    guard let retryDelay = VolumeOperationOutcomePolicy.automaticRemountRetryDelay(afterFailedAttemptAt: attemptIndex) else {
                        Log.volumeOperations.warning("Automatic remount retry limit reached for \(volume.logLabel)")
                        self.removeRemountCandidate(withID: volumeID)
                        return
                    }

                    let retryNumber = attemptIndex + 1
                    attemptIndex += 1
                    Log.volumeOperations.info("Scheduling automatic remount retry \(retryNumber)/\(VolumeOperationOutcomePolicy.automaticRemountRetryDelays.count) for \(volume.logLabel)")

                    do {
                        try await Task.sleep(for: retryDelay)
                    } catch {
                        Log.volumeOperations.info("Automatic remount retry cancelled; preserving candidate for \(volume.logLabel)")
                        return
                    }
                }
            }
        }
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

                guard canContinueEncryptedUnlock(for: volume) else {
                    return .deferred
                }

                let result = await VolumeOperationRouter.shared.unlockAPFSVolume(
                    identityUUID: volume.identityUUID.map { $0 as NSUUID },
                    bsdName: volume.bsdName,
                    password: savedPassword
                )

                switch result.outcome {
                case .succeeded:
                    return .succeeded
                case .invalidPassword:
                    Log.volumeOperations.warning("Saved encrypted APFS password was rejected for \(volume.logLabel)")
                    deleteEncryptedVolumePassword(for: volume)
                    return await promptForEncryptedVolumePassword(for: volume)
                case .failed, .timedOut, .launchFailed, .targetUnavailable, .targetAmbiguous, .invalidTarget:
                    showEncryptedVolumeUnlockFailure(for: volume, details: result.outcome.rawValue)
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
        while canContinueEncryptedUnlock(for: volume) {
            Log.volumeOperations.log("Encrypted APFS password prompt presented for \(volume.logLabel)")
            let outcome = encryptedVolumePasswordPrompt.requestPassword(for: volume)

            switch outcome {
            case .notNow:
                Log.volumeOperations.info("Encrypted APFS password prompt action selected; action=not_now; \(volume.logLabel)")
                return .failed
            case .unlock(let response):
                Log.volumeOperations.info("Encrypted APFS password prompt action selected; action=unlock; saveRequested=\(response.shouldSaveInKeychain); \(volume.logLabel)")

                guard canContinueEncryptedUnlock(for: volume) else {
                    Log.volumeOperations.info("Stale encrypted APFS prompt response ignored for \(volume.logLabel)")
                    return .deferred
                }

                let result = await VolumeOperationRouter.shared.unlockAPFSVolume(
                    identityUUID: volume.identityUUID.map { $0 as NSUUID },
                    bsdName: volume.bsdName,
                    password: response.password
                )

                switch result.outcome {
                case .succeeded:
                    updateEncryptedVolumePassword(
                        response.password,
                        shouldSave: response.shouldSaveInKeychain,
                        volume: volume
                    )
                    return .succeeded
                case .invalidPassword:
                    Log.volumeOperations.warning("Entered encrypted APFS password was rejected for \(volume.logLabel)")
                case .failed, .timedOut, .launchFailed, .targetUnavailable, .targetAmbiguous, .invalidTarget:
                    showEncryptedVolumeUnlockFailure(for: volume, details: result.outcome.rawValue)
                    return .failed
                }
            }
        }

        return .deferred
    }

    /// Returns whether a delayed credential action still belongs to the active remount workflow.
    private func canContinueEncryptedUnlock(for volume: Volume) -> Bool {
        !Task.isCancelled
            && !Preference.ejectInsteadOfUnmount
            && isReadyToMount
            && hasRemountCandidate(withID: volume.id)
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
            Log.powerEvents.warning("System sleep delay reached cap; maximumDelaySeconds=\(Self.maximumSystemSleepDelaySeconds); pendingCount=\(pendingSystemSleepOperationCount)")
            allowSystemSleepIfNeeded(for: token, reason: "\(Self.maximumSystemSleepDelaySeconds)-second timeout reached")
        }

        pendingSystemSleepDiskOperationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let batchResult = await handleEnabledStorageAndWait()
            pendingSystemSleepOperationCount = 0
            pendingSystemSleepDiskOperationTask = nil
            guard pendingSystemSleepToken == token else {
                Log.powerEvents.log("System sleep disk operation batch finished after power token release; succeededCount=\(batchResult.succeededCount); requestedCount=\(batchResult.requestedCount)")
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
        pendingSystemSleepTimeoutTask?.cancel()
        pendingSystemSleepTimeoutTask = nil
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
    private func handleEnabledStorageAndWait() async -> DiskOperationBatchResult {
        let enabledVolumes = Volume.mountedVolumes().filter(\.enabled)
        pendingSystemSleepOperationCount = enabledVolumes.count

        guard !Preference.ejectInsteadOfUnmount else {
            clearRemountStateForEjectMode()
            Log.volumeOperations.log("System sleep eject batch started: \(enabledVolumes.count) enabled volume(s)")

            return await performDiskOperationBatch(items: enabledVolumes) { volume, completion in
                self.requestEject(for: volume, trigger: .systemSleep, completion: completion)
            }
        }

        mergeRemountCandidates(with: enabledVolumes, reason: "Starting new system sleep unmount batch")

        return await performDiskOperationBatch(items: enabledVolumes) { volume, completion in
            self.requestUnmount(for: volume, trigger: .systemSleep, completion: completion)
        }
    }

    /// Performs one asynchronous disk operation per supplied model and summarizes callback results.
    private func performDiskOperationBatch<Item>(
        items: [Item],
        operation: (Item, @escaping (Bool) -> Void) -> Void
    ) async -> DiskOperationBatchResult {
        guard !items.isEmpty else {
            return DiskOperationBatchResult(requestedCount: 0, succeededCount: 0)
        }

        return await withCheckedContinuation { continuation in
            var pendingCallbacks = items.count
            var succeededCount = 0
            var didResume = false

            func completeIfNeeded() {
                guard !didResume, pendingCallbacks == 0 else {
                    return
                }
                didResume = true
                continuation.resume(returning: DiskOperationBatchResult(requestedCount: items.count, succeededCount: succeededCount))
            }

            for item in items {
                operation(item) { success in
                    self.pendingSystemSleepOperationCount = max(0, self.pendingSystemSleepOperationCount - 1)
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

    /// Enqueues a routed eject request for one selected volume and tracks in-flight state.
    private func requestEject(for volume: Volume, trigger: VolumeOperationTrigger, completion: @escaping (Bool) -> Void) {
        requestOperation(.eject, for: volume, trigger: trigger, completion: completion)
    }

    /// Enqueues a routed unmount request for one volume and tracks in-flight state.
    private func requestUnmount(for volume: Volume, trigger: VolumeOperationTrigger, completion: @escaping (Bool) -> Void) {
        cancelPendingMountTask(for: volume.id)
        requestOperation(.unmount, for: volume, trigger: trigger, completion: completion)
    }

    /// Starts or joins one routed mutation keyed by volume and operation type.
    private func requestOperation(
        _ operation: RequestedVolumeOperation,
        for volume: Volume,
        trigger: VolumeOperationTrigger,
        completion: @escaping (Bool) -> Void
    ) {
        let key = OperationKey(volumeID: volume.id, operation: operation)
        if pendingOperationCompletions[key] != nil {
            pendingOperationCompletions[key, default: []].append(completion)
            Log.volumeOperations.info("\(operation.operationName.capitalized) request joined existing in-flight operation: \(volume.logLabel)")
            return
        }
        pendingOperationCompletions[key] = [completion]

        Task { @MainActor [weak self] in
            let result: VolumeOperationRouter.MutationResult
            switch operation {
            case .unmount:
                result = await VolumeOperationRouter.shared.unmount(
                    identityUUID: volume.identityUUID.map { $0 as NSUUID },
                    bsdName: volume.bsdName,
                    force: Preference.forceUnmount,
                    trigger: trigger
                )
            case .eject:
                result = await VolumeOperationRouter.shared.eject(
                    identityUUID: volume.identityUUID.map { $0 as NSUUID },
                    bsdName: volume.bsdName,
                    force: Preference.forceUnmount,
                    trigger: trigger
                )
            }

            guard let self else {
                completion(result.success)
                return
            }

            let completions = self.pendingOperationCompletions.removeValue(forKey: key) ?? []
            completions.forEach { $0(result.success) }
        }
    }

}
