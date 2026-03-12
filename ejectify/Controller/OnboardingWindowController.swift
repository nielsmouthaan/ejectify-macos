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

    /// Initializes and configures the onboarding window.
    init() {
        let hostingView = NSHostingView(rootView: OnboardingView())
        let contentSize = hostingView.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.titlebarAppearsTransparent = true
        window.setContentSize(contentSize)
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
        window.contentView = hostingView
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

        DispatchQueue.main.async { [weak window] in
            guard
                let window,
                let hostingView = window.contentView as? NSHostingView<OnboardingView>
            else {
                return
            }

            let contentSize = hostingView.fittingSize
            window.setContentSize(contentSize)
            window.contentMinSize = contentSize
            window.contentMaxSize = contentSize
            window.center()
        }
    }
}
