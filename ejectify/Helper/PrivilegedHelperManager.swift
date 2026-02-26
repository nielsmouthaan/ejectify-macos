//
//  PrivilegedHelperManager.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation
import OSLog
import ServiceManagement

@MainActor
final class PrivilegedHelperManager {
    
    /// Wraps completion closures so they can cross Dispatch sendable boundaries safely.
    private final class CompletionBox: @unchecked Sendable {
        let completion: (Bool) -> Void

        init(completion: @escaping (Bool) -> Void) {
            self.completion = completion
        }
    }

    static let shared = PrivilegedHelperManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "PrivilegedHelperManager")
    private var didAttemptRegistration = false
    private var helperIsEnabled = false
    private let localOperationQueue = DispatchQueue(label: "nl.nielsmouthaan.Ejectify.LocalDiskOperation", qos: .userInitiated)

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
        success: Bool,
        message: String?
    ) {
        let suffix = messageSuffix(for: message)
        if success {
            logger.info("\(source, privacy: .public) \(operation.operationName, privacy: .public) succeeded for \(volumeName, privacy: .public)\(suffix, privacy: .public)")
        } else {
            logger.error("\(source, privacy: .public) \(operation.operationName, privacy: .public) failed for \(volumeName, privacy: .public)\(suffix, privacy: .public)")
        }
    }

    /// Registers the launch daemon so privileged XPC requests can be accepted.
    func registerDaemonIfNeeded() {
        guard !didAttemptRegistration else {
            return
        }
        didAttemptRegistration = true

        let daemonService = SMAppService.daemon(plistName: PrivilegedHelperConfiguration.launchDaemonPlistName)
        do {
            switch daemonService.status {
            case .notRegistered:
                try daemonService.register()
                logger.info("Privileged helper daemon not registered, registration attempted with status: \(daemonService.status.statusDescription, privacy: .public)")
            case .enabled:
                logger.info("Privileged helper daemon already registered");
            case .requiresApproval:
                logger.warning("Privileged helper daemon requires approval");
            case .notFound:
                try daemonService.register()
                logger.info("Privileged helper daemon was not found, registration attempted with status: \(daemonService.status.statusDescription, privacy: .public)")
            @unknown default:
                logger.warning("Privileged helper daemon reported unknown status: \(daemonService.status.statusDescription, privacy: .public)");
            }
        } catch {
            logger.error("Privileged helper daemon registration failed: \(error, privacy: .public)")
        }

        helperIsEnabled = daemonService.status == .enabled
    }

    /// Requests a mount operation, preferring the privileged helper and falling back to local Disk Arbitration when unavailable.
    func mount(volumeUUID: NSUUID, volumeName: String, completion: @escaping (Bool) -> Void) {
        performRequest(
            operation: .mount,
            volumeUUID: volumeUUID,
            volumeName: volumeName,
            completion: completion
        ) { proxy, reply in
            proxy.mount(volumeUUID: volumeUUID, volumeName: volumeName, withReply: reply)
        }
    }

    /// Requests an unmount operation, preferring the privileged helper and falling back to local Disk Arbitration when unavailable.
    func unmount(volumeUUID: NSUUID, volumeName: String, force: Bool, completion: @escaping (Bool) -> Void) {
        performRequest(
            operation: .unmount(force: force),
            volumeUUID: volumeUUID,
            volumeName: volumeName,
            completion: completion
        ) { proxy, reply in
            proxy.unmount(volumeUUID: volumeUUID, volumeName: volumeName, force: force, withReply: reply)
        }
    }

    /// Sends a request to the daemon and falls back to local Disk Arbitration when helper availability requirements are not met.
    private func performRequest(
        operation: DiskArbitrationVolumeOperator.Operation,
        volumeUUID: NSUUID,
        volumeName: String,
        completion: @escaping (Bool) -> Void,
        request: (PrivilegedDiskServiceProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) {
        if !didAttemptRegistration {
            registerDaemonIfNeeded()
        }

        if !helperIsEnabled {
            let daemonService = SMAppService.daemon(plistName: PrivilegedHelperConfiguration.launchDaemonPlistName)
            helperIsEnabled = daemonService.status == .enabled
        }

        guard helperIsEnabled else {
            performLocalOperation(operation: operation, volumeUUID: volumeUUID, volumeName: volumeName, completion: completion)
            return
        }

        let connection = NSXPCConnection(machServiceName: PrivilegedHelperConfiguration.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedDiskServiceProtocol.self)
        connection.resume()

        var didComplete = false
        let completeOnce: (@escaping () -> Void) -> Void = { action in
            DispatchQueue.main.async {
                guard !didComplete else {
                    return
                }
                didComplete = true
                action()
            }
        }

        let complete: (Bool) -> Void = { success in
            completeOnce {
                completion(success)
                connection.invalidate()
            }
        }

        let completeWithLocalFallback = {
            completeOnce { [weak self] in
                guard let self else {
                    completion(false)
                    connection.invalidate()
                    return
                }

                self.performLocalOperation(operation: operation, volumeUUID: volumeUUID, volumeName: volumeName, completion: completion)
                connection.invalidate()
            }
        }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.logger.error("Privileged helper connection failed: \(String(describing: error), privacy: .public)")
            completeWithLocalFallback()
        }) as? PrivilegedDiskServiceProtocol else {
            logger.error("Privileged helper proxy could not be created")
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
                    success: success,
                    message: message
                )
            }
            complete(success)
        }
    }

    /// Executes mount/unmount in the main app process when privileged helper routing is unavailable.
    private func performLocalOperation(
        operation: DiskArbitrationVolumeOperator.Operation,
        volumeUUID: NSUUID,
        volumeName: String,
        completion: @escaping (Bool) -> Void
    ) {
        let uuid = volumeUUID as UUID
        let logger = self.logger
        let completionBox = CompletionBox(completion: completion)

        localOperationQueue.async {
            let result = DiskArbitrationVolumeOperator.perform(volumeUUID: uuid, operation: operation)
            let success = result.0
            let message = result.1
            DispatchQueue.main.async {
                Self.logOperationResult(
                    logger: logger,
                    source: "Local",
                    operation: operation,
                    volumeName: volumeName,
                    success: success,
                    message: message
                )
                completionBox.completion(success)
            }
        }
    }

}
