//
//  PrivilegedDiskService.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Foundation
import OSLog

final class PrivilegedDiskService: NSObject, PrivilegedDiskServiceProtocol {
    
    private let logger = Logger(subsystem: "nl.nielsmouthaan.Ejectify", category: "PrivilegedDiskService")

    func mount(volumeUUID: NSUUID, volumeName: String, bsdName: String, withReply reply: @escaping (Bool, String?) -> Void) {
        perform(operation: .mount, volumeUUID: volumeUUID as UUID, volumeName: volumeName, bsdName: bsdName, reply: reply)
    }

    func unmount(volumeUUID: NSUUID, volumeName: String, bsdName: String, force: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        perform(operation: .unmount(force: force), volumeUUID: volumeUUID as UUID, volumeName: volumeName, bsdName: bsdName, reply: reply)
    }

    /// Executes a shared Disk Arbitration operation and returns the result through XPC.
    private func perform(
        operation: DiskArbitrationVolumeOperator.Operation,
        volumeUUID: UUID,
        volumeName: String,
        bsdName: String,
        reply: @escaping (Bool, String?) -> Void
    ) {
        let result = DiskArbitrationVolumeOperator.perform(volumeUUID: volumeUUID, bsdName: bsdName, operation: operation)

        if let errorMessage = result.1, !result.0 {
            logger.error("Privileged \(operation.operationName, privacy: .public) failed for \(volumeName, privacy: .public): \(errorMessage, privacy: .public)")
        }

        reply(result.0, result.1)
    }
}
