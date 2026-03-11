//
//  OnboardingWindowController.swift
//  Ejectify
//
//  Created by Codex on 09/03/2026.
//

import AppKit
import SwiftUI

/// Guides first-run users through privileged helper approval with a local-fallback escape hatch.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    /// Callback invoked after the window fully closes.
    private let onDidClose: () -> Void

    /// View model that owns onboarding action and polling state.
    private let viewModel: OnboardingViewModel

    /// Initializes and configures the onboarding window.
    init(onDidClose: @escaping () -> Void) {
        self.onDidClose = onDidClose
        self.viewModel = OnboardingViewModel()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.title = "Ejectify Setup"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: OnboardingView(viewModel: viewModel))

        viewModel.setCallbacks(
            onApproved: { [weak self] in
                self?.handleApprovalDetected()
            },
            onSkipConfirmed: { [weak self] in
                self?.handleSkipConfirmed()
            }
        )
    }

    /// Storyboard initialization is unsupported because this controller is built in code.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the onboarding window centered and brings it to the foreground.
    func showCentered() {
        guard let window else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    /// Stops polling when the window has closed and notifies the owner.
    func windowWillClose(_ notification: Notification) {
        viewModel.stopApprovalPolling()
        onDidClose()
    }

    /// Finalizes successful onboarding, enables privileged routing, and closes the window.
    private func handleApprovalDetected() {
        _ = VolumeOperationRouter.shared.configureExecutionMode()
        Preference.hasSeenOnboarding = true
        close()
    }

    /// Applies local fallback mode after explicit user confirmation and closes onboarding.
    private func handleSkipConfirmed() {
        _ = VolumeOperationRouter.shared.disablePrivilegedExecutionMode()
        Preference.hasSeenOnboarding = true
        close()
    }
}
