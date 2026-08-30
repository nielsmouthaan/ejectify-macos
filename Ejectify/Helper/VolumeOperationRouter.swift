//
//  VolumeOperationRouter.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation

/// Notification posted whenever volume-operation routing state changes.
extension Notification.Name {
    static let volumeOperationRouterDidChange = Notification.Name(PrivilegedHelperConfiguration.operationRouterDidChangeNotificationName)
}

/// Identifies the workflow that dispatched a volume operation.
enum VolumeOperationTrigger: String, Sendable {
    case manual
    case hotkey
    case display
    case session
    case systemSleep
    case automaticRemount
    case encryptedRecovery
}

/// Routes all diskutil operations through a compatible helper when enabled, with explicit local fallback on XPC failure.
final class VolumeOperationRouter: @unchecked Sendable {

    /// Describes where diskutil is currently executed.
    enum ExecutionMode: String {
        case local
        case privilegedHelper
    }

    /// Wraps result callbacks for use from sendable queues.
    private final class OperationCompletionBox: @unchecked Sendable {
        let completion: (DiskutilOperator.OperationResult) -> Void

        init(_ completion: @escaping (DiskutilOperator.OperationResult) -> Void) {
            self.completion = completion
        }
    }

    /// Wraps lock-state callbacks for use from sendable queues.
    private final class LockCompletionBox: @unchecked Sendable {
        let completion: (DiskutilOperator.LockState) -> Void

        init(_ completion: @escaping (DiskutilOperator.LockState) -> Void) {
            self.completion = completion
        }
    }

    /// Wraps unlock callbacks for use from sendable queues.
    private final class UnlockCompletionBox: @unchecked Sendable {
        let completion: (DiskutilOperator.UnlockResult) -> Void

        init(_ completion: @escaping (DiskutilOperator.UnlockResult) -> Void) {
            self.completion = completion
        }
    }

    /// Wraps preference-setting callbacks for use from XPC sendable closures.
    private final class SettingCompletionBox: @unchecked Sendable {
        let completion: (Bool, String?) -> Void

        init(_ completion: @escaping (Bool, String?) -> Void) {
            self.completion = completion
        }
    }

