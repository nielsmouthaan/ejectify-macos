//
//  PrivilegedHelperManager.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation
import OSLog
import ServiceManagement

final class PrivilegedHelperManager: @unchecked Sendable {

    enum OperationMode: String {
        case local
        case privilegedHelper
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

    static let shared = PrivilegedHelperManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "PrivilegedHelperManager")
    private let localOperationQueue = DispatchQueue(label: "nl.nielsmouthaan.Ejectify.LocalDiskOperation", qos: .userInitiated)
    private let stateLock = NSLock()
    private var operationModeStorage: OperationMode = .local
    private var helperConnection: NSXPCConnection?
    private var daemonService: SMAppService {
        SMAppService.daemon(plistName: PrivilegedHelperConfiguration.launchDaemonPlistName)
    }

    /// Returns whether the privileged helper daemon is currently registered and approved to run.
    var isDaemonEnabled: Bool {
        daemonService.status == .enabled
    }

    /// Returns the active operation mode for mount and unmount routing.
    var operationMode: OperationMode {
        withStateLock { operationModeStorage }
    }

    /// Appends a message suffix in the format `": <message>"` when a non-empty message is available.
    private nonisolated static func messageSuffix(for message: String?) -> String {
        guard let message, !message.isEmpty else {
            return ""
        }
        return ": \(message)"
    }

    /// Logs a mount/unmount outcome with a consistent format used by privileged and local execution paths.
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

    /// Runs a closure while holding the shared manager state lock.
    private func withStateLock<T>(_ action: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return action()
    }

    /// Updates operation mode and logs the transition reason.
    private func setOperationMode(_ mode: OperationMode, reason: String) {
        let previousMode = withStateLock {
            let previous = operationModeStorage
            operationModeStorage = mode
            return previous
        }

        if previousMode == mode {
            logger.info("Operation mode remains \(mode.rawValue, privacy: .public): \(reason, privacy: .public)")
        } else {
            logger.info("Operation mode changed from \(previousMode.rawValue, privacy: .public) to \(mode.rawValue, privacy: .public): \(reason, privacy: .public)")
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
            self.logger.warning("Privileged helper XPC connection interrupted; switching to local mode")
            self.invalidateHelperConnection(matching: connection)
            self.setOperationMode(.local, reason: "helper connection interrupted")
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self else {
                return
            }
            self.logger.warning("Privileged helper XPC connection invalidated; switching to local mode")
            self.invalidateHelperConnection(matching: connection)
            self.setOperationMode(.local, reason: "helper connection invalidated")
        }
        connection.resume()
        withStateLock {
            helperConnection = connection
        }
        logger.info("Privileged helper XPC connection established")
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
            self.logger.warning("Privileged helper routing failed while \(operationDescription, privacy: .public): \(error, privacy: .public)")
            self.invalidateHelperConnection(matching: connection)
            self.setOperationMode(.local, reason: "helper routing failed")
            onRoutingFailure(error)
        }

        guard let typedProxy = proxy as? PrivilegedDiskServiceProtocol else {
            logger.warning("Privileged helper proxy could not be created while \(operationDescription, privacy: .public)")
            invalidateHelperConnection(matching: connection)
            setOperationMode(.local, reason: "helper proxy unavailable")
            return nil
        }

