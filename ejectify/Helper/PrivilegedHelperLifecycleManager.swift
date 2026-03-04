//
//  PrivilegedHelperLifecycleManager.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation
import OSLog
import ServiceManagement

/// Manages privileged helper daemon registration and approval status.
final class PrivilegedHelperLifecycleManager: @unchecked Sendable {

    /// Shared lifecycle manager used by app routing logic.
    static let shared = PrivilegedHelperLifecycleManager()

    /// Logger used for daemon registration lifecycle diagnostics.
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "PrivilegedHelperLifecycleManager")

    /// Lazily created ServiceManagement daemon handle for status and registration calls.
    private var daemonService: SMAppService {
        SMAppService.daemon(plistName: PrivilegedHelperConfiguration.launchDaemonPlistName)
    }

    /// Returns whether the privileged helper daemon is currently registered and approved to run.
    var isDaemonEnabled: Bool {
        daemonService.status == .enabled
    }

    /// Registers the launch daemon and returns whether it is ready for privileged routing.
    @discardableResult
    func registerDaemon() -> Bool {
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

}
