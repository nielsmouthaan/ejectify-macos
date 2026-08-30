//
//  PrivilegedHelperLifecycleManager.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation
import ServiceManagement

/// Abstracts the ServiceManagement operations needed to register and refresh the privileged helper.
protocol PrivilegedHelperServiceControlling: AnyObject {

    /// Current registration and approval status.
    var status: SMAppService.Status { get }

    /// Registers the service from the current application bundle.
    func register() throws

    /// Unregisters the service synchronously for an explicit user disable action.
    func unregister() throws

    /// Unregisters the service and calls completion after its running process has been reaped.
    func unregisterAfterTermination(completion: @escaping @Sendable (Error?) -> Void)
}

/// Adapts the system `SMAppService` API for production lifecycle management and deterministic tests.
private final class ServiceManagementPrivilegedHelperService: PrivilegedHelperServiceControlling {

    /// Launch daemon service embedded in the current Ejectify application bundle.
    private let service = SMAppService.daemon(plistName: PrivilegedHelperConfiguration.launchDaemonPlistName)

    var status: SMAppService.Status {
        service.status
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func unregisterAfterTermination(completion: @escaping @Sendable (Error?) -> Void) {
        service.unregister { error in
            completion(error)
        }
    }
}

/// Manages privileged helper daemon registration and approval status.
final class PrivilegedHelperLifecycleManager: @unchecked Sendable {

    /// Outcome of replacing an incompatible registered daemon with the helper in the current app bundle.
    enum DaemonRefreshResult: Equatable, Sendable {
        case enabled
        case requiresApproval
        case failed
        case alreadyAttempted
    }

    /// Shared lifecycle manager used by app routing logic.
    static let shared = PrivilegedHelperLifecycleManager(daemonService: ServiceManagementPrivilegedHelperService())

    private let daemonService: any PrivilegedHelperServiceControlling
    private let refreshStateLock = NSLock()
    private var daemonRefreshAttempted = false

    /// Creates a lifecycle manager with the system service or an injected deterministic test service.
    init(daemonService: any PrivilegedHelperServiceControlling) {
        self.daemonService = daemonService
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

        resetDaemonRefreshAttempt()
        return !isDaemonEnabled
    }

    /// Replaces an incompatible helper once, waiting for the old daemon to terminate before registering the current bundle.
    func refreshDaemon(completion: @escaping @Sendable (DaemonRefreshResult) -> Void) {
        guard claimDaemonRefreshAttempt() else {
            Log.privilegedHelper.warning("Privileged helper refresh skipped because this launch already attempted one replacement")
            completion(.alreadyAttempted)
            return
        }

        switch daemonService.status {
        case .enabled, .requiresApproval:
            Log.privilegedHelper.log("Privileged helper refresh started; stage=unregister")
            daemonService.unregisterAfterTermination { [weak self] error in
                guard let self else {
                    completion(.failed)
                    return
                }
                guard error == nil else {
                    Log.privilegedHelper.error("Privileged helper refresh failed; stage=unregister")
                    completion(.failed)
                    return
                }

                Log.privilegedHelper.log("Privileged helper refresh completed; stage=unregister")
                self.registerRefreshedDaemon(completion: completion)
            }
        case .notRegistered, .notFound:
            registerRefreshedDaemon(completion: completion)
        @unknown default:
            Log.privilegedHelper.error("Privileged helper refresh failed; stage=inspectStatus")
            completion(.failed)
        }
    }

    /// Allows one new automatic replacement attempt after an explicit user toggle.
    func resetDaemonRefreshAttempt() {
        refreshStateLock.withLock {
            daemonRefreshAttempted = false
        }
    }

    /// Registers the helper from the current app bundle and classifies its resulting ServiceManagement status.
    private func registerRefreshedDaemon(completion: @escaping @Sendable (DaemonRefreshResult) -> Void) {
        Log.privilegedHelper.log("Privileged helper refresh started; stage=register")
        do {
            try daemonService.register()
        } catch {
            let status = daemonService.status
            let errorCode = (error as NSError).code
            if Self.registrationRequiresApproval(error: error, status: status) {
                Log.privilegedHelper.warning("Privileged helper refresh requires approval; stage=register; status=\(status.statusDescription); errorCode=\(errorCode)")
                completion(.requiresApproval)
            } else {
                Log.privilegedHelper.error("Privileged helper refresh failed; stage=register; status=\(status.statusDescription); errorCode=\(errorCode)")
                completion(.failed)
            }
            return
        }

        switch daemonService.status {
        case .enabled:
            Log.privilegedHelper.log("Privileged helper refresh completed; stage=register; status=enabled")
            completion(.enabled)
        case .requiresApproval:
            Log.privilegedHelper.warning("Privileged helper refresh requires approval; stage=register")
            completion(.requiresApproval)
        case .notRegistered, .notFound:
            Log.privilegedHelper.error("Privileged helper refresh failed; stage=register; status=unavailable")
            completion(.failed)
        @unknown default:
            Log.privilegedHelper.error("Privileged helper refresh failed; stage=register; status=unexpected")
            completion(.failed)
        }
    }

    /// Recognizes ServiceManagement's approval denial even when its immediate status is still not registered.
    static func registrationRequiresApproval(error: Error, status: SMAppService.Status) -> Bool {
        guard status != .requiresApproval else {
            return true
        }

        let error = error as NSError
        return error.domain == "SMAppServiceErrorDomain" && error.code == 1
    }

    /// Claims the single automatic replacement attempt allowed during this application launch.
    private func claimDaemonRefreshAttempt() -> Bool {
        refreshStateLock.withLock {
            guard daemonRefreshAttempted == false else {
                return false
            }
            daemonRefreshAttempted = true
            return true
        }
    }
}
