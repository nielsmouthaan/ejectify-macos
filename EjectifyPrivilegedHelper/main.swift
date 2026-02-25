//
//  main.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation
import OSLog

final class PrivilegedHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    
    private let service = PrivilegedDiskService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: PrivilegedDiskServiceProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

let logger = Logger(subsystem: "nl.nielsmouthaan.Ejectify", category: "PrivilegedHelperMain")
let delegate = PrivilegedHelperListenerDelegate()
let listener = NSXPCListener(machServiceName: PrivilegedHelperConfiguration.machServiceName)
listener.delegate = delegate
listener.resume()
logger.info("Privileged helper daemon started")
RunLoop.current.run()
