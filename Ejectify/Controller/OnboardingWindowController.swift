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

    /// Shared monitor for helper approval state while the onboarding window exists.
    private let approvalMonitor: OnboardingApprovalMonitor

    /// SwiftUI host view used for dynamic window content-size fitting.
    private let hostingView: NSHostingView<OnboardingView>

    /// Callback invoked after the onboarding window has closed.
    private let onWindowWillClose: () -> Void

    /// Initializes and configures the onboarding window.
    init(onWindowWillClose: @escaping () -> Void = {}) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSZeroSize),
            styleMask: [.closable],
            backing: .buffered,
            defer: false
        )
        self.approvalMonitor = OnboardingApprovalMonitor()
        self.onWindowWillClose = onWindowWillClose
        self.hostingView = NSHostingView(rootView: OnboardingView(approvalMonitor: approvalMonitor))

        super.init(window: window)

        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.contentView = hostingView
        hostingView.rootView = OnboardingView(approvalMonitor: approvalMonitor, closeAction: { [weak self] in
            self?.window?.close()
        }, approvalResolvedAction: { [weak self] in
            self?.bringToFront()
        })
        updateWindowSize()
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

        Preference.hasSeenOnboarding = true
        approvalMonitor.startMonitoring()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        updateWindowSize()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// Clears retained onboarding state after the window has closed.
    func windowWillClose(_ notification: Notification) {
        approvalMonitor.stopMonitoring()
        onWindowWillClose()
    }

    /// Re-activates the app and re-keys the onboarding window after approval status changes.
    func bringToFront() {
        guard let window else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    /// Recomputes the window size from the current SwiftUI content before presentation.
    private func updateWindowSize() {
        guard let window else {
            return
        }

        hostingView.layoutSubtreeIfNeeded()
        let contentSize = hostingView.fittingSize
        window.setContentSize(contentSize)
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
    }
}
