//
//  PrivilegedHelperLifecycleManagerTests.swift
//  EjectifyTests
//
//  Created by Codex on 06/08/2026.
//

import Testing

/// Verifies the ordering required when replacing a privileged-helper registration.
struct PrivilegedHelperLifecycleManagerTests {

    /// Observable steps in a replacement-registration operation.
    private enum Operation: Equatable {
        case unregisterStarted
        case unregisterCompleted
        case register
    }

    @Test func replacementRegistrationAwaitsUnregistration() async throws {
        var operations: [Operation] = []

        try await PrivilegedHelperLifecycleManager.replaceDaemonRegistration(
            unregister: {
                operations.append(.unregisterStarted)
                await Task.yield()
                operations.append(.unregisterCompleted)
            },
            register: {
                operations.append(.register)
            }
        )

        #expect(operations == [.unregisterStarted, .unregisterCompleted, .register])
    }
}
