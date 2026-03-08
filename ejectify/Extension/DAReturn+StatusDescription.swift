//
//  DAReturn+StatusDescription.swift
//  Ejectify
//
//  Created by Codex on 25/02/2026.
//

import Foundation
@preconcurrency import DiskArbitration

/// Returns the matching Disk Arbitration constant name for known status codes.
extension DAReturn {

    /// Stringified Disk Arbitration status constant name for logs.
    var statusDescription: String {
        switch self {
        case Int32(kDAReturnSuccess):
            return "kDAReturnSuccess"
        case Int32(kDAReturnError):
            return "kDAReturnError"
        case Int32(kDAReturnBusy):
            return "kDAReturnBusy"
        case Int32(kDAReturnBadArgument):
            return "kDAReturnBadArgument"
        case Int32(kDAReturnExclusiveAccess):
            return "kDAReturnExclusiveAccess"
        case Int32(kDAReturnNoResources):
            return "kDAReturnNoResources"
        case Int32(kDAReturnNotFound):
            return "kDAReturnNotFound"
        case Int32(kDAReturnNotMounted):
            return "kDAReturnNotMounted"
        case Int32(kDAReturnNotPermitted):
            return "kDAReturnNotPermitted"
        case Int32(kDAReturnNotPrivileged):
            return "kDAReturnNotPrivileged"
        case Int32(kDAReturnNotReady):
            return "kDAReturnNotReady"
        case Int32(kDAReturnNotWritable):
            return "kDAReturnNotWritable"
        case Int32(kDAReturnUnsupported):
            return "kDAReturnUnsupported"
        default:
            return "unknown(\(self))"
        }
    }

    /// Returns whether a failed automatic remount should be retried for this status.
    var shouldRetryAutomaticRemount: Bool {
        switch self {
        case Int32(kDAReturnSuccess):
            return false
        case Int32(kDAReturnBadArgument):
            return false
        case Int32(kDAReturnNotFound):
            return false
        case Int32(kDAReturnNotPermitted):
            return false
        case Int32(kDAReturnNotPrivileged):
            return false
        case Int32(kDAReturnNotWritable):
            return false
        case Int32(kDAReturnUnsupported):
            return false
        default:
            return true
        }
    }

}