    /// Executes an action no more than once across competing XPC callbacks.
    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func run(_ action: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else {
                return
            }
            completed = true
            action()
        }
    }

    static let shared = VolumeOperationRouter()

    /// Darwin notification posted after helper daemon startup.
    private static let helperStartedNotification = CFNotificationName(PrivilegedHelperConfiguration.helperStartedNotificationName as CFString)

    /// Receives helper startup Darwin notifications.
    private static let helperStartedNotificationCallback: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else {
            return
        }
        let router = Unmanaged<VolumeOperationRouter>.fromOpaque(observer).takeUnretainedValue()
        DispatchQueue.main.async {
            _ = router.configureExecutionMode()
        }
    }

    /// Queue used by direct local diskutil operations.
    private let localOperationQueue = DispatchQueue(
        label: "nl.nielsmouthaan.Ejectify.LocalDiskutil",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let stateLock = NSLock()
    private var executionModeStorage: ExecutionMode = .local
    private var helperConnection: NSXPCConnection?
    private var helperInitializationInProgress = false

    private init() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            Self.helperStartedNotificationCallback,
            Self.helperStartedNotification.rawValue,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), nil, nil)
    }

    var isDaemonEnabled: Bool {
        PrivilegedHelperLifecycleManager.shared.isDaemonEnabled
    }

    var executionMode: ExecutionMode {
        withStateLock { executionModeStorage }
    }

    var isUsingPrivilegedHelper: Bool {
        executionMode == .privilegedHelper
    }

    /// Configures helper execution after verifying the helper's diskutil capability.
    @discardableResult
    func configureExecutionMode() -> Bool {
        let status = PrivilegedHelperLifecycleManager.shared.daemonStatus
        guard status == .enabled else {
            invalidateHelperConnection()
            setExecutionMode(.local, reason: "daemon status is \(status.statusDescription)")
            return false
        }
        initializeHelperRouting()
        return true
    }

    /// Registers the helper after explicit user authorization, then negotiates capabilities.
    @discardableResult
    func requestPrivilegedExecutionMode() -> Bool {
        PrivilegedHelperLifecycleManager.shared.resetDaemonRefreshAttempt()
        if isDaemonEnabled {
            return configureExecutionMode()
        }
        guard PrivilegedHelperLifecycleManager.shared.registerDaemon() else {
            setExecutionMode(.local, reason: "daemon registration did not complete")
            return false
        }
        initializeHelperRouting()
        return true
    }

    /// Disables privileged execution.
    @discardableResult
    func disablePrivilegedExecutionMode() -> Bool {
        let disabled = PrivilegedHelperLifecycleManager.shared.unregisterDaemon()
        invalidateHelperConnection()
        setExecutionMode(.local, reason: "daemon unregistered by user action")
        return disabled
    }

    /// Requests diskutil mount.
    func mount(
        identityUUID: NSUUID?,
        bsdName: String,
        logLabel: String,
        trigger: VolumeOperationTrigger,
        completion: @escaping (DiskutilOperator.OperationResult) -> Void
    ) {
        route(
            operation: .mount,
            identityUUID: identityUUID,
            bsdName: bsdName,
            logLabel: logLabel,
            trigger: trigger,
            completion: completion
        ) { proxy, reply in
            proxy.mount(volumeUUID: identityUUID, volumeName: "", bsdName: bsdName, withReply: reply)
        }
    }

    /// Requests diskutil unmount.
    func unmount(
        identityUUID: NSUUID?,
        bsdName: String,
        logLabel: String,
        force: Bool,
        trigger: VolumeOperationTrigger,
        completion: @escaping (DiskutilOperator.OperationResult) -> Void
    ) {
        route(
            operation: .unmount(force: force),
            identityUUID: identityUUID,
            bsdName: bsdName,
            logLabel: logLabel,
            trigger: trigger,
            completion: completion
        ) { proxy, reply in
            proxy.unmount(volumeUUID: identityUUID, volumeName: "", bsdName: bsdName, force: force, withReply: reply)
        }
    }

    /// Requests diskutil eject using the selected volume as the target.
    func eject(
        identityUUID: NSUUID?,
        bsdName: String,
        logLabel: String,
        force: Bool,
        trigger: VolumeOperationTrigger,
        completion: @escaping (DiskutilOperator.OperationResult) -> Void
    ) {
        route(
            operation: .eject(force: force),
            identityUUID: identityUUID,
            bsdName: bsdName,
            logLabel: logLabel,
            trigger: trigger,
            completion: completion
        ) { proxy, reply in
            proxy.eject(volumeUUID: identityUUID, volumeName: "", bsdName: bsdName, forceUnmount: force, withReply: reply)
        }
    }

    /// Reads APFS lock state through the active diskutil execution location.
    func inspectAPFSLockState(
        identityUUID: NSUUID?,
        bsdName: String,
        logLabel: String,
        completion: @escaping (DiskutilOperator.LockState) -> Void
    ) {
        let completionBox = LockCompletionBox(completion)
        if executionMode == .privilegedHelper,
           let connection = currentHelperConnection(),
           let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
               guard let self else { return }
               self.switchToLocalAfterXPCFailure(reason: "APFS lock-state XPC failure")
               self.performLocalLockState(identityUUID: identityUUID, bsdName: bsdName, logLabel: logLabel, completion: completionBox.completion)
           }) as? PrivilegedDiskServiceProtocol {
            proxy.inspectAPFSLockState(volumeUUID: identityUUID, bsdName: bsdName) { rawState in
                DispatchQueue.main.async {
                    completionBox.completion(DiskutilOperator.LockState(rawValue: rawState) ?? .unknown)
                }
            }
            return
        }
        performLocalLockState(identityUUID: identityUUID, bsdName: bsdName, logLabel: logLabel, completion: completion)
    }

    /// Unlocks APFS through the active diskutil execution location.
    func unlockAPFSVolume(
        identityUUID: NSUUID?,
        bsdName: String,
        logLabel: String,
        password: String,
        completion: @escaping (DiskutilOperator.UnlockResult) -> Void
    ) {
        let completionBox = UnlockCompletionBox(completion)
        if executionMode == .privilegedHelper,
           let connection = currentHelperConnection(),
           let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
               guard let self else { return }
               self.switchToLocalAfterXPCFailure(reason: "APFS unlock XPC failure")
               self.performLocalUnlock(identityUUID: identityUUID, bsdName: bsdName, logLabel: logLabel, password: password, completion: completionBox.completion)
           }) as? PrivilegedDiskServiceProtocol {
            let startedAt = ContinuousClock.now
            proxy.unlockAPFSVolume(volumeUUID: identityUUID, bsdName: bsdName, password: password) { success, rawOutcome, exitCode, duration, errorCode, backoff, lockout in
                let outcome = DiskutilOperator.UnlockOutcome(rawValue: rawOutcome) ?? (success ? .succeeded : .failed)
                let result = DiskutilOperator.UnlockResult(
                    outcome: outcome,
                    exitCode: exitCode == Int32.min ? nil : exitCode,
                    terminationReason: Self.unlockTerminationReason(outcome: outcome, exitCode: exitCode),
                    durationMilliseconds: duration > 0 ? duration : Self.elapsedMilliseconds(since: startedAt),
                    timedOut: outcome == .timedOut,
                    resolvedBSDName: bsdName,
                    metadata: DiskutilOperator.APFSMetadata(
                        diskManagementErrorCode: errorCode?.intValue,
                        rateLimitBackoff: backoff?.boolValue,
                        rateLimitLockout: lockout?.boolValue
                    )
                )
                DispatchQueue.main.async {
                    Self.logUnlockResult(result, location: .privilegedHelper, logLabel: logLabel)
                    completionBox.completion(result)
                }
            }
            return
        }
        performLocalUnlock(identityUUID: identityUUID, bsdName: bsdName, logLabel: logLabel, password: password, completion: completion)
    }

    /// Updates the privileged Disk Arbitration notification preference.
    func setEjectNotificationsMuted(_ muted: Bool, completion: @escaping (Bool, String?) -> Void) {
        let completionBox = SettingCompletionBox(completion)
        guard executionMode == .privilegedHelper,
              let connection = currentHelperConnection(),
              let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                  self?.switchToLocalAfterXPCFailure(reason: "notification setting XPC failure")
                  DispatchQueue.main.async { completionBox.completion(false, error.localizedDescription) }
              }) as? PrivilegedDiskServiceProtocol else {
            completion(false, "Privileged helper is unavailable")
            return
        }
        proxy.setEjectNotificationsMuted(muted: muted, withReply: completionBox.completion)
    }

    /// Sends a best-effort helper shutdown request.
    func requestHelperTermination() {
        guard let connection = currentHelperConnection() else {
            return
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? PrivilegedDiskServiceProtocol
        proxy?.requestTermination { _, _ in }
    }

    /// Routes a mutation and performs local fallback only after changing router mode.
    private func route(
        operation: DiskutilOperator.Operation,
        identityUUID: NSUUID?,
        bsdName: String,
        logLabel: String,
        trigger: VolumeOperationTrigger,
        completion: @escaping (DiskutilOperator.OperationResult) -> Void,
        helperRequest: (PrivilegedDiskServiceProtocol, @escaping (Bool, String?, Int32) -> Void) -> Void
    ) {
        let completionBox = OperationCompletionBox(completion)
        if executionMode == .privilegedHelper, let connection = currentHelperConnection() {
            let gate = CompletionGate()
            let startedAt = ContinuousClock.now
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                gate.run {
                    guard let self else { return }
                    self.switchToLocalAfterXPCFailure(reason: "diskutil operation XPC failure")
                    self.performLocal(operation: operation, identityUUID: identityUUID, bsdName: bsdName, logLabel: logLabel, trigger: trigger, completion: completionBox.completion)
                }
            }) as? PrivilegedDiskServiceProtocol else {
                switchToLocalAfterXPCFailure(reason: "diskutil helper proxy unavailable")
                performLocal(operation: operation, identityUUID: identityUUID, bsdName: bsdName, logLabel: logLabel, trigger: trigger, completion: completionBox.completion)
                return
            }

            Self.logDispatch(operation: operation, location: .privilegedHelper, trigger: trigger, identityUUID: identityUUID, bsdName: bsdName)
            helperRequest(proxy) { success, message, exitCode in
                gate.run {
                    let outcome = message.flatMap(DiskutilOperator.Outcome.init(rawValue:)) ?? (success ? .succeeded : .failed)
                    let result = DiskutilOperator.OperationResult(
                        outcome: outcome,
                        exitCode: exitCode == Int32.min ? nil : exitCode,
                        terminationReason: Self.operationTerminationReason(outcome: outcome, exitCode: exitCode),
                        durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                        timedOut: outcome == .timedOut,
                        reconciledState: .unknown,
                        resolvedBSDName: bsdName
                    )
                    DispatchQueue.main.async {
                        Self.logResult(result, operation: operation, location: .privilegedHelper, trigger: trigger, identityUUID: identityUUID, bsdName: bsdName)
                        completionBox.completion(result)
                    }
                }
            }
            return
        }

        performLocal(operation: operation, identityUUID: identityUUID, bsdName: bsdName, logLabel: logLabel, trigger: trigger, completion: completion)
    }

    /// Executes one local diskutil mutation.
    private func performLocal(
        operation: DiskutilOperator.Operation,
        identityUUID: NSUUID?,
        bsdName: String,
        logLabel _: String,
        trigger: VolumeOperationTrigger,
        completion: @escaping (DiskutilOperator.OperationResult) -> Void
    ) {
        let completionBox = OperationCompletionBox(completion)
        let uuid = identityUUID.map { $0 as UUID }
        Self.logDispatch(operation: operation, location: .local, trigger: trigger, identityUUID: identityUUID, bsdName: bsdName)
        localOperationQueue.async {
            let result = DiskutilOperator.perform(identityUUID: uuid, bsdName: bsdName, operation: operation)
            DispatchQueue.main.async {
                Self.logResult(result, operation: operation, location: .local, trigger: trigger, identityUUID: identityUUID, bsdName: bsdName)
                completionBox.completion(result)
            }
        }
    }

    /// Executes one local APFS lock-state query.
    private func performLocalLockState(
        identityUUID: NSUUID?,
        bsdName: String,
        logLabel: String,
        completion: @escaping (DiskutilOperator.LockState) -> Void
    ) {
        let completionBox = LockCompletionBox(completion)
        let uuid = identityUUID.map { $0 as UUID }
        localOperationQueue.async {
            let state = DiskutilOperator.lockState(identityUUID: uuid, bsdName: bsdName)
            DispatchQueue.main.async {
                Log.volumeOperations.log("APFS lock-state query completed; executionLocation=local; state=\(state.rawValue); \(logLabel)")
                completionBox.completion(state)
            }
        }
    }

    /// Executes one local APFS unlock.
    private func performLocalUnlock(
        identityUUID: NSUUID?,
        bsdName: String,
        logLabel: String,
        password: String,
        completion: @escaping (DiskutilOperator.UnlockResult) -> Void
    ) {
        let completionBox = UnlockCompletionBox(completion)
        let uuid = identityUUID.map { $0 as UUID }
        localOperationQueue.async {
            let result = DiskutilOperator.unlock(identityUUID: uuid, bsdName: bsdName, password: password)
            DispatchQueue.main.async {
                Self.logUnlockResult(result, location: .local, logLabel: logLabel)
                completionBox.completion(result)
            }
        }
    }

    /// Opens a helper connection, pings it, and confirms the diskutil capability.
    private func initializeHelperRouting() {
        let shouldStart = withStateLock { () -> Bool in
            guard !helperInitializationInProgress else { return false }
            helperInitializationInProgress = true
            return true
        }
        guard shouldStart else {
            return
        }

        invalidateHelperConnection()
        setExecutionMode(.local, reason: "verifying privileged helper diskutil capability")
        let connection = makeAndStoreHelperConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self, weak connection] _ in
            guard let self else { return }
            self.finishHelperInitialization()
            self.refreshIncompatibleHelper(connection: connection)
        }) as? PrivilegedDiskServiceProtocol else {
            finishHelperInitialization()
            setExecutionMode(.local, reason: "privileged helper proxy unavailable")
            return
        }

        proxy.ping { [weak self, weak connection] success, _ in
            guard let self, success else {
                self?.finishHelperInitialization()
                self?.invalidateHelperConnection(matching: connection)
                self?.setExecutionMode(.local, reason: "privileged helper ping failed")
                return
            }
            proxy.capabilityVersion { [weak self, weak connection] version in
                guard let self else { return }
                self.finishHelperInitialization()
                guard Self.supportsHelperCapability(version) else {
                    self.refreshIncompatibleHelper(connection: connection)
                    return
                }
                self.setExecutionMode(.privilegedHelper, reason: "diskutil helper capability confirmed")
                Log.privilegedHelper.log("Privileged helper will execute all diskutil operations; capabilityVersion=\(version)")
            }
        }
    }

    /// Re-registers one incompatible helper from the current app bundle, then negotiates its capability once more.
    private func refreshIncompatibleHelper(connection: NSXPCConnection?) {
        Log.privilegedHelper.warning("Privileged helper is incompatible; requesting ServiceManagement refresh")
        invalidateHelperConnection(matching: connection)
        setExecutionMode(.local, reason: "refreshing incompatible privileged helper")
        PrivilegedHelperLifecycleManager.shared.refreshDaemon { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .enabled:
                    Log.privilegedHelper.log("Privileged helper refresh succeeded; negotiating replacement capability")
                    self.initializeHelperRouting()
                case .requiresApproval:
                    self.setExecutionMode(.local, reason: "refreshed privileged helper requires approval")
                case .failed:
                    self.setExecutionMode(.local, reason: "privileged helper refresh failed")
                case .alreadyAttempted:
                    self.setExecutionMode(.local, reason: "replacement privileged helper remains incompatible")
                }
            }
        }
    }

    /// Returns whether a helper capability supports the current diskutil identity contract.
    static func supportsHelperCapability(_ version: Int) -> Bool {
        version >= PrivilegedHelperConfiguration.diskutilCapabilityVersion
    }

    /// Creates and stores one privileged XPC connection.
    private func makeAndStoreHelperConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: PrivilegedHelperConfiguration.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedDiskServiceProtocol.self)
        connection.interruptionHandler = { [weak self, weak connection] in
            self?.finishHelperInitialization()
            self?.invalidateHelperConnection(matching: connection)
            self?.setExecutionMode(.local, reason: "privileged helper connection interrupted")
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            self?.finishHelperInitialization()
            self?.invalidateHelperConnection(matching: connection)
            self?.setExecutionMode(.local, reason: "privileged helper connection invalidated")
        }
        connection.resume()
        withStateLock { helperConnection = connection }
        return connection
    }

    /// Switches mode before starting a local retry.
    private func switchToLocalAfterXPCFailure(reason: String) {
        invalidateHelperConnection()
        setExecutionMode(.local, reason: reason)
    }

    /// Returns the current helper connection.
    private func currentHelperConnection() -> NSXPCConnection? {
        withStateLock { helperConnection }
    }

    /// Invalidates the active helper connection when it matches an optional candidate.
    private func invalidateHelperConnection(matching candidate: NSXPCConnection? = nil) {
        let connection = withStateLock { () -> NSXPCConnection? in
            guard let current = helperConnection else { return nil }
            if let candidate, candidate !== current { return nil }
            helperConnection = nil
            return current
        }
        connection?.interruptionHandler = nil
        connection?.invalidationHandler = nil
        connection?.invalidate()
    }

    /// Updates execution mode and refreshes UI when it changes.
    private func setExecutionMode(_ mode: ExecutionMode, reason: String) {
        let previous = withStateLock { () -> ExecutionMode in
            let previous = executionModeStorage
            executionModeStorage = mode
            return previous
        }
        if previous != mode {
            Log.privilegedHelper.log("Execution mode changed; from=\(previous.rawValue); to=\(mode.rawValue); reason=\(reason)")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .volumeOperationRouterDidChange, object: self)
            }
        }
    }

    /// Marks helper capability negotiation as complete.
    private func finishHelperInitialization() {
        withStateLock { helperInitializationInProgress = false }
    }

    /// Runs an action while holding the router state lock.
    private func withStateLock<T>(_ action: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return action()
    }

    /// Logs one mutation dispatch without volume names or paths.
    private static func logDispatch(
        operation: DiskutilOperator.Operation,
        location: ExecutionMode,
        trigger: VolumeOperationTrigger,
        identityUUID: NSUUID?,
        bsdName: String
    ) {
        Log.volumeOperations.log("Volume operation dispatched; trigger=\(trigger.rawValue); operation=\(operation.operationName); executionLocation=\(location.rawValue); identityUUID=\(identityUUID?.uuidString ?? "none"); bsdName=\(bsdName); force=\(operation.isForced)")
    }

    /// Logs one final semantic mutation result.
    private static func logResult(
        _ result: DiskutilOperator.OperationResult,
        operation: DiskutilOperator.Operation,
        location: ExecutionMode,
        trigger: VolumeOperationTrigger,
        identityUUID: NSUUID?,
        bsdName: String
    ) {
        let details = "trigger=\(trigger.rawValue); operation=\(operation.operationName); executionLocation=\(location.rawValue); identityUUID=\(identityUUID?.uuidString ?? "none"); bsdName=\(bsdName); force=\(operation.isForced); outcome=\(result.outcome.rawValue); exitCode=\(result.exitCode.map(String.init) ?? "none"); terminationReason=\(result.terminationReason.rawValue); durationMilliseconds=\(result.durationMilliseconds); timeout=\(result.timedOut); reconciledState=\(result.reconciledState.rawValue)"
        if result.success {
            Log.volumeOperations.log("Volume operation completed; \(details)")
        } else {
            Log.volumeOperations.error("Volume operation failed; \(details)")
        }
    }

    /// Logs one APFS unlock result using only structured metadata.
    private static func logUnlockResult(_ result: DiskutilOperator.UnlockResult, location: ExecutionMode, logLabel: String) {
        let metadata = result.metadata
        let details = "operation=apfsUnlock; executionLocation=\(location.rawValue); outcome=\(result.outcome.rawValue); exitCode=\(result.exitCode.map(String.init) ?? "none"); terminationReason=\(result.terminationReason.rawValue); durationMilliseconds=\(result.durationMilliseconds); timeout=\(result.timedOut); diskManagementErrorCode=\(metadata.diskManagementErrorCode.map(String.init) ?? "none"); rateLimitBackoff=\(metadata.rateLimitBackoff.map(String.init) ?? "none"); rateLimitLockout=\(metadata.rateLimitLockout.map(String.init) ?? "none"); \(logLabel)"
        if result.success {
            Log.volumeOperations.log("APFS unlock completed; \(details)")
        } else {
            Log.volumeOperations.error("APFS unlock failed; \(details)")
        }
    }

    /// Maps an XPC outcome to the best available termination category.
    private static func operationTerminationReason(outcome: DiskutilOperator.Outcome, exitCode: Int32) -> DiskutilOperator.TerminationReason {
        switch outcome {
        case .timedOut: return .timeout
        case .launchFailed: return .launchFailure
        case .targetUnavailable: return .targetUnavailable
        case .targetAmbiguous: return .targetAmbiguous
        case .invalidTarget: return .invalidTarget
        case .succeeded, .satisfiedAfterReconciliation, .failed:
            return exitCode == Int32.min ? .launchFailure : .exit
        }
    }

    /// Maps an unlock XPC outcome to the best available termination category.
    private static func unlockTerminationReason(outcome: DiskutilOperator.UnlockOutcome, exitCode: Int32) -> DiskutilOperator.TerminationReason {
        switch outcome {
        case .timedOut: return .timeout
        case .launchFailed: return .launchFailure
        case .targetUnavailable: return .targetUnavailable
        case .targetAmbiguous: return .targetAmbiguous
        case .invalidTarget: return .invalidTarget
        case .succeeded, .invalidPassword, .failed:
            return exitCode == Int32.min ? .launchFailure : .exit
        }
    }

    /// Converts monotonic elapsed time to milliseconds.
    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now)
        return Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
