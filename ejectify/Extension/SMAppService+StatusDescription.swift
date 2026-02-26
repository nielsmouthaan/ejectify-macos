//
//  SMAppService+StatusDescription.swift
//  Ejectify
//
//  Created by Codex on 26/02/2026.
//

import ServiceManagement

/// Converts ServiceManagement daemon status values into readable log labels.
extension SMAppService.Status {
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
