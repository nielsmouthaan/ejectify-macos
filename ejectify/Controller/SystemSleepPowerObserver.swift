//
//  SystemSleepPowerObserver.swift
//  Ejectify
//

import IOKit
import IOKit.pwr_mgt
import OSLog

/// Bridges low-level IOKit power callbacks to a main-actor handler.
final class SystemSleepPowerObserver {

    /// Semantic representation of IOKit power messages consumed by `ActivityController`.
    enum Event {
        case systemWillSleep(token: Int)
        case systemHasPoweredOn
    }

    /// Main-actor callback invoked for translated sleep/wake events.
    private let onPowerMessage: @MainActor (Event) -> Void

    /// Logger used for power notification registration and lifecycle diagnostics.
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "SystemSleepPowerObserver")

    /// IOKit root power connection used to acknowledge sleep transitions.
    private var rootPort: io_connect_t = 0

    /// Notification port that delivers power messages to the run loop.
    private var notificationPort: IONotificationPortRef?

    /// Registered notifier token returned by `IORegisterForSystemPower`.
    private var notifierObject: io_object_t = 0

    /// Run loop source receiving callbacks from the notification port.
    private var runLoopSource: CFRunLoopSource?

    /// IOMessage.h constant for the "system will sleep" callback.
    private static let systemWillSleepMessage: natural_t = natural_t(EjectifyIOMessageSystemWillSleep())

    /// IOMessage.h constant for the "system has powered on" callback.
    private static let systemHasPoweredOnMessage: natural_t = natural_t(EjectifyIOMessageSystemHasPoweredOn())

    /// Creates an observer that forwards translated power events to the supplied handler.
    init(onPowerMessage: @escaping @MainActor (Event) -> Void) {
        self.onPowerMessage = onPowerMessage
    }

    /// Registers for system power notifications and attaches the callback source to the main run loop.
    @discardableResult
    func start() -> Bool {
        guard rootPort == 0 else {
            return true
        }

        var localNotifierObject: io_object_t = 0
        var localNotificationPort: IONotificationPortRef?
        let refCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let localRootPort = IORegisterForSystemPower(refCon, &localNotificationPort, Self.powerCallback, &localNotifierObject)
        guard localRootPort != 0, let localNotificationPort else {
            logger.error("Failed to register for system power notifications")
            return false
        }

        guard let runLoopSource = IONotificationPortGetRunLoopSource(localNotificationPort)?.takeUnretainedValue() else {
            logger.error("Failed to attach system power callback run loop source")
            if localNotifierObject != 0 {
                IOObjectRelease(localNotifierObject)
            }
            IONotificationPortDestroy(localNotificationPort)
            IOServiceClose(localRootPort)
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.commonModes)
        self.rootPort = localRootPort
        self.notificationPort = localNotificationPort
        self.notifierObject = localNotifierObject
        self.runLoopSource = runLoopSource
        logger.info("System power monitoring enabled")
        return true
    }

    /// Stops system power monitoring and cleans up all IOKit resources.
    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.commonModes)
            self.runLoopSource = nil
        }

        if notifierObject != 0 {
            IOObjectRelease(notifierObject)
            notifierObject = 0
        }

        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }

        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }
    }

    /// Signals to powerd that sleep may proceed for the given token.
    func allowPowerChange(for token: Int) {
        guard rootPort != 0 else {
            return
        }
        IOAllowPowerChange(rootPort, token)
    }

    /// Raw IOKit callback that forwards incoming messages to an observer instance.
    private static let powerCallback: IOServiceInterestCallback = { refCon, _, messageType, messageArgument in
        guard let refCon else {
            return
        }

        let observer = Unmanaged<SystemSleepPowerObserver>.fromOpaque(refCon).takeUnretainedValue()
        let token = Int(bitPattern: messageArgument)
        observer.forwardPowerMessage(messageType: messageType, token: token)
    }

    /// Converts a raw IOKit callback payload into a typed power event.
    private static func powerEvent(for messageType: natural_t, token: Int) -> Event? {
        switch messageType {
        case systemWillSleepMessage:
            return .systemWillSleep(token: token)
        case systemHasPoweredOnMessage:
            return .systemHasPoweredOn
        default:
            return nil
        }
    }

    /// Forwards callback payload to the configured handler on the main actor.
    private func forwardPowerMessage(messageType: natural_t, token: Int) {
        guard let powerEvent = Self.powerEvent(for: messageType, token: token) else {
            return
        }
        let handler = onPowerMessage
        Task { @MainActor in
            handler(powerEvent)
        }
    }

    /// Ensures all IOKit registrations are released when the observer is deallocated.
    deinit {
        stop()
    }
}
