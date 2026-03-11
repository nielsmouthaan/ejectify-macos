//
//  VolumeOperationRouter.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation
import OSLog
@preconcurrency import DiskArbitration

/// Notification posted whenever `VolumeOperationRouter` state has changed and UI should refresh.
extension Notification.Name {

    static let volumeOperationRouterDidChange = Notification.Name(PrivilegedHelperConfiguration.operationRouterDidChangeNotificationName)
}

/// Routes volume operations to the priviledged helper when available, with local fallback.
final class VolumeOperationRouter: @unchecked Sendable {

    /// Describes where mount/unmount requests are currently executed.
    enum ExecutionMode: String {
        case local
        case priviledgedHelper
    }

    /// Wraps completion closures with optional operation details so they can cross Dispatch sendable boundaries safely.
    private final class OperationCompletionBox: @unchecked Sendable {

        /// Completion closure invoked with operation success state, optional message and optional status.
        let completion: (Bool, String?, DAReturn?) -> Void

        /// Stores a completion closure for deferred execution on main queue.
        init(completion: @escaping (Bool, String?, DAReturn?) -> Void) {
            self.completion = completion
        }
    }

    /// Wraps completion closures with error details so they can cross Dispatch sendable boundaries safely.
    private final class ToggleSettingCompletionBox: @unchecked Sendable {

        /// Completion closure invoked with success state and optional error details.
        let completion: (Bool, String?) -> Void

        /// Stores a completion closure for deferred execution on main queue.
        init(completion: @escaping (Bool, String?) -> Void) {
            self.completion = completion
        }
    }

    /// Stores completion actions so they can cross Dispatch sendable boundaries safely.
    private final class ActionBox: @unchecked Sendable {

        /// Arbitrary action to execute once a completion gate permits it.
        let action: () -> Void

        /// Stores an action closure for dispatch-safe forwarding.
        init(action: @escaping () -> Void) {
            self.action = action
        }
    }

    /// Ensures a completion path is only executed once across concurrent callbacks.
    private final class CompletionGate: @unchecked Sendable {

        /// Lock protecting completion state transitions.
        private let lock = NSLock()

        /// Tracks whether completion has already run.
        private var didComplete = false

        /// Executes `action` exactly once across all callers.
        func runOnce(_ action: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !didComplete else {
                return
            }
            didComplete = true
            action()
        }
    }

    /// Shared router instance used throughout the app.
    static let shared = VolumeOperationRouter()

    /// Darwin notification posted by the privileged helper after daemon startup completes.
    private static let helperStartedNotification = CFNotificationName(PrivilegedHelperConfiguration.helperStartedNotificationName as CFString)

    /// C callback invoked for helper startup Darwin notifications.
    private static let helperStartedNotificationCallback: CFNotificationCallback = { _, observer, name, _, _ in
        guard let observer else {
            return
        }

        guard let name, name.rawValue as String == PrivilegedHelperConfiguration.helperStartedNotificationName else {
            return
        }

        let router = Unmanaged<VolumeOperationRouter>.fromOpaque(observer).takeUnretainedValue()
        DispatchQueue.main.async {
            router.handleHelperStartedNotification()
        }
    }

