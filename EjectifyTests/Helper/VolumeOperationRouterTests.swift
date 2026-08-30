//
//  VolumeOperationRouterTests.swift
//  EjectifyTests
//
//  Created by Codex on 28/08/2026.
//

import Foundation
import ServiceManagement
import Testing

struct VolumeOperationRouterTests {

    @Test func diskutilHelperCapabilityIsVersioned() {
        #expect(PrivilegedHelperConfiguration.diskutilCapabilityVersion == 2)
    }

    @Test(arguments: [
        (version: 1, supported: false),
        (version: 2, supported: true),
        (version: 3, supported: true)
    ])
    func helperCapabilityRequiresCFUUIDIdentitySupport(fixture: (version: Int, supported: Bool)) {
        #expect(VolumeOperationRouter.supportsHelperCapability(fixture.version) == fixture.supported)
    }

    @Test func helperRefreshWaitsForUnregistrationBeforeRegistering() {
        let service = FakePrivilegedHelperService(status: .enabled)
        let manager = PrivilegedHelperLifecycleManager(daemonService: service)
        let result = LockedValue<PrivilegedHelperLifecycleManager.DaemonRefreshResult>()

        manager.refreshDaemon { refreshResult in
            result.value = refreshResult
        }

        #expect(service.events == ["unregister"])
        #expect(result.value == nil)

        service.completeUnregistration()

        #expect(service.events == ["unregister", "register"])
        #expect(result.value == .enabled)
    }

    @Test func helperRefreshReportsRegistrationFailure() {
        let service = FakePrivilegedHelperService(status: .notRegistered, registrationOutcome: .failure)
        let manager = PrivilegedHelperLifecycleManager(daemonService: service)
        let result = LockedValue<PrivilegedHelperLifecycleManager.DaemonRefreshResult>()

        manager.refreshDaemon { refreshResult in
            result.value = refreshResult
        }

        #expect(service.events == ["register"])
        #expect(result.value == .failed)
    }

    @Test func helperRefreshPreservesApprovalRequirement() {
        let service = FakePrivilegedHelperService(status: .notRegistered, registrationOutcome: .requiresApproval)
        let manager = PrivilegedHelperLifecycleManager(daemonService: service)
        let result = LockedValue<PrivilegedHelperLifecycleManager.DaemonRefreshResult>()

        manager.refreshDaemon { refreshResult in
            result.value = refreshResult
        }

        #expect(service.events == ["register"])
        #expect(result.value == .requiresApproval)
    }

    @Test func helperRefreshRecognizesServiceManagementApprovalDenialBeforeStatusUpdates() {
        let service = FakePrivilegedHelperService(status: .notRegistered, registrationOutcome: .approvalDenied)
        let manager = PrivilegedHelperLifecycleManager(daemonService: service)
        let result = LockedValue<PrivilegedHelperLifecycleManager.DaemonRefreshResult>()

        manager.refreshDaemon { refreshResult in
            result.value = refreshResult
        }

        #expect(service.events == ["register"])
        #expect(result.value == .requiresApproval)
    }

    @Test func helperRefreshAttemptsOnlyOnceUntilReset() {
        let service = FakePrivilegedHelperService(status: .notRegistered)
        let manager = PrivilegedHelperLifecycleManager(daemonService: service)
        let firstResult = LockedValue<PrivilegedHelperLifecycleManager.DaemonRefreshResult>()
        let secondResult = LockedValue<PrivilegedHelperLifecycleManager.DaemonRefreshResult>()

        manager.refreshDaemon { refreshResult in
            firstResult.value = refreshResult
        }
        manager.refreshDaemon { refreshResult in
            secondResult.value = refreshResult
        }

        #expect(service.events == ["register"])
        #expect(firstResult.value == .enabled)
        #expect(secondResult.value == .alreadyAttempted)
    }

    @Test func helperClientRequirementPinsAppIdentifierAndTeam() {
        let requirement = PrivilegedHelperConfiguration.appSigningRequirement
        #expect(requirement.contains("nl.nielsmouthaan.Ejectify"))
        #expect(requirement.contains("DNG6HL3Y5G"))
    }

    @Test(arguments: [
        VolumeOperationTrigger.manual,
        .hotkey,
        .display,
        .session,
        .systemSleep,
        .automaticRemount,
        .encryptedRecovery
    ])
    func operationTriggersHaveStableDistinctDiagnosticValues(_ trigger: VolumeOperationTrigger) {
        let values = Set([
            VolumeOperationTrigger.manual,
            .hotkey,
            .display,
            .session,
            .systemSleep,
            .automaticRemount,
            .encryptedRecovery
        ].map(\.rawValue))
        #expect(values.count == 7)
        #expect(values.contains(trigger.rawValue))
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?

    var value: Value? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class FakePrivilegedHelperService: PrivilegedHelperServiceControlling, @unchecked Sendable {
    enum RegistrationOutcome {
        case enabled
        case requiresApproval
        case approvalDenied
        case failure
    }

    private enum FakeError: Error {
        case registrationFailed
    }

    private let lock = NSLock()
    private var statusStorage: SMAppService.Status
    private let registrationOutcome: RegistrationOutcome
    private var eventsStorage: [String] = []
    private var pendingUnregistration: (@Sendable (Error?) -> Void)?

    init(status: SMAppService.Status, registrationOutcome: RegistrationOutcome = .enabled) {
        statusStorage = status
        self.registrationOutcome = registrationOutcome
    }

    var status: SMAppService.Status {
        lock.withLock { statusStorage }
    }

    var events: [String] {
        lock.withLock { eventsStorage }
    }

    func register() throws {
        let outcome = lock.withLock { () -> RegistrationOutcome in
            eventsStorage.append("register")
            return registrationOutcome
        }

        switch outcome {
        case .enabled:
            lock.withLock { statusStorage = .enabled }
        case .requiresApproval:
            lock.withLock { statusStorage = .requiresApproval }
        case .approvalDenied:
            throw NSError(domain: "SMAppServiceErrorDomain", code: 1)
        case .failure:
            throw FakeError.registrationFailed
        }
    }

    func unregister() throws {
        lock.withLock {
            eventsStorage.append("unregister")
            statusStorage = .notRegistered
        }
    }

    func unregisterAfterTermination(completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock {
            eventsStorage.append("unregister")
            pendingUnregistration = completion
        }
    }

    func completeUnregistration(error: Error? = nil) {
        let completion = lock.withLock { () -> (@Sendable (Error?) -> Void)? in
            if error == nil {
                statusStorage = .notRegistered
            }
            defer { pendingUnregistration = nil }
            return pendingUnregistration
        }
        completion?(error)
    }
}
