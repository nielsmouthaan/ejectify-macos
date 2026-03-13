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
final class OnboardingWindowController: NSWindowController {

    /// SwiftUI host view used for dynamic window content-size fitting.
    private let hostingView: NSHostingView<OnboardingView>

    /// Initializes and configures the onboarding window.
    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSZeroSize),
            styleMask: [.closable],
            backing: .buffered,
            defer: false
        )
        self.hostingView = NSHostingView(rootView: OnboardingView())

        super.init(window: window)

        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.contentView = hostingView
        hostingView.rootView = OnboardingView(closeAction: { [weak self] in
            self?.window?.close()
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

        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        updateWindowSize()
        window.center()
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
