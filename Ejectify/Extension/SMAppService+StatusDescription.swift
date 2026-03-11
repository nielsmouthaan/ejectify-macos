//
//  SMAppService+StatusDescription.swift
//  Ejectify
//
//  Created by Codex on 26/02/2026.
//

import ServiceManagement

/// Returns the enum case name for each Service Management daemon status.
extension SMAppService.Status {

    /// Stringified status case for concise logging and diagnostics.
    var statusDescription: String {
        switch self {
        case .notRegistered:
            return "notRegistered"
        case .enabled:
            return "enabled"
        case .requiresApproval:
            return "requiresApproval"
        case .notFound:
            return "notFound"
        @unknown default:
            return "unknown(\(self.rawValue))"
        }
    }
}
