//
//  main.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation
import OSLog

/// Accepts helper XPC connections and exports a single privileged volume-operation service instance.
private final class PrivilegedHelperListenerDelegate: NSObject, NSXPCListenerDelegate {

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

/// Runs privileged helper daemon bootstrap.
private enum PrivilegedHelperMain {

    /// Logger used during helper daemon bootstrap.
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: PrivilegedHelperMain.self)
    )

    /// Starts the XPC listener and enters the helper run loop.
    static func run() {
        let delegate = PrivilegedHelperListenerDelegate()
        let listener = NSXPCListener(machServiceName: PrivilegedHelperConfiguration.machServiceName)
        listener.delegate = delegate
        listener.resume()
        notifyHelperStarted()
        Self.logger.log("Privileged helper daemon started")
        RunLoop.current.run()
    }

    /// Posts a Darwin notification that the helper daemon has started.
    private static func notifyHelperStarted() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(PrivilegedHelperConfiguration.helperStartedNotificationName as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
    }
}

PrivilegedHelperMain.run()
