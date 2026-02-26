//
//  DAReturn+StatusDescription.swift
//  Ejectify
//
//  Created by Codex on 25/02/2026.
//

import Foundation
@preconcurrency import DiskArbitration

/// Converts Disk Arbitration return codes into readable descriptions.
extension DAReturn {
    var statusDescription: String {
        switch self {
        case Int32(kDAReturnSuccess):
            return "operation completed successfully"
        case Int32(kDAReturnError):
            return "generic Disk Arbitration error"
        case Int32(kDAReturnBusy):
            return "resource is busy"
        case Int32(kDAReturnBadArgument):
            return "invalid argument was supplied"
        case Int32(kDAReturnExclusiveAccess):
            return "exclusive access conflict"
        case Int32(kDAReturnNoResources):
            return "insufficient resources to complete the operation"
        case Int32(kDAReturnNotFound):
            return "requested disk or resource was not found"
        case Int32(kDAReturnNotMounted):
            return "volume is not currently mounted"
        case Int32(kDAReturnNotPermitted):
            return "operation is not permitted"
        case Int32(kDAReturnNotPrivileged):
            return "operation requires elevated privileges"
        case Int32(kDAReturnNotReady):
            return "disk is not ready"
        case Int32(kDAReturnNotWritable):
            return "volume is not writable"
        case Int32(kDAReturnUnsupported):
            return "operation is not supported for this disk"
        default:
            return String(
                format: "unknown Disk Arbitration status, code: %d / 0x%08X",
                self,
                UInt32(bitPattern: self)
            )
        }
    }
}
