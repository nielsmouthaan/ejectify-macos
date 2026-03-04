//
//  VolumeLogLabelFormatter.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 26/02/2026.
//

import Foundation

/// Builds canonical volume labels used by logs across app and helper targets.
enum VolumeLogLabelFormatter {

    /// Builds a canonical label from typed UUID metadata.
    static func label(name: String, uuid: UUID, bsdName: String) -> String {
        label(name: name, uuidString: uuid.uuidString, bsdName: bsdName)
    }

    /// Builds a canonical label from raw UUID text and BSD name metadata.
    static func label(name: String, uuidString: String, bsdName: String) -> String {
        "\(name) (UUID=\(uuidString), BSD=\(bsdName))"
    }
}
