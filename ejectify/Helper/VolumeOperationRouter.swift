//
//  VolumeOperationRouter.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation
import OSLog

/// Routes volume operations to the priviledged helper when available, with local fallback.
final class VolumeOperationRouter: @unchecked Sendable {

    enum ExecutionMode: String {
        case local
        case priviledgedHelper
    }

    /// Wraps completion closures so they can cross Dispatch sendable boundaries safely.
    private final class CompletionBox: @unchecked Sendable {
        let completion: (Bool) -> Void

        init(completion: @escaping (Bool) -> Void) {
            self.completion = completion
        }
    }

    /// Wraps completion closures with error details so they can cross Dispatch sendable boundaries safely.
    private final class ToggleSettingCompletionBox: @unchecked Sendable {
        let completion: (Bool, String?) -> Void

        init(completion: @escaping (Bool, String?) -> Void) {
            self.completion = completion
        }
    }

    /// Stores completion actions so they can cross Dispatch sendable boundaries safely.
    private final class ActionBox: @unchecked Sendable {
        let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }
    }

    /// Ensures a completion path is only executed once across concurrent callbacks.
    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var didComplete = false

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

    static let shared = VolumeOperationRouter()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "VolumeOperationRouter")
    private let lifecycleManager = PrivilegedHelperLifecycleManager.shared
    private let localOperationQueue = DispatchQueue(label: "nl.nielsmouthaan.Ejectify.LocalDiskOperation", qos: .userInitiated)
    private let stateLock = NSLock()
    private var executionModeStorage: ExecutionMode = .local
    private var helperConnection: NSXPCConnection?

    /// Returns whether the privileged helper daemon is currently registered and approved to run.
    var isDaemonEnabled: Bool {
        lifecycleManager.isDaemonEnabled
    }

    /// Returns the active execution mode for mount and unmount routing.
    var executionMode: ExecutionMode {
        withStateLock { executionModeStorage }
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

    /// Runs a closure while holding the shared router state lock.
    private func withStateLock<T>(_ action: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return action()
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
        logger.info("Priviledged helper XPC connection established")
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
        setExecutionMode(.local, reason: "awaiting startup priviledged helper ping")
        invalidateHelperConnection()
        let connection = makeAndStoreHelperConnection()

        guard let proxy = helperProxy(
            for: connection,
            operationDescription: "startup ping",
            onRoutingFailure: { _ in }
        ) else {
            return
        }

        proxy.ping { [weak self, weak connection] success, message in
            guard let self else {
                return
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

    /// Configures execution mode from current preferences and startup helper ping result.
    @discardableResult
    func configureExecutionMode() -> Bool {
        guard Preference.useElevatedPermissions else {
            let didDisable = lifecycleManager.unregisterDaemon()
            invalidateHelperConnection()
            setExecutionMode(.local, reason: "daemon unregistered")
            return didDisable
        }

        guard lifecycleManager.registerDaemon() else {
            invalidateHelperConnection()
            setExecutionMode(.local, reason: "daemon unavailable while elevated permissions are enabled")
            return false
        }

        initializeHelperRoutingFromStartupPing()
        return true
    }

    /// Requests a mount operation with a BSD-name hint, routed by the active execution mode.
    func mount(volumeUUID: NSUUID, volumeName: String, bsdName: String, completion: @escaping (Bool) -> Void) {
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
            completion: completion
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

    /// Routes mount/unmount requests to priviledged helper or local execution based on current mode.
    private func routeOperation(
        operation: DiskArbitrationVolumeOperator.Operation,
        volumeUUID: NSUUID,
        volumeName: String,
        bsdName: String,
        completion: @escaping (Bool) -> Void,
        request: (PrivilegedDiskServiceProtocol, @escaping (Bool, String?) -> Void) -> Void
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
        completion: @escaping (Bool) -> Void,
        request: (PrivilegedDiskServiceProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) {
        let completionGate = CompletionGate()
        let completeOnce: (@escaping () -> Void) -> Void = { action in
            let actionBox = ActionBox(action: action)
            DispatchQueue.main.async {
                completionGate.runOnce(actionBox.action)
            }
        }

        let complete: (Bool) -> Void = { success in
            completeOnce {
                completion(success)
            }
        }

        let completeWithLocalFallback = {
            completeOnce { [weak self] in
                guard let self else {
                    completion(false)
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

        request(proxy) { [weak self] success, message in
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
            complete(success)
        }
    }

    /// Executes mount/unmount in the app process when priviledged helper routing is unavailable.
    private func performLocalDiskOperation(
        operation: DiskArbitrationVolumeOperator.Operation,
        volumeUUID: NSUUID,
        volumeName: String,
        bsdName: String,
        completion: @escaping (Bool) -> Void
    ) {
        let uuid = volumeUUID as UUID
        let logger = self.logger
        let completionBox = CompletionBox(completion: completion)

        localOperationQueue.async {
            let result = DiskArbitrationVolumeOperator.perform(volumeUUID: uuid, volumeName: volumeName, bsdName: bsdName, operation: operation)
            let success = result.0
            let message = result.1
            DispatchQueue.main.async {
                Self.logOperationResult(
                    logger: logger,
                    source: "local",
                    operation: operation,
                    volumeName: volumeName,
                    volumeUUID: uuid,
                    bsdName: bsdName,
                    success: success,
                    message: message
                )
                completionBox.completion(success)
            }
        }
    }

}
