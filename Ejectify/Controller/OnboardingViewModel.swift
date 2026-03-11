//
//  OnboardingViewModel.swift
//  Ejectify
//
//  Created by Codex on 09/03/2026.
//

import SwiftUI

/// Owns onboarding actions and helper-approval polling state for SwiftUI rendering.
@MainActor
final class OnboardingViewModel: ObservableObject {

    /// Whether helper approval polling is currently active.
    @Published private(set) var isPollingForApproval = false

    /// Whether the skip-confirmation alert is currently shown.
    @Published var isSkipConfirmationPresented = false

    /// Callback invoked once helper approval has been detected.
    private var onApproved: () -> Void

    /// Callback invoked once skip has been confirmed by the user.
    private var onSkipConfirmed: () -> Void

    /// Polling task used to periodically check helper approval status.
    private var approvalPollingTask: Task<Void, Never>?

    /// Creates a view model with side-effect callbacks owned by the window controller.
    init(onApproved: @escaping () -> Void = {}, onSkipConfirmed: @escaping () -> Void = {}) {
        self.onApproved = onApproved
        self.onSkipConfirmed = onSkipConfirmed
    }

    /// Replaces side-effect callbacks after the owning window controller has fully initialized.
    func setCallbacks(onApproved: @escaping () -> Void, onSkipConfirmed: @escaping () -> Void) {
        self.onApproved = onApproved
        self.onSkipConfirmed = onSkipConfirmed
    }

    /// Starts helper registration, opens System Settings, and begins polling for approval changes.
    func openSettingsClicked() {
        if VolumeOperationRouter.shared.requestPrivilegedExecutionMode(), VolumeOperationRouter.shared.isDaemonEnabled {
            stopApprovalPolling()
            onApproved()
            return
        }

        PrivilegedHelperLifecycleManager.shared.openSystemSettingsLoginItems()
        startApprovalPolling()
    }

    /// Presents a confirmation alert before skipping privileged helper approval.
    func skipClicked() {
        isSkipConfirmationPresented = true
    }

    /// Applies the user's confirmed skip choice and ends the onboarding flow.
    func confirmSkip() {
        isSkipConfirmationPresented = false
        stopApprovalPolling()
        onSkipConfirmed()
    }

    /// Starts periodic helper approval polling if not already active.
    func startApprovalPolling() {
        guard approvalPollingTask == nil else {
            return
        }

        isPollingForApproval = true
        approvalPollingTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else {
                    return
                }
                if VolumeOperationRouter.shared.isDaemonEnabled {
                    stopApprovalPolling()
                    onApproved()
                    return
                }
            }
        }
    }

    /// Stops helper approval polling and clears associated in-memory state.
    func stopApprovalPolling() {
        approvalPollingTask?.cancel()
        approvalPollingTask = nil
        isPollingForApproval = false
    }
}
