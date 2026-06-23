//
//  UpdateController.swift
//  Ejectify
//
//  Created by Codex on 12/03/2026.
//

import AppKit
import OSLog
import Sparkle

/// Coordinates Sparkle updater lifecycle and menu-triggered update checks.
@MainActor
final class UpdateController {

    /// Logger used for updater startup and manual check diagnostics.
    private static let logger = Logger(
        subsystem: LoggingConfiguration.subsystem,
        category: String(describing: UpdateController.self)
    )

    /// Sparkle controller owning updater state and standard update UI.
    private let updaterController: SPUStandardUpdaterController

    /// Initializes Sparkle without auto-start so app launch controls startup timing.
    init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Starts Sparkle without scheduling or forcing automatic update checks.
    func start() {
        do {
            try updaterController.updater.start()
        } catch {
            Self.logger.error("Failed to start Sparkle updater: \(error.localizedDescription)")
        }
    }

    /// Triggers a user-initiated update check from the status menu.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