        return typedProxy
    }

    /// Starts helper routing by opening XPC and pinging once to verify responsiveness.
    private func initializeHelperRoutingFromStartupPing() {
        setOperationMode(.local, reason: "awaiting startup helper ping")
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
                self.setOperationMode(.privilegedHelper, reason: "startup helper ping succeeded")
                self.logger.info("Privileged helper is available and will be used for mount and unmount operations")
            } else {
                let details = message ?? "No additional details"
                self.logger.warning("Privileged helper startup ping failed: \(details, privacy: .public)")
                self.invalidateHelperConnection(matching: connection)
                self.setOperationMode(.local, reason: "startup helper ping failed")
            }
        }
    }

    /// Registers the launch daemon so privileged XPC requests can be accepted.
    private func registerDaemonIfNeeded() {
        let daemonService = self.daemonService
        do {
            switch daemonService.status {
            case .notRegistered:
                try daemonService.register()
                logger.info("Privileged helper daemon was not registered. Registration attempted; current status: \(daemonService.status.statusDescription, privacy: .public)")
            case .enabled:
                logger.info("Privileged helper daemon already registered and enabled")
            case .requiresApproval:
                logger.warning("Privileged helper daemon is not runnable yet: \(daemonService.status.statusDescription, privacy: .public)")
            case .notFound:
                try daemonService.register()
                logger.info("Privileged helper daemon service was not found. Registration attempted; current status: \(daemonService.status.statusDescription, privacy: .public)")
            @unknown default:
                logger.warning("Privileged helper daemon reported an unexpected status: \(daemonService.status.statusDescription, privacy: .public)")
            }
        } catch {
            logger.error("Privileged helper daemon registration failed: \(error, privacy: .public)")
        }
    }

    /// Registers the launch daemon and returns whether it is ready for privileged routing.
    @discardableResult
    func registerDaemon() -> Bool {
        registerDaemonIfNeeded()
        return isDaemonEnabled
    }

    /// Unregisters the launch daemon and returns whether privileged routing is disabled.
    @discardableResult
    func unregisterDaemon() -> Bool {
        let daemonService = self.daemonService
        do {
            switch daemonService.status {
            case .enabled, .requiresApproval:
                try daemonService.unregister()
                logger.info("Privileged helper daemon unregistration attempted; current status: \(daemonService.status.statusDescription, privacy: .public)")
            case .notRegistered:
                logger.info("Privileged helper daemon already unregistered")
            case .notFound:
                logger.warning("Privileged helper daemon was not found while attempting unregistration")
            @unknown default:
                logger.warning("Privileged helper daemon reported an unexpected status while unregistering: \(daemonService.status.statusDescription, privacy: .public)")
            }
        } catch {
            logger.error("Privileged helper daemon unregistration failed: \(error, privacy: .public)")
        }

        invalidateHelperConnection()
        setOperationMode(.local, reason: "daemon unregistered")
        return !isDaemonEnabled
    }

    /// Configures operation mode from current preferences and startup helper ping result.
    @discardableResult
    func configureOperationMode() -> Bool {
        guard Preference.useElevatedPermissions else {
            return unregisterDaemon()
        }

        guard registerDaemon() else {
            invalidateHelperConnection()
            setOperationMode(.local, reason: "daemon unavailable while elevated permissions are enabled")
            return false
        }

        initializeHelperRoutingFromStartupPing()
        return true
    }

    /// Requests a mount operation with a BSD-name hint, routed by the configured operation mode.
    func mount(volumeUUID: NSUUID, volumeName: String, bsdName: String, completion: @escaping (Bool) -> Void) {
        performRequest(
            operation: .mount,
            volumeUUID: volumeUUID,
            volumeName: volumeName,
            bsdName: bsdName,
            completion: completion
        ) { proxy, reply in
            proxy.mount(volumeUUID: volumeUUID, volumeName: volumeName, bsdName: bsdName, withReply: reply)
        }
    }

    /// Requests an unmount operation with a BSD-name hint, routed by the configured operation mode.
    func unmount(volumeUUID: NSUUID, volumeName: String, bsdName: String, force: Bool, completion: @escaping (Bool) -> Void) {
        performRequest(
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

        guard operationMode == .privilegedHelper else {
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
            logger.warning("Privileged helper connection unavailable while toggling eject notifications")
            setOperationMode(.local, reason: "helper connection missing")
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
                self?.logger.info("Privileged helper updated eject notification muting to \(muted, privacy: .public)")
            } else {
                let details = message ?? "No additional details"
                self?.logger.error("Privileged helper failed to update eject notification muting to \(muted, privacy: .public): \(details, privacy: .public)")
            }
            complete(success, message)
        }
    }

    /// Routes mount/unmount requests to helper or local execution based on current operation mode.
    private func performRequest(
        operation: DiskArbitrationVolumeOperator.Operation,
        volumeUUID: NSUUID,
        volumeName: String,
        bsdName: String,
        completion: @escaping (Bool) -> Void,
        request: (PrivilegedDiskServiceProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) {
        switch operationMode {
        case .local:
            performLocalOperation(operation: operation, volumeUUID: volumeUUID, volumeName: volumeName, bsdName: bsdName, completion: completion)
        case .privilegedHelper:
            performPrivilegedOperation(
                operation: operation,
                volumeUUID: volumeUUID,
                volumeName: volumeName,
                bsdName: bsdName,
                completion: completion,
                request: request
            )
        }
    }

    /// Executes a helper-backed operation and falls back to local execution on helper routing failures.
    private func performPrivilegedOperation(
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

                self.performLocalOperation(operation: operation, volumeUUID: volumeUUID, volumeName: volumeName, bsdName: bsdName, completion: completion)
            }
        }

        guard let connection = withStateLock({ helperConnection }) else {
            logger.warning("Privileged helper connection unavailable while \(operation.operationName, privacy: .public); falling back to local")
            setOperationMode(.local, reason: "helper connection missing")
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
                    source: "Privileged helper",
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

    /// Executes mount/unmount in the main app process when helper routing is unavailable.
    private func performLocalOperation(
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
                    source: "Local",
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
