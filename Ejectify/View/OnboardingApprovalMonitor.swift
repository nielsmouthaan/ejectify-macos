//
//  OnboardingApprovalMonitor.swift
//  Ejectify
//
//  Created by Codex on 18/03/2026.
//

import SwiftUI

/// Tracks privileged-helper approval state while onboarding is visible.
@MainActor
final class OnboardingApprovalMonitor: ObservableObject {

    /// Latest Service Management status observed for the privileged helper daemon.
    @Published private(set) var daemonStatus = PrivilegedHelperLifecycleManager.shared.daemonStatus

    /// Polling task used to periodically refresh helper approval status.
    private var approvalPollingTask: Task<Void, Never>?

    /// Starts periodic daemon-status monitoring if not already active.
    func startMonitoring() {
        guard approvalPollingTask == nil else {
            return
        }

        approvalPollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else {
                    return
                }
                let daemonStatus = PrivilegedHelperLifecycleManager.shared.daemonStatus
                await MainActor.run {
                    self.daemonStatus = daemonStatus
                }
            }
        }
    }

    /// Stops daemon-status monitoring and clears associated in-memory state.
    func stopMonitoring() {
        approvalPollingTask?.cancel()
        approvalPollingTask = nil
    }
}
