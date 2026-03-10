//
//  Volume.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import Foundation
import OSLog
@preconcurrency import DiskArbitration

/// Represents a mounted volume discovered from Disk Arbitration metadata.
final class Volume {

    /// Describes how a volume should be grouped in the menu.
    enum Category {
        case internalVolume
        case external
        case diskImage

        /// Default auto-(un)mount state used when no user override exists yet.
        var defaultEnabled: Bool {
            self != .diskImage
        }
    }

    /// Logger used for volume discovery and eligibility diagnostics.
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "Volume")

    /// Shared Disk Arbitration session retained for the lifetime of the app so asynchronous callbacks are delivered reliably.
    nonisolated(unsafe) private static let diskArbitrationSession: DASession? = {
        guard let session = DiskArbitrationVolumeOperator.DiskArbitrationSessionFactory.makeSession(dispatchQueue: DispatchQueue.main) else {
            logger.error("Failed to create Disk Arbitration session")
            return nil
        }
        return session
    }()

    /// Stable identifier used for persisted per-volume settings.
    let id: UUID

    /// Human-readable volume name displayed in UI and logs.
    let name: String

    /// Mounted volume URL used for notification correlation.
    let url: URL

    /// BSD disk identifier associated with this volume (for example `disk6s2`).
    let bsdName: String

    /// Category used for grouping volumes in the status-bar menu.
    let category: Category

    /// Canonical volume label for logs.
    var logLabel: String {
        VolumeLogLabelFormatter.label(name: name, uuid: id, bsdName: bsdName)
    }

    /// Tracks whether this volume should be managed automatically.
    /// Uses a category-based default when no explicit user preference exists.
    var enabled: Bool {
        get {
            let key = "volume." + id.uuidString
            guard let value = UserDefaults.standard.object(forKey: key) else {
                return category.defaultEnabled
            }

            if let boolValue = value as? Bool {
                return boolValue
            }

            return category.defaultEnabled
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "volume." + id.uuidString)
        }
    }

    /// Creates a managed volume model from resolved Disk Arbitration metadata.
    init(id: UUID, name: String, url: URL, bsdName: String, category: Category) {
        self.id = id
        self.name = name
        self.url = url
        self.bsdName = bsdName
        self.category = category
    }

    /// Returns currently mounted volumes that Ejectify can manage.
    static func mountedVolumes() -> [Volume] {
        guard let mountedVolumeURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:nil, options: []) else {
            logger.warning("Failed to enumerate mounted volumes from FileManager")
            return []
        }

        return mountedVolumeURLs
            .compactMap(Volume.fromURL(url:))
    }

    /// Resolves a mounted volume URL to a `Volume` model when eligible.
    static func fromURL(url: URL) -> Volume? {
        guard let session = Volume.diskArbitrationSession else {
            return nil
        }

        // Only continue when Disk Arbitration can resolve this URL to a disk object.
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else {
            return nil
        }

        // Read metadata required for volume eligibility checks.
        guard let diskInfo = DADiskCopyDescription(disk) as? [NSString: Any] else {
            return nil
        }

        // Require a stable volume UUID for identification and settings.
        guard let volumeUUID = DiskArbitrationVolumeOperator.VolumeUUIDResolver.volumeUUID(from: diskInfo) else {
            return nil
        }

        // Require a displayable volume name for UI/logging.
        guard let name = diskInfo[kDADiskDescriptionVolumeNameKey] as? String else {
            return nil
        }

        // Require a BSD disk identifier for fast resolve attempts during mount/unmount operations.
        guard let bsdName = diskInfo[kDADiskDescriptionMediaBSDNameKey] as? String else {
            return nil
        }

        // Require explicit ejectability metadata and keep only ejectable media.
        guard let isMediaEjectable = diskInfo[kDADiskDescriptionMediaEjectableKey] as? Bool else {
            return nil
        }
        if !isMediaEjectable {
            return nil
        }

        let category: Category
        if disk.isDiskImage() {
            category = .diskImage
        } else if let isInternalDevice = diskInfo[kDADiskDescriptionDeviceInternalKey] as? Bool, isInternalDevice {
            category = .internalVolume
        } else {
            category = .external
        }

        return Volume(id: volumeUUID, name: name, url: url, bsdName: bsdName, category: category)
    }

}
