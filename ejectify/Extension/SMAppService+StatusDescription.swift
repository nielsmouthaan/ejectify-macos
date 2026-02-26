//
//  SMAppService+StatusDescription.swift
//  Ejectify
//
//  Created by Codex on 26/02/2026.
//

import ServiceManagement

/// Converts Service Management daemon status values into readable descriptions.
extension SMAppService.Status {
    var statusDescription: String {
        switch self {
        case .notRegistered:
            return "service is not registered or was unregistered"
        case .enabled:
            return "service is registered and eligible to run"
        case .requiresApproval:
            return "service is registered but requires user approval in System Settings"
        case .notFound:
            return "service could not be found due to an error"
        @unknown default:
            return "unknown Service Management status \(self.rawValue)"
        }
    }
}
