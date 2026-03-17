//
//  GlobalHotKeyController.swift
//  Ejectify
//
//  Created by Codex on 17/03/2026.
//

import Carbon
import Foundation
import OSLog

/// Registers and handles the app-wide keyboard shortcut for manual unmount-all.
final class GlobalHotKeyController {

    /// Carbon signature used to identify Ejectify's hotkey events.
    private static let hotKeySignature: OSType = 0x456A484B // ASCII for "EjHK" (Ejectify hotkey)

    /// Carbon identifier used to distinguish the unmount-all hotkey from other hotkeys.
    private static let hotKeyID: UInt32 = 1

    /// Event specification describing the hotkey-pressed callback this controller listens for.
    private static let hotKeyPressedEvent = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
    )

    /// C callback that forwards Carbon hotkey events back into the Swift controller instance.
    private static let hotKeyHandler: EventHandlerUPP = { _, eventRef, userData in
        guard let eventRef, let userData else {
            return noErr
        }

        let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
        controller.handleHotKeyPressed(eventRef)
        return noErr
    }

    /// Logger used for registration and trigger diagnostics.
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "GlobalHotKeyController")

    /// Action invoked when the registered global hotkey is pressed.
    private let onUnmountAll: @MainActor () -> Void

    /// Registered Carbon event handler reference for hotkey press callbacks.
    private var eventHandlerRef: EventHandlerRef?

    /// Registered Carbon hotkey reference while the shortcut is active.
    private var eventHotKeyRef: EventHotKeyRef?

    /// Returns whether the global hotkey registration is currently active.
    private(set) var isRegistered = false

    /// Creates the controller, installs its event handler, and attempts hotkey registration.
    init(onUnmountAll: @escaping @MainActor () -> Void) {
        self.onUnmountAll = onUnmountAll
        installHotKeyHandlerIfNeeded()
        registerHotKey()
    }

    /// Unregisters the hotkey and removes the Carbon event handler.
    deinit {
        unregisterHotKey()
        removeHotKeyHandler()
    }

    /// Installs the Carbon event handler used to receive global hotkey press events.
    private func installHotKeyHandlerIfNeeded() {
        guard eventHandlerRef == nil else {
            return
        }

        var eventHandlerRef: EventHandlerRef?
        var hotKeyPressedEvent = Self.hotKeyPressedEvent
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyHandler,
            1,
            &hotKeyPressedEvent,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard status == noErr, let eventHandlerRef else {
            logger.error("Failed to install global hotkey event handler: status=\(status, privacy: .public)")
            return
        }

        self.eventHandlerRef = eventHandlerRef
    }

    /// Attempts to register the fixed global `Control` + `Command` + `U` hotkey.
    private func registerHotKey() {
        guard eventHotKeyRef == nil else {
            return
        }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_U),
            UInt32(controlKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
            isRegistered = false
            logger.error("Failed to register global unmount-all hotkey (Control-Command-U): status=\(status, privacy: .public)")
            return
        }

        eventHotKeyRef = hotKeyRef
        isRegistered = true
        logger.info("Registered global unmount-all hotkey: Control-Command-U")
    }

    /// Unregisters the Carbon hotkey if it is currently active.
    private func unregisterHotKey() {
        guard let eventHotKeyRef else {
            isRegistered = false
            return
        }

        let status = UnregisterEventHotKey(eventHotKeyRef)
        if status == noErr {
            logger.info("Unregistered global unmount-all hotkey")
        } else {
            logger.error("Failed to unregister global unmount-all hotkey: status=\(status, privacy: .public)")
        }

        self.eventHotKeyRef = nil
        isRegistered = false
    }

    /// Removes the Carbon event handler when the controller is torn down.
    private func removeHotKeyHandler() {
        guard let eventHandlerRef else {
            return
        }

        let status = RemoveEventHandler(eventHandlerRef)
        if status != noErr {
            logger.error("Failed to remove global hotkey event handler: status=\(status, privacy: .public)")
        }

        self.eventHandlerRef = nil
    }

    /// Handles an incoming Carbon hotkey event and dispatches the shared unmount action.
    private func handleHotKeyPressed(_ eventRef: EventRef) {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else {
            logger.error("Failed to read global hotkey event payload: status=\(status, privacy: .public)")
            return
        }

        guard hotKeyID.signature == Self.hotKeySignature, hotKeyID.id == Self.hotKeyID else {
            return
        }

        logger.info("Global unmount-all hotkey pressed")
        Task { @MainActor [onUnmountAll] in
            onUnmountAll()
        }
    }
}
