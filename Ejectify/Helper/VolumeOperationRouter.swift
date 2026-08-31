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

/// Routes diskutil operations through a compatible helper when enabled, switching later requests to local execution after XPC failure.
final class VolumeOperationRouter: @unchecked Sendable {

    /// Describes where diskutil is currently executed.
    enum ExecutionMode: String {
        case local
        case privilegedHelper
    }

    /// Semantic mutation result exposed without process details owned by another executable.
    struct MutationResult: Equatable, Sendable {
        let outcome: DiskutilOperator.Outcome

        /// Whether the requested semantic state was reached.
        var success: Bool {
            outcome == .succeeded
        }
    }

    /// Semantic APFS unlock result exposed without reconstructed process details.
    struct UnlockResult: Equatable, Sendable {
        let outcome: DiskutilOperator.UnlockOutcome
        let metadata: DiskutilOperator.APFSMetadata

        /// Whether diskutil reported a successful unlock.
        var success: Bool {
            outcome == .succeeded
        }
    }

    /// Resumes an async operation no more than once across competing XPC callbacks.
    private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?

        init(_ continuation: CheckedContinuation<Value, Never>) {
            self.continuation = continuation
        }

        func resume(returning value: Value) {
            let continuation = lock.withLock {
                let current = self.continuation
                self.continuation = nil
                return current
            }
            continuation?.resume(returning: value)
        }
    }

    /// Invokes a callback no more than once across competing XPC callbacks.
    private final class CallbackGate<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: ((Value) -> Void)?

        init(_ completion: @escaping (Value) -> Void) {
            self.completion = completion
        }

        func complete(with value: Value) {
            let completion = lock.withLock {
                let current = self.completion
                self.completion = nil
                return current
            }
            completion?(value)
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
    func mount(identityUUID: NSUUID?, bsdName: String, trigger: VolumeOperationTrigger) async -> MutationResult {
        await route(operation: .mount, identityUUID: identityUUID, bsdName: bsdName, trigger: trigger) { proxy, reply in
            proxy.mount(volumeUUID: identityUUID, volumeName: "", bsdName: bsdName, withReply: reply)
        }
    }

    /// Requests diskutil unmount.
    func unmount(identityUUID: NSUUID?, bsdName: String, force: Bool, trigger: VolumeOperationTrigger) async -> MutationResult {
        await route(operation: .unmount(force: force), identityUUID: identityUUID, bsdName: bsdName, trigger: trigger) { proxy, reply in
            proxy.unmount(volumeUUID: identityUUID, volumeName: "", bsdName: bsdName, force: force, withReply: reply)
        }
    }

    /// Requests diskutil eject using the selected volume as the target.
    func eject(identityUUID: NSUUID?, bsdName: String, force: Bool, trigger: VolumeOperationTrigger) async -> MutationResult {
        await route(operation: .eject(force: force), identityUUID: identityUUID, bsdName: bsdName, trigger: trigger) { proxy, reply in
            proxy.eject(volumeUUID: identityUUID, volumeName: "", bsdName: bsdName, forceUnmount: force, withReply: reply)
        }
    }

    /// Reads APFS lock state through the active diskutil execution location.
    func inspectAPFSLockState(identityUUID: NSUUID?, bsdName: String) async -> DiskutilOperator.LockState {
        let location = executionMode
        Self.logDispatch(operationName: "apfsLockState", force: false, location: location, trigger: .encryptedRecovery, identityUUID: identityUUID, bsdName: bsdName)
        guard location == .privilegedHelper else {
            return await performLocalLockState(identityUUID: identityUUID, bsdName: bsdName)
        }

        guard let connection = currentHelperConnection() else {
            switchToLocalAfterXPCFailure(reason: "APFS lock-state helper connection unavailable")
            Self.logXPCFailure(operationName: "apfsLockState", force: false, trigger: .encryptedRecovery, identityUUID: identityUUID, bsdName: bsdName)
            return .unknown
        }

        return await withCheckedContinuation { continuation in
            let gate = ContinuationGate(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                self?.switchToLocalAfterXPCFailure(reason: "APFS lock-state XPC failure")
                Self.logXPCFailure(operationName: "apfsLockState", force: false, trigger: .encryptedRecovery, identityUUID: identityUUID, bsdName: bsdName)
                gate.resume(returning: .unknown)
            }) as? PrivilegedDiskServiceProtocol else {
                switchToLocalAfterXPCFailure(reason: "APFS lock-state helper proxy unavailable")
                Self.logXPCFailure(operationName: "apfsLockState", force: false, trigger: .encryptedRecovery, identityUUID: identityUUID, bsdName: bsdName)
                gate.resume(returning: .unknown)
                return
            }
            proxy.inspectAPFSLockState(volumeUUID: identityUUID, bsdName: bsdName) { rawState in
                gate.resume(returning: DiskutilOperator.LockState(rawValue: rawState) ?? .unknown)
            }
        }
    }

    /// Unlocks APFS through the active diskutil execution location.
    func unlockAPFSVolume(identityUUID: NSUUID?, bsdName: String, password: String) async -> UnlockResult {
        let location = executionMode
        Self.logDispatch(operationName: "apfsUnlock", force: false, location: location, trigger: .encryptedRecovery, identityUUID: identityUUID, bsdName: bsdName)
        guard location == .privilegedHelper else {
            return await performLocalUnlock(identityUUID: identityUUID, bsdName: bsdName, password: password)
        }

        let emptyMetadata = DiskutilOperator.APFSMetadata(diskManagementErrorCode: nil, rateLimitBackoff: nil, rateLimitLockout: nil)
        guard let connection = currentHelperConnection() else {
            switchToLocalAfterXPCFailure(reason: "APFS unlock helper connection unavailable")
            Self.logXPCFailure(operationName: "apfsUnlock", force: false, trigger: .encryptedRecovery, identityUUID: identityUUID, bsdName: bsdName)
            return UnlockResult(outcome: .failed, metadata: emptyMetadata)
        }

        return await withCheckedContinuation { continuation in
            let gate = ContinuationGate(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                self?.switchToLocalAfterXPCFailure(reason: "APFS unlock XPC failure")
                Self.logXPCFailure(operationName: "apfsUnlock", force: false, trigger: .encryptedRecovery, identityUUID: identityUUID, bsdName: bsdName)
                gate.resume(returning: UnlockResult(outcome: .failed, metadata: emptyMetadata))
            }) as? PrivilegedDiskServiceProtocol else {
                switchToLocalAfterXPCFailure(reason: "APFS unlock helper proxy unavailable")
                Self.logXPCFailure(operationName: "apfsUnlock", force: false, trigger: .encryptedRecovery, identityUUID: identityUUID, bsdName: bsdName)
                gate.resume(returning: UnlockResult(outcome: .failed, metadata: emptyMetadata))
                return
            }
            proxy.unlockAPFSVolume(volumeUUID: identityUUID, bsdName: bsdName, password: password) { success, rawOutcome, _, _, errorCode, backoff, lockout in
                let outcome = DiskutilOperator.UnlockOutcome(rawValue: rawOutcome) ?? (success ? .succeeded : .failed)
                gate.resume(returning: UnlockResult(
                    outcome: outcome,
                    metadata: DiskutilOperator.APFSMetadata(
                        diskManagementErrorCode: errorCode?.intValue,
                        rateLimitBackoff: backoff?.boolValue,
                        rateLimitLockout: lockout?.boolValue
                    )
                ))
            }
        }
    }

    /// Updates the privileged Disk Arbitration notification preference.
    func setEjectNotificationsMuted(_ muted: Bool, completion: @escaping (Bool, String?) -> Void) {
        let gate = CallbackGate<(Bool, String?)> { result in
            completion(result.0, result.1)
        }
        guard executionMode == .privilegedHelper,
              let connection = currentHelperConnection(),
              let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                  self?.switchToLocalAfterXPCFailure(reason: "notification setting XPC failure")
                  DispatchQueue.main.async { gate.complete(with: (false, error.localizedDescription)) }
              }) as? PrivilegedDiskServiceProtocol else {
            gate.complete(with: (false, "Privileged helper is unavailable"))
            return
        }
        proxy.setEjectNotificationsMuted(muted: muted) { success, message in
            gate.complete(with: (success, message))
        }
    }

    /// Sends a best-effort helper shutdown request.
    func requestHelperTermination() {
        guard let connection = currentHelperConnection() else {
            return
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? PrivilegedDiskServiceProtocol
        proxy?.requestTermination { _, _ in }
    }

    /// Routes one mutation without retrying the same request after an XPC failure.
    private func route(
        operation: DiskutilOperator.Operation,
        identityUUID: NSUUID?,
        bsdName: String,
        trigger: VolumeOperationTrigger,
        helperRequest: @escaping (PrivilegedDiskServiceProtocol, @escaping (Bool, String?, Int32) -> Void) -> Void
    ) async -> MutationResult {
        let location = executionMode
        Self.logDispatch(operation: operation, location: location, trigger: trigger, identityUUID: identityUUID, bsdName: bsdName)
        guard location == .privilegedHelper else {
            return await performLocal(operation: operation, identityUUID: identityUUID, bsdName: bsdName, trigger: trigger)
        }

        guard let connection = currentHelperConnection() else {
            switchToLocalAfterXPCFailure(reason: "diskutil helper connection unavailable")
            Self.logXPCFailure(operation: operation, trigger: trigger, identityUUID: identityUUID, bsdName: bsdName)
            return MutationResult(outcome: .failed)
        }

        return await withCheckedContinuation { continuation in
            let gate = ContinuationGate(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                self?.switchToLocalAfterXPCFailure(reason: "diskutil operation XPC failure")
                Self.logXPCFailure(operation: operation, trigger: trigger, identityUUID: identityUUID, bsdName: bsdName)
                gate.resume(returning: MutationResult(outcome: .failed))
            }) as? PrivilegedDiskServiceProtocol else {
                switchToLocalAfterXPCFailure(reason: "diskutil helper proxy unavailable")
                Self.logXPCFailure(operation: operation, trigger: trigger, identityUUID: identityUUID, bsdName: bsdName)
                gate.resume(returning: MutationResult(outcome: .failed))
                return
            }
            helperRequest(proxy) { success, message, _ in
                let outcome = message.flatMap(DiskutilOperator.Outcome.init(rawValue:)) ?? (success ? .succeeded : .failed)
                gate.resume(returning: MutationResult(outcome: outcome))
            }
        }
    }

    /// Executes one local diskutil mutation.
    private func performLocal(
        operation: DiskutilOperator.Operation,
        identityUUID: NSUUID?,
        bsdName: String,
        trigger: VolumeOperationTrigger
    ) async -> MutationResult {
        let uuid = identityUUID.map { $0 as UUID }
        return await withCheckedContinuation { continuation in
            localOperationQueue.async {
                let result = DiskutilOperator.perform(identityUUID: uuid, bsdName: bsdName, operation: operation)
                Self.logResult(result, operation: operation, location: .local, trigger: trigger, identityUUID: identityUUID, bsdName: bsdName)
                continuation.resume(returning: MutationResult(outcome: result.outcome))
            }
        }
    }

    /// Executes one local APFS lock-state query.
    private func performLocalLockState(identityUUID: NSUUID?, bsdName: String) async -> DiskutilOperator.LockState {
        let uuid = identityUUID.map { $0 as UUID }
        return await withCheckedContinuation { continuation in
            localOperationQueue.async {
                let state = DiskutilOperator.lockState(identityUUID: uuid, bsdName: bsdName)
                Log.volumeOperations.log("APFS lock-state query completed; executionLocation=local; state=\(state.rawValue); \(VolumeLogLabelFormatter.label(uuid: uuid, bsdName: bsdName))")
                continuation.resume(returning: state)
            }
        }
    }

    /// Executes one local APFS unlock.
    private func performLocalUnlock(identityUUID: NSUUID?, bsdName: String, password: String) async -> UnlockResult {
        let uuid = identityUUID.map { $0 as UUID }
        return await withCheckedContinuation { continuation in
            localOperationQueue.async {
                let result = DiskutilOperator.unlock(identityUUID: uuid, bsdName: bsdName, password: password)
                Self.logUnlockResult(result, location: .local, identityUUID: identityUUID, bsdName: bsdName)
                continuation.resume(returning: UnlockResult(outcome: result.outcome, metadata: result.metadata))
            }
        }
    }

    /// Opens a helper connection and confirms the diskutil capability.
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

    /// Switches future requests to local execution after an XPC failure.
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
        logDispatch(operationName: operation.operationName, force: operation.isForced, location: location, trigger: trigger, identityUUID: identityUUID, bsdName: bsdName)
    }

    /// Logs one diskutil dispatch without volume names or paths.
    private static func logDispatch(
        operationName: String,
        force: Bool,
        location: ExecutionMode,
        trigger: VolumeOperationTrigger,
        identityUUID: NSUUID?,
        bsdName: String
    ) {
        Log.volumeOperations.log("Volume operation dispatched; trigger=\(trigger.rawValue); operation=\(operationName); executionLocation=\(location.rawValue); identityUUID=\(identityUUID?.uuidString ?? "none"); bsdName=\(bsdName); force=\(force)")
    }

    /// Logs one final semantic mutation result owned by the local process.
    private static func logResult(
        _ result: DiskutilOperator.OperationResult,
        operation: DiskutilOperator.Operation,
        location: ExecutionMode,
        trigger: VolumeOperationTrigger,
        identityUUID: NSUUID?,
        bsdName: String
    ) {
        let details = "trigger=\(trigger.rawValue); operation=\(operation.operationName); executionLocation=\(location.rawValue); identityUUID=\(identityUUID?.uuidString ?? "none"); bsdName=\(bsdName); force=\(operation.isForced); outcome=\(result.outcome.rawValue); exitCode=\(result.exitCode.map(String.init) ?? "none"); terminationReason=\(result.terminationReason.rawValue); durationMilliseconds=\(result.durationMilliseconds); timeout=\(result.timedOut)"
        if result.success {
            Log.volumeOperations.log("Volume operation completed; \(details)")
        } else {
            Log.volumeOperations.error("Volume operation failed; \(details)")
        }
    }

    /// Logs one local APFS unlock result using only structured metadata.
    private static func logUnlockResult(
        _ result: DiskutilOperator.UnlockResult,
        location: ExecutionMode,
        identityUUID: NSUUID?,
        bsdName: String
    ) {
        let metadata = result.metadata
        let label = VolumeLogLabelFormatter.label(uuid: identityUUID.map { $0 as UUID }, bsdName: bsdName)
        let details = "operation=apfsUnlock; executionLocation=\(location.rawValue); outcome=\(result.outcome.rawValue); exitCode=\(result.exitCode.map(String.init) ?? "none"); terminationReason=\(result.terminationReason.rawValue); durationMilliseconds=\(result.durationMilliseconds); timeout=\(result.timedOut); diskManagementErrorCode=\(metadata.diskManagementErrorCode.map(String.init) ?? "none"); rateLimitBackoff=\(metadata.rateLimitBackoff.map(String.init) ?? "none"); rateLimitLockout=\(metadata.rateLimitLockout.map(String.init) ?? "none"); \(label)"
        if result.success {
            Log.volumeOperations.log("APFS unlock completed; \(details)")
        } else {
            Log.volumeOperations.error("APFS unlock failed; \(details)")
        }
    }

    /// Logs a routed operation whose authoritative helper result became unavailable.
    private static func logXPCFailure(
        operation: DiskutilOperator.Operation,
        trigger: VolumeOperationTrigger,
        identityUUID: NSUUID?,
        bsdName: String
    ) {
        logXPCFailure(operationName: operation.operationName, force: operation.isForced, trigger: trigger, identityUUID: identityUUID, bsdName: bsdName)
    }

    /// Logs a routed operation whose authoritative helper result became unavailable.
    private static func logXPCFailure(
        operationName: String,
        force: Bool,
        trigger: VolumeOperationTrigger,
        identityUUID: NSUUID?,
        bsdName: String
    ) {
        Log.volumeOperations.error("Volume operation failed; trigger=\(trigger.rawValue); operation=\(operationName); executionLocation=privilegedHelper; identityUUID=\(identityUUID?.uuidString ?? "none"); bsdName=\(bsdName); force=\(force); outcome=failed; reason=xpc_failure")
    }
}
