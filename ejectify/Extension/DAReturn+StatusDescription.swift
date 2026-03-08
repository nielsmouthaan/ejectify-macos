//
//  DAReturn+StatusDescription.swift
//  Ejectify
//
//  Created by Codex on 25/02/2026.
//

import Foundation
import Darwin
@preconcurrency import DiskArbitration

/// Returns the matching Disk Arbitration constant name for known status codes.
extension DAReturn {

    /// Mach error layout constants used to decode system/subsystem/code fields.
    private enum MachErrorEncoding {
        static let systemShift: UInt32 = 26
        static let subsystemShift: UInt32 = 14
        static let systemMask: UInt32 = 0x3F
        static let subsystemMask: UInt32 = 0xFFF
        static let codeMask: UInt32 = 0x3FFF

        static let kernSystem: UInt32 = 0
        static let unixSubsystem: UInt32 = 3
    }

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
            if let description = unixErrorDescription {
                return "Unknown (\(self): \(description))"
            }

            return "Unknown (\(self))"
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

    /// Decodes one Mach error value into individual system/subsystem/code fields.
    private var machErrorComponents: (system: UInt32, subsystem: UInt32, code: UInt32) {
        let rawValue = UInt32(bitPattern: self)

        let system = (rawValue >> MachErrorEncoding.systemShift) & MachErrorEncoding.systemMask
        let subsystem = (rawValue >> MachErrorEncoding.subsystemShift) & MachErrorEncoding.subsystemMask
        let code = rawValue & MachErrorEncoding.codeMask

        return (system: system, subsystem: subsystem, code: code)
    }

    /// Decodes a UNIX-encoded Mach error (`unix_err(errno)`) into a dynamic `strerror` message.
    private var unixErrorDescription: String? {
        let components = machErrorComponents

        // `unix_err(errno)` is encoded as err_kern (system 0), subsystem 3, and errno in low 14 bits.
        guard components.system == MachErrorEncoding.kernSystem,
              components.subsystem == MachErrorEncoding.unixSubsystem else {
            return nil
        }

        guard let messagePointer = strerror(Int32(components.code)) else {
            return nil
        }

        let message = String(cString: messagePointer)
        return message.isEmpty ? nil : message
    }
}
