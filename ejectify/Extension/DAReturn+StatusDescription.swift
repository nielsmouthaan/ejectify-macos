//
//  DAReturn+StatusDescription.swift
//  Ejectify
//
//  Created by Codex on 25/02/2026.
//

import Foundation
@preconcurrency import DiskArbitration

/// Converts Disk Arbitration return codes into readable log labels.
extension DAReturn {
    var statusDescription: String {
        switch self {
        case Int32(kDAReturnSuccess):
            return "success"
        case Int32(kDAReturnError):
            return "error"
        case Int32(kDAReturnBusy):
            return "busy"
        case Int32(kDAReturnBadArgument):
            return "badArgument"
        case Int32(kDAReturnExclusiveAccess):
            return "exclusiveAccess"
        case Int32(kDAReturnNoResources):
            return "noResources"
        case Int32(kDAReturnNotFound):
            return "notFound"
        case Int32(kDAReturnNotMounted):
            return "notMounted"
        case Int32(kDAReturnNotPermitted):
            return "notPermitted"
        case Int32(kDAReturnNotPrivileged):
            return "notPrivileged"
        case Int32(kDAReturnNotReady):
            return "notReady"
        case Int32(kDAReturnNotWritable):
            return "notWritable"
        case Int32(kDAReturnUnsupported):
            return "unsupported"
        default:
            return "unknown(\(Int(self)))"
        }
    }
}
