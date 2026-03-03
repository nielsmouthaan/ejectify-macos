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
    private var daemonService: SMAppService {
        SMAppService.daemon(plistName: PrivilegedHelperConfiguration.launchDaemonPlistName)
    }

    /// Returns whether the privileged helper daemon is currently registered and approved to run.
    var isDaemonEnabled: Bool {
        daemonService.status == .enabled
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

    /// Registers the launch daemon so privileged XPC requests can be accepted.
    func registerDaemonIfNeeded() {
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

        return !isDaemonEnabled
    }

    /// Requests a mount operation with a BSD-name hint, preferring the privileged helper and falling back to local Disk Arbitration when unavailable.
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

    /// Requests an unmount operation with a BSD-name hint, preferring the privileged helper and falling back to local Disk Arbitration when unavailable.
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

        guard isDaemonEnabled else {
            DispatchQueue.main.async {
                completionBox.completion(false, nil)
            }
            return
        }

        let connection = NSXPCConnection(machServiceName: PrivilegedHelperConfiguration.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedDiskServiceProtocol.self)
        connection.resume()

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
                connection.invalidate()
            }
        }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.logger.error("Privileged helper connection failed while toggling eject notifications: \(error, privacy: .public)")
            complete(false, error.localizedDescription)
        }) as? PrivilegedDiskServiceProtocol else {
            logger.error("Privileged helper proxy could not be created while toggling eject notifications")
            complete(false, nil)
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

    /// Sends a request to the daemon and falls back to local Disk Arbitration only when helper routing is unavailable.
    private func performRequest(
        operation: DiskArbitrationVolumeOperator.Operation,
        volumeUUID: NSUUID,
        volumeName: String,
        bsdName: String,
        completion: @escaping (Bool) -> Void,
        request: (PrivilegedDiskServiceProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) {
        guard isDaemonEnabled else {
            performLocalOperation(operation: operation, volumeUUID: volumeUUID, volumeName: volumeName, bsdName: bsdName, completion: completion)
            return
        }

        let connection = NSXPCConnection(machServiceName: PrivilegedHelperConfiguration.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedDiskServiceProtocol.self)
        connection.resume()

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
                connection.invalidate()
            }
        }

        let completeWithHelperRoutingFallback = {
            completeOnce { [weak self] in
                guard let self else {
                    completion(false)
                    connection.invalidate()
                    return
                }

                self.performLocalOperation(operation: operation, volumeUUID: volumeUUID, volumeName: volumeName, bsdName: bsdName, completion: completion)
                connection.invalidate()
            }
        }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.logger.error("Privileged helper connection failed: \(error, privacy: .public)")
            completeWithHelperRoutingFallback()
        }) as? PrivilegedDiskServiceProtocol else {
            logger.error("Privileged helper proxy could not be created")
            completeWithHelperRoutingFallback()
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
            if success {
                complete(true)
            } else {
                complete(false)
            }
        }
    }

    /// Executes mount/unmount in the main app process when privileged helper routing is unavailable.
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
