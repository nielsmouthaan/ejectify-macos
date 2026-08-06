//
//  PrivilegedHelperLifecycleManager.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation
import ServiceManagement

/// Manages privileged helper daemon registration and approval status.
final class PrivilegedHelperLifecycleManager: @unchecked Sendable {

    /// Shared lifecycle manager used by app routing logic.
    static let shared = PrivilegedHelperLifecycleManager()


    /// Lazily created ServiceManagement daemon handle for status and registration calls.
    private var daemonService: SMAppService {
        SMAppService.daemon(plistName: PrivilegedHelperConfiguration.launchDaemonPlistName)
    }

    /// Returns the current ServiceManagement status for the privileged helper daemon.
    var daemonStatus: SMAppService.Status {
        daemonService.status
    }

    /// Returns whether the privileged helper daemon is currently registered and approved to run.
    var isDaemonEnabled: Bool {
        daemonStatus == .enabled
    }

    /// Registers the launch daemon and returns whether it is ready for privileged routing.
    @discardableResult
    func registerDaemon() -> Bool {
        let daemonService = self.daemonService
        do {
            switch daemonService.status {
            case .notRegistered:
                try daemonService.register()
                Log.privilegedHelper.log("Privileged helper daemon was not registered. Registration attempted; current status: \(daemonService.status.statusDescription)")
            case .enabled:
                Log.privilegedHelper.info("Privileged helper daemon already registered and enabled")
            case .requiresApproval:
                Log.privilegedHelper.warning("Privileged helper daemon requires approval")
            case .notFound:
                try daemonService.register()
                Log.privilegedHelper.log("Privileged helper daemon service was not found. Registration attempted; current status: \(daemonService.status.statusDescription)")
            @unknown default:
                Log.privilegedHelper.warning("Privileged helper daemon reported an unexpected status: \(daemonService.status.statusDescription)")
            }
        } catch {
            Log.privilegedHelper.error(error, message: "Privileged helper daemon registration failed")
        }

        return isDaemonEnabled
    }

    /// Re-registers an enabled launch daemon after unregistering its previous app-bundle association.
    @discardableResult
    func reregisterDaemon() async -> Bool {
        let daemonService = self.daemonService

        do {
            try await Self.replaceDaemonRegistration(
                unregister: {
                    try await daemonService.unregister()
                    Log.privilegedHelper.log("Privileged helper daemon unregistered before replacement registration")
                },
                register: {
                    try daemonService.register()
                    Log.privilegedHelper.log("Privileged helper daemon replacement registered; currentStatus=\(daemonService.status.statusDescription)")
                }
            )
        } catch {
            Log.privilegedHelper.error(error, message: "Privileged helper daemon replacement registration failed")
        }

        return isDaemonEnabled
    }

    /// Awaits `unregister` before invoking `register` for a replacement daemon registration.
    static func replaceDaemonRegistration(
        unregister: () async throws -> Void,
        register: () throws -> Void
    ) async throws {
        try await unregister()
        try register()
    }

    /// Unregisters the launch daemon and returns whether privileged routing is disabled.
    @discardableResult
    func unregisterDaemon() -> Bool {
        let daemonService = self.daemonService
        do {
            switch daemonService.status {
            case .enabled, .requiresApproval:
                try daemonService.unregister()
                Log.privilegedHelper.log("Privileged helper daemon unregistration attempted; current status: \(daemonService.status.statusDescription)")
            case .notRegistered:
                Log.privilegedHelper.info("Privileged helper daemon already unregistered")
            case .notFound:
                Log.privilegedHelper.warning("Privileged helper daemon was not found while attempting unregistration")
            @unknown default:
                Log.privilegedHelper.warning("Privileged helper daemon reported an unexpected status while unregistering: \(daemonService.status.statusDescription)")
            }
        } catch {
            Log.privilegedHelper.error(error, message: "Privileged helper daemon unregistration failed")
        }

        return !isDaemonEnabled
    }
}
