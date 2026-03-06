//
//  main.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation
import OSLog

/// Accepts helper XPC connections and exports a single privileged disk service instance.
final class PrivilegedHelperListenerDelegate: NSObject, NSXPCListenerDelegate {

    /// Exported XPC service handling privileged volume operations.
    private let service = PrivilegedDiskService()

    /// Configures and accepts incoming XPC connections for the privileged service.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: PrivilegedDiskServiceProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

/// Logger used during helper daemon bootstrap.
let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify.PrivilegedHelper", category: "PrivilegedHelperMain")

/// Listener delegate that exports the privileged disk service object.
let delegate = PrivilegedHelperListenerDelegate()

/// Mach service listener receiving app connections.
let listener = NSXPCListener(machServiceName: PrivilegedHelperConfiguration.machServiceName)
listener.delegate = delegate
listener.resume()

/// Posts a Darwin notification that the helper daemon has started.
func notifyHelperStarted() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let name = CFNotificationName(PrivilegedHelperConfiguration.helperStartedNotificationName as CFString)
    CFNotificationCenterPostNotification(center, name, nil, nil, true)
}

notifyHelperStarted()
logger.info("Privileged helper daemon started")
RunLoop.current.run()
