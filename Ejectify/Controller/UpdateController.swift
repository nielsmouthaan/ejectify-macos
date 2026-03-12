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
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "UpdateController")

    /// Sparkle controller owning updater state and standard update UI.
    private let updaterController: SPUStandardUpdaterController

    /// Initializes Sparkle without auto-start so app launch controls startup timing.
    init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Starts Sparkle update scheduling and feed checks.
    func start() {
        do {
            try updaterController.updater.start()
        } catch {
            logger.error("Failed to start Sparkle updater: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Triggers a user-initiated update check from the status menu.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
