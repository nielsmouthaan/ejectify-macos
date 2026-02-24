//
//  DAReturn+Message.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 12/11/2021.
//

import Foundation

extension DAReturn {
    /// Returns the system-provided human-readable message for this status.
    var message: String {
        guard let message = mach_error_string(self) else {
            return "Unknown"
        }
        return String (cString: message)
    }

    /// Returns a stable symbolic name for common Disk Arbitration status values.
    var description: String {
        let status = Int(self)
        switch status {
        case kDAReturnSuccess:
            return "kDAReturnSuccess"
        case kDAReturnError:
            return "kDAReturnError"
        case kDAReturnBusy:
            return "kDAReturnBusy"
        case kDAReturnBadArgument:
            return "kDAReturnBadArgument"
        case kDAReturnExclusiveAccess:
            return "kDAReturnExclusiveAccess"
        case kDAReturnNoResources:
            return "kDAReturnNoResources"
        case kDAReturnNotFound:
            return "kDAReturnNotFound"
        case kDAReturnNotMounted:
            return "kDAReturnNotMounted"
        case kDAReturnNotPermitted:
            return "kDAReturnNotPermitted"
        case kDAReturnNotPrivileged:
            return "kDAReturnNotPrivileged"
        case kDAReturnNotReady:
            return "kDAReturnNotReady"
        case kDAReturnNotWritable:
            return "kDAReturnNotWritable"
        case kDAReturnUnsupported:
            return "kDAReturnUnsupported"
        default:
            return "Unknown"
        }
    }
}