    /// Logger used for routing mode and operation outcomes.
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "VolumeOperationRouter")

    /// Queue used for local mount/unmount operations.
    private let localOperationQueue = DispatchQueue(
        label: "nl.nielsmouthaan.Ejectify.LocalDiskOperation",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Lock guarding mutable router state.
    private let stateLock = NSLock()

    /// Backing storage for the current execution mode.
    private var executionModeStorage: ExecutionMode = .local

    /// Cached XPC connection to the privileged helper when available.
    private var helperConnection: NSXPCConnection?

    /// Tracks whether startup helper routing initialization is currently running.
    private var isStartupRoutingInitializationInProgress = false

    /// Registers helper startup observers and initializes router state.
    private init() {
        registerForHelperStartedNotification()
    }

    /// Removes helper startup observers if the router is deallocated.
    deinit {
        unregisterForHelperStartedNotification()
    }

    /// Returns whether the privileged helper daemon is currently registered and approved to run.
    var isDaemonEnabled: Bool {
        PrivilegedHelperLifecycleManager.shared.isDaemonEnabled
    }

    /// Returns the active execution mode for mount and unmount routing.
    var executionMode: ExecutionMode {
        withStateLock { executionModeStorage }
    }

    /// Returns whether startup helper routing initialization is currently running.
    private var isStartupRoutingInitializationActive: Bool {
        withStateLock { isStartupRoutingInitializationInProgress }
    }

    /// Returns whether there is an active helper XPC connection.
    private var hasHelperConnection: Bool {
        withStateLock { helperConnection != nil }
    }

    /// Appends a message suffix in the format `": <message>"` when a non-empty message is available.
    private nonisolated static func messageSuffix(for message: String?) -> String {
        guard let message, !message.isEmpty else {
            return ""
        }
        return ": \(message)"
    }

    /// Logs a mount/unmount outcome with a consistent format used by priviledged helper and local execution paths.
    private nonisolated static func logOperationResult(
        logger: Logger,
        source: String,
        operation: DiskArbitrationVolumeOperator.Operation,
        volumeName: String,
        volumeUUID: UUID,
        bsdName: String,
        success: Bool,
        message: String?
    ) {
        let suffix = messageSuffix(for: message)
        let volumeLabel = VolumeLogLabelFormatter.label(name: volumeName, uuid: volumeUUID, bsdName: bsdName)
        if success {
            logger.info("\(source, privacy: .public) \(operation.operationName, privacy: .public) succeeded for \(volumeLabel, privacy: .public)\(suffix, privacy: .public)")
        } else {
            logger.error("\(source, privacy: .public) \(operation.operationName, privacy: .public) failed for \(volumeLabel, privacy: .public)\(suffix, privacy: .public)")
        }
    }

    /// Logs when an operation is dispatched, before completion is known.
    private nonisolated static func logOperationDispatch(
        logger: Logger,
        source: String,
        operation: DiskArbitrationVolumeOperator.Operation,
        volumeName: String,
        volumeUUID: UUID,
        bsdName: String
    ) {
        let volumeLabel = VolumeLogLabelFormatter.label(name: volumeName, uuid: volumeUUID, bsdName: bsdName)
        logger.info("\(source, privacy: .public) \(operation.operationName, privacy: .public) dispatched for \(volumeLabel, privacy: .public)")
    }

    /// Runs a closure while holding the shared router state lock.
    private func withStateLock<T>(_ action: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return action()
    }

    /// Posts a notification consumed by menu/UI components that mirror router state.
    private func notifyStateDidChange() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .volumeOperationRouterDidChange, object: self)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .volumeOperationRouterDidChange, object: self)
            }
        }
    }

    /// Starts startup helper routing initialization only if not already in progress.
    private func beginStartupRoutingInitialization() -> Bool {
        withStateLock {
            guard !isStartupRoutingInitializationInProgress else {
                return false
            }
            isStartupRoutingInitializationInProgress = true
            return true
        }
    }

    /// Marks startup helper routing initialization as completed.
    private func endStartupRoutingInitialization() {
        withStateLock {
            isStartupRoutingInitializationInProgress = false
        }
    }

    /// Registers a Darwin notification observer for helper-started signals.
    private func registerForHelperStartedNotification() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            Self.helperStartedNotificationCallback,
            Self.helperStartedNotification.rawValue,
            nil,
            .deliverImmediately
        )
    }

    /// Unregisters the helper-started Darwin observer.
    private func unregisterForHelperStartedNotification() {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil
        )
    }

    /// Re-evaluates helper availability after receiving a helper-started signal.
    @MainActor
    private func handleHelperStartedNotification() {
        logger.info("Received privileged helper startup signal; reconciling routing state")

        guard !isStartupRoutingInitializationActive else {
            logger.info("Skipping helper startup reconciliation because startup helper ping is already in progress")
            return
        }

        if executionMode == .priviledgedHelper, hasHelperConnection {
            logger.info("Skipping helper startup reconciliation because privileged helper routing is already active")
            return
        }

        let didSucceed = configureExecutionMode()
        if !didSucceed {
            logger.warning("Privileged helper startup signal received, but helper reconciliation still failed")
        }
    }

    /// Updates execution mode and logs the transition reason.
    private func setExecutionMode(_ mode: ExecutionMode, reason: String) {
        let previousMode = withStateLock {
            let previous = executionModeStorage
            executionModeStorage = mode
            return previous
        }

        if previousMode == mode {
            logger.info("Execution mode remains \(mode.rawValue, privacy: .public): \(reason, privacy: .public)")
        } else {
            logger.info("Execution mode changed from \(previousMode.rawValue, privacy: .public) to \(mode.rawValue, privacy: .public): \(reason, privacy: .public)")
            notifyStateDidChange()
        }
    }

    /// Removes and invalidates the cached helper connection.
    private func invalidateHelperConnection(matching candidate: NSXPCConnection? = nil) {
        let connection = withStateLock { () -> NSXPCConnection? in
            guard let currentConnection = helperConnection else {
                return nil
            }
            if let candidate, currentConnection !== candidate {
                return nil
            }
            helperConnection = nil
            return currentConnection
        }

        guard let connection else {
            return
        }

        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
    }

    /// Creates and stores a helper connection used for startup ping and future helper operations.
    private func makeAndStoreHelperConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: PrivilegedHelperConfiguration.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedDiskServiceProtocol.self)
        connection.interruptionHandler = { [weak self, weak connection] in
            guard let self else {
                return
            }
            self.logger.warning("Priviledged helper XPC connection interrupted; switching to local mode")
            self.invalidateHelperConnection(matching: connection)
            self.setExecutionMode(.local, reason: "priviledged helper connection interrupted")
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self else {
                return
            }
            self.logger.warning("Priviledged helper XPC connection invalidated; switching to local mode")
            self.invalidateHelperConnection(matching: connection)
            self.setExecutionMode(.local, reason: "priviledged helper connection invalidated")
        }
        connection.resume()
        withStateLock {
            helperConnection = connection
        }
        logger.info("Privileged helper XPC client connection set up")
        return connection
    }

    /// Resolves a typed helper proxy for an existing connection.
    private func helperProxy(
        for connection: NSXPCConnection,
        operationDescription: String,
        onRoutingFailure: @escaping (Error) -> Void
    ) -> PrivilegedDiskServiceProtocol? {
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] error in
            guard let self else {
                return
            }
            self.logger.warning("Priviledged helper routing failed while \(operationDescription, privacy: .public): \(error, privacy: .public)")
            self.invalidateHelperConnection(matching: connection)
            self.setExecutionMode(.local, reason: "priviledged helper routing failed")
            onRoutingFailure(error)
        }

        guard let typedProxy = proxy as? PrivilegedDiskServiceProtocol else {
            logger.warning("Priviledged helper proxy could not be created while \(operationDescription, privacy: .public)")
            invalidateHelperConnection(matching: connection)
            setExecutionMode(.local, reason: "priviledged helper proxy unavailable")
            return nil
        }

        return typedProxy
    }

    /// Starts helper routing by opening XPC and pinging once to verify responsiveness.
    private func initializeHelperRoutingFromStartupPing() {
        guard beginStartupRoutingInitialization() else {
            logger.info("Skipping startup priviledged helper ping because one is already in progress")
            return
        }

        setExecutionMode(.local, reason: "awaiting startup priviledged helper ping")
        invalidateHelperConnection()
        let connection = makeAndStoreHelperConnection()

        guard let proxy = helperProxy(
            for: connection,
            operationDescription: "startup ping",
            onRoutingFailure: { _ in }
        ) else {
            endStartupRoutingInitialization()
            return
        }

        proxy.ping { [weak self, weak connection] success, message in
            guard let self else {
                return
            }
            defer {
                self.endStartupRoutingInitialization()
            }

            if success {
                self.setExecutionMode(.priviledgedHelper, reason: "startup priviledged helper ping succeeded")
                self.logger.info("Priviledged helper is available and will be used for mount and unmount operations")
            } else {
                let details = message ?? "No additional details"
                self.logger.warning("Priviledged helper startup ping failed: \(details, privacy: .public)")
                self.invalidateHelperConnection(matching: connection)
                self.setExecutionMode(.local, reason: "startup priviledged helper ping failed")
            }
        }
    }

    /// Configures execution mode from current helper approval status and startup helper ping result.
    @discardableResult
    func configureExecutionMode() -> Bool {
        let status = PrivilegedHelperLifecycleManager.shared.daemonStatus

        guard status == .enabled else {
            invalidateHelperConnection()
            setExecutionMode(.local, reason: "daemon status is \(status.statusDescription)")
            return false
        }

        initializeHelperRoutingFromStartupPing()
        return true
    }

    /// Attempts to register and enable privileged helper execution after an explicit user action.
    @discardableResult
    func requestPrivilegedExecutionMode() -> Bool {
        if isDaemonEnabled {
            return configureExecutionMode()
        }

        guard PrivilegedHelperLifecycleManager.shared.registerDaemon() else {
            let status = PrivilegedHelperLifecycleManager.shared.daemonStatus
            invalidateHelperConnection()
            setExecutionMode(.local, reason: "daemon registration requires user approval or failed: \(status.statusDescription)")
            return false
        }

        initializeHelperRoutingFromStartupPing()
        return true
    }

    /// Disables privileged helper execution and switches routing to local mode.
    @discardableResult
    func disablePrivilegedExecutionMode() -> Bool {
        let didDisable = PrivilegedHelperLifecycleManager.shared.unregisterDaemon()
        invalidateHelperConnection()
        setExecutionMode(.local, reason: "daemon unregistered by user action")
        return didDisable
    }

    /// Requests a mount operation with a BSD-name hint and returns optional operation details.
    func mount(volumeUUID: NSUUID, volumeName: String, bsdName: String, completion: @escaping (Bool, String?, DAReturn?) -> Void) {
        routeOperation(
            operation: .mount,
            volumeUUID: volumeUUID,
            volumeName: volumeName,
            bsdName: bsdName,
            completion: completion
        ) { proxy, reply in
            proxy.mount(volumeUUID: volumeUUID, volumeName: volumeName, bsdName: bsdName, withReply: reply)
        }
    }

    /// Requests an unmount operation with a BSD-name hint, routed by the active execution mode.
    func unmount(volumeUUID: NSUUID, volumeName: String, bsdName: String, force: Bool, completion: @escaping (Bool) -> Void) {
        routeOperation(
            operation: .unmount(force: force),
            volumeUUID: volumeUUID,
            volumeName: volumeName,
            bsdName: bsdName,
            completion: { success, _, _ in
                completion(success)
            }
        ) { proxy, reply in
            proxy.unmount(volumeUUID: volumeUUID, volumeName: volumeName, bsdName: bsdName, force: force, withReply: reply)
        }
    }

    /// Updates the system setting that controls "Disk Not Ejected Properly" notifications.
    func setEjectNotificationsMuted(_ muted: Bool, completion: @escaping (Bool, String?) -> Void) {
        let completionBox = ToggleSettingCompletionBox(completion: completion)

        guard executionMode == .priviledgedHelper else {
            DispatchQueue.main.async {
                completionBox.completion(false, "Privileged helper is unavailable")
            }
            return
        }

        let completionGate = CompletionGate()
        let completeOnce: (@escaping () -> Void) -> Void = { action in
            let actionBox = ActionBox(action: action)
            DispatchQueue.main.async {
                completionGate.runOnce(actionBox.action)
            }
        }

        let complete: (Bool, String?) -> Void = { success, message in
            completeOnce {
                completionBox.completion(success, message)
            }
        }

        guard let connection = withStateLock({ helperConnection }) else {
            logger.warning("Priviledged helper connection unavailable while toggling eject notifications")
            setExecutionMode(.local, reason: "priviledged helper connection missing")
            complete(false, "Privileged helper connection unavailable")
            return
        }

        guard let proxy = helperProxy(
            for: connection,
            operationDescription: "toggle eject notifications",
            onRoutingFailure: { error in
                complete(false, error.localizedDescription)
            }
        ) else {
            complete(false, "Privileged helper proxy unavailable")
            return
        }

        proxy.setEjectNotificationsMuted(muted: muted) { [weak self] success, message in
            if success {
                self?.logger.info("Priviledged helper updated eject notification muting to \(muted, privacy: .public)")
            } else {
                let details = message ?? "No additional details"
                self?.logger.error("Priviledged helper failed to update eject notification muting to \(muted, privacy: .public): \(details, privacy: .public)")
            }
            complete(success, message)
        }
    }

    /// Sends a best-effort request for the privileged helper daemon to terminate itself.
    func requestHelperTermination() {
        guard PrivilegedHelperLifecycleManager.shared.isDaemonEnabled else {
            return
        }

        guard let connection = withStateLock({ helperConnection }) else {
            return
        }

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? PrivilegedDiskServiceProtocol
        proxy?.requestTermination { _, _ in }
    }

    /// Routes mount/unmount requests to priviledged helper or local execution based on current mode.
    private func routeOperation(
        operation: DiskArbitrationVolumeOperator.Operation,
        volumeUUID: NSUUID,
        volumeName: String,
        bsdName: String,
        completion: @escaping (Bool, String?, DAReturn?) -> Void,
        request: (PrivilegedDiskServiceProtocol, @escaping (Bool, String?, Int32) -> Void) -> Void
    ) {
        switch executionMode {
        case .local:
            performLocalDiskOperation(
                operation: operation,
                volumeUUID: volumeUUID,
                volumeName: volumeName,
                bsdName: bsdName,
                completion: completion
            )
        case .priviledgedHelper:
            Self.logOperationDispatch(
                logger: logger,
                source: "Priviledged helper",
                operation: operation,
                volumeName: volumeName,
                volumeUUID: volumeUUID as UUID,
                bsdName: bsdName
            )
            performHelperOperationWithFallback(
                operation: operation,
                volumeUUID: volumeUUID,
                volumeName: volumeName,
                bsdName: bsdName,
                completion: completion,
                request: request
            )
        }
    }

    /// Executes a priviledged helper-backed operation and falls back to local execution on routing failures.
    private func performHelperOperationWithFallback(
        operation: DiskArbitrationVolumeOperator.Operation,
        volumeUUID: NSUUID,
        volumeName: String,
        bsdName: String,
        completion: @escaping (Bool, String?, DAReturn?) -> Void,
        request: (PrivilegedDiskServiceProtocol, @escaping (Bool, String?, Int32) -> Void) -> Void
    ) {
        let completionGate = CompletionGate()
        let completeOnce: (@escaping () -> Void) -> Void = { action in
            let actionBox = ActionBox(action: action)
            DispatchQueue.main.async {
                completionGate.runOnce(actionBox.action)
            }
        }

        let complete: (Bool, String?, DAReturn?) -> Void = { success, message, status in
            completeOnce {
                completion(success, message, status)
            }
        }

        let completeWithLocalFallback = {
            completeOnce { [weak self] in
                guard let self else {
                    completion(false, "Router unavailable while falling back to local execution", nil)
                    return
                }

                self.performLocalDiskOperation(
                    operation: operation,
                    volumeUUID: volumeUUID,
                    volumeName: volumeName,
                    bsdName: bsdName,
                    completion: completion
                )
            }
        }

        guard let connection = withStateLock({ helperConnection }) else {
            logger.warning("Priviledged helper connection unavailable while \(operation.operationName, privacy: .public); falling back to local execution")
            setExecutionMode(.local, reason: "priviledged helper connection missing")
            completeWithLocalFallback()
            return
        }

        guard let proxy = helperProxy(
            for: connection,
            operationDescription: "\(operation.operationName) \(VolumeLogLabelFormatter.label(name: volumeName, uuid: volumeUUID as UUID, bsdName: bsdName))",
            onRoutingFailure: { _ in
                completeWithLocalFallback()
            }
        ) else {
            completeWithLocalFallback()
            return
        }

        request(proxy) { [weak self] success, message, statusRawValue in
            let status: DAReturn? = success ? nil : statusRawValue
            if let logger = self?.logger {
                Self.logOperationResult(
                    logger: logger,
                    source: "Priviledged helper",
                    operation: operation,
                    volumeName: volumeName,
                    volumeUUID: volumeUUID as UUID,
                    bsdName: bsdName,
                    success: success,
                    message: message
                )
            }
            complete(success, message, status)
        }
    }

    /// Executes mount/unmount in the app process when priviledged helper routing is unavailable.
    private func performLocalDiskOperation(
        operation: DiskArbitrationVolumeOperator.Operation,
        volumeUUID: NSUUID,
        volumeName: String,
        bsdName: String,
        completion: @escaping (Bool, String?, DAReturn?) -> Void
    ) {
        let uuid = volumeUUID as UUID
        let logger = self.logger
        let completionBox = OperationCompletionBox(completion: completion)

        Self.logOperationDispatch(
            logger: logger,
            source: "Local",
            operation: operation,
            volumeName: volumeName,
            volumeUUID: uuid,
            bsdName: bsdName
        )

        localOperationQueue.async {
            let result = DiskArbitrationVolumeOperator.perform(volumeUUID: uuid, volumeName: volumeName, bsdName: bsdName, operation: operation)
            let success = result.success
            let message = result.message
            let status = result.status
            DispatchQueue.main.async {
                Self.logOperationResult(
                    logger: logger,
                    source: "Local",
                    operation: operation,
                    volumeName: volumeName,
                    volumeUUID: uuid,
                    bsdName: bsdName,
                    success: success,
                    message: message
                )
                completionBox.completion(success, message, status)
            }
        }
    }

}
