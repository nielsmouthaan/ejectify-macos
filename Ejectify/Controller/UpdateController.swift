//
//  UpdateController.swift
//  Ejectify
//
//  Created by Codex on 12/03/2026.
//

import AppKit
import Sparkle

/// Coordinates Sparkle updater lifecycle and menu-triggered update checks.
@MainActor
final class UpdateController {


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
            Log.updates.info("Sparkle updater started")
        } catch {
            Log.updates.error(error, message: "Sparkle updater startup failed")
        }
    }

    /// Triggers a user-initiated update check from the status menu.
    func checkForUpdates() {
        Log.updates.log("Manual update check requested")
        updaterController.checkForUpdates(nil)
    }
}
