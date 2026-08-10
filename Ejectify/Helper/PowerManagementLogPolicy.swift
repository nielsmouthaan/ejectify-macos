//
//  PowerManagementLogPolicy.swift
//  Ejectify
//

import Foundation

/// Defines which powerd messages diagnostics may include.
enum PowerManagementLogPolicy {

    /// Identifiers that make a powerd message relevant to Ejectify.
    static let ejectifyIdentifiers = [
        "Ejectify",
        "nl.nielsmouthaan.Ejectify"
    ]

    /// Returns whether a powerd message explicitly references Ejectify.
    static func includes(message: String) -> Bool {
        ejectifyIdentifiers.contains { identifier in
            message.localizedCaseInsensitiveContains(identifier)
        }
    }
}
