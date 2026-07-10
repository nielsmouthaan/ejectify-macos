//
//  VolumeLogLabelFormatter.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 26/02/2026.
//

import Foundation

/// Builds privacy-safe volume correlation fields used by logs across app and helper targets.
enum VolumeLogLabelFormatter {

    /// Builds correlation fields from typed UUID metadata.
    static func label(uuid: UUID, bsdName: String) -> String {
        fields(uuidString: uuid.uuidString, bsdName: bsdName)
    }

    /// Builds correlation fields from optional UUID metadata.
    static func label(uuid: UUID?, bsdName: String) -> String {
        guard let uuid else {
            return fields(uuidString: nil, bsdName: bsdName)
        }

        return fields(uuidString: uuid.uuidString, bsdName: bsdName)
    }

    /// Builds correlation fields from raw UUID text and BSD name metadata.
    static func label(uuidString: String, bsdName: String) -> String {
        fields(uuidString: uuidString, bsdName: bsdName)
    }

    /// Formats normalized UUID and BSD values as concise log metadata.
    private static func fields(uuidString: String?, bsdName: String) -> String {
        let normalizedUUID = uuidString.flatMap { $0.isEmpty ? nil : $0 } ?? "none"
        let normalizedBSDName = bsdName.isEmpty ? "none" : bsdName
        return "volume_uuid=\(normalizedUUID); bsd_name=\(normalizedBSDName)"
    }
}
