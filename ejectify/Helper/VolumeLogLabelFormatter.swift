import Foundation

/// Builds canonical volume labels used by logs across app and helper targets.
enum VolumeLogLabelFormatter {
    static func label(name: String, uuid: UUID, bsdName: String) -> String {
        label(name: name, uuidString: uuid.uuidString, bsdName: bsdName)
    }

    static func label(name: String, uuidString: String, bsdName: String) -> String {
        "\(name) (UUID=\(uuidString), BSD=\(bsdName))"
    }
}
