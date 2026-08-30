//
//  main.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation
import Security

/// Accepts helper XPC connections and exports a single privileged volume-operation service instance.
private final class PrivilegedHelperListenerDelegate: NSObject, NSXPCListenerDelegate {

    /// Exported XPC service handling privileged volume operations.
    private let service = PrivilegedDiskService()

    /// Configures and accepts incoming XPC connections for the privileged service.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard Self.isAuthorized(connection: newConnection) else {
            Log.privilegedHelper.error("Rejected unauthorized privileged helper XPC client")
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: PrivilegedDiskServiceProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }

    /// Validates the connecting process against Ejectify's designated signing identity.
    private static func isAuthorized(connection: NSXPCConnection) -> Bool {
        let attributes = [kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)] as CFDictionary
        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
              let guestCode else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            PrivilegedHelperConfiguration.appSigningRequirement as CFString,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement else {
            return false
        }

        return SecCodeCheckValidity(guestCode, [], requirement) == errSecSuccess
    }
}

/// Runs privileged helper daemon bootstrap.
private enum PrivilegedHelperMain {


    /// Starts the XPC listener and enters the helper run loop.
    static func run() {
        let delegate = PrivilegedHelperListenerDelegate()
        let listener = NSXPCListener(machServiceName: PrivilegedHelperConfiguration.machServiceName)
        listener.delegate = delegate
        listener.resume()
        notifyHelperStarted()
        Log.privilegedHelper.log("Privileged helper daemon started")
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
