//
//  Volume.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import Foundation
@preconcurrency import DiskArbitration

/// Notification posted after Disk Arbitration reports volume topology changes.
extension Notification.Name {
    static let volumeDiscoveryDidChange = Notification.Name("nl.nielsmouthaan.Ejectify.VolumeDiscovery.didChange")
}

/// Represents a mounted volume discovered from Disk Arbitration metadata.
final class Volume {

    /// Describes how a volume should be grouped in the menu.
    enum Category: Sendable {
        case internalVolume
        case external
        case diskImage

        /// Default auto-(un)mount state used when no user override exists yet.
        var defaultEnabled: Bool {
            self != .diskImage
        }
    }


    /// Shared Disk Arbitration session retained for the lifetime of the app so asynchronous callbacks are delivered reliably.
    nonisolated(unsafe) private static let diskArbitrationSession: DASession? = {
        guard let session = DiskutilOperator.DiskArbitrationSessionFactory.makeSession(dispatchQueue: DispatchQueue.main) else {
            Log.volumeOperations.error("Failed to create Disk Arbitration session")
            return nil
        }
        return session
    }()

    /// Tracks one-time Disk Arbitration callback registration.
    nonisolated(unsafe) private static var discoveryStarted = false

    /// Coalesces bursts of topology callbacks before consumers rescan mounted volumes.
    nonisolated(unsafe) private static var pendingDiscoveryNotification: DispatchWorkItem?

    /// Receives appeared and disappeared media notifications.
    private static let diskChangedCallback: DADiskAppearedCallback = { _, _ in
        scheduleDiscoveryNotification()
    }

    /// Receives mount path and volume name changes.
    private static let diskDescriptionChangedCallback: DADiskDescriptionChangedCallback = { _, _, _ in
        scheduleDiscoveryNotification()
    }

    /// Identifier used for persisted per-volume settings, falling back to best-effort metadata when no identity UUID exists.
    let id: String

    /// Disk Arbitration UUID used to revalidate the live BSD target when available.
    let identityUUID: UUID?

    /// Human-readable volume name displayed in UI and logs.
    let name: String

    /// Mounted volume URL used for notification correlation.
    let url: URL

    /// BSD disk identifier associated with this volume (for example `disk6s2`).
    let bsdName: String

    /// Category used for grouping volumes in the status-bar menu.
    let category: Category

    /// Indicates whether Disk Arbitration reports the volume media as encrypted.
    let isEncrypted: Bool

    /// Indicates whether Disk Arbitration reports the volume kind as APFS.
    let isAPFS: Bool

    /// Privacy-safe volume correlation fields for logs.
    var logLabel: String {
        VolumeLogLabelFormatter.label(uuid: identityUUID, bsdName: bsdName)
    }

    /// Tracks whether this volume should be managed automatically, using a category-based default when no explicit user preference exists.
    var enabled: Bool {
        get {
            let key = "volume." + id
            guard let value = UserDefaults.standard.object(forKey: key) else {
                return category.defaultEnabled
            }

            if let boolValue = value as? Bool {
                return boolValue
            }

            return category.defaultEnabled
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "volume." + id)
        }
    }

    /// Creates a managed volume model from resolved Disk Arbitration metadata.
    init(
        id: String,
        identityUUID: UUID?,
        name: String,
        url: URL,
        bsdName: String,
        category: Category,
        isEncrypted: Bool,
        isAPFS: Bool
    ) {
        self.id = id
        self.identityUUID = identityUUID
        self.name = name
        self.url = url
        self.bsdName = bsdName
        self.category = category
        self.isEncrypted = isEncrypted
        self.isAPFS = isAPFS
    }

    /// Returns currently mounted volumes that Ejectify can manage.
    static func mountedVolumes() -> [Volume] {
        guard let mountedVolumeURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:nil, options: []) else {
            Log.volumeOperations.warning("Failed to enumerate mounted volumes from FileManager")
            return []
        }

        return mountedVolumeURLs
            .compactMap(Volume.fromURL(url:))
    }

    /// Starts Disk Arbitration discovery notifications once for the application lifetime.
    static func startDiscovery() {
        guard !discoveryStarted, let session = diskArbitrationSession else {
            return
        }
        discoveryStarted = true
        DARegisterDiskAppearedCallback(session, nil, diskChangedCallback, nil)
        DARegisterDiskDisappearedCallback(session, nil, diskChangedCallback, nil)
        let watchedKeys = [
            kDADiskDescriptionVolumePathKey,
            kDADiskDescriptionVolumeNameKey
        ] as CFArray
        DARegisterDiskDescriptionChangedCallback(session, nil, watchedKeys, diskDescriptionChangedCallback, nil)
        Log.volumeOperations.log("Disk Arbitration volume discovery started")
    }

    /// Posts one coalesced inventory notification on the main queue.
    private static func scheduleDiscoveryNotification() {
        pendingDiscoveryNotification?.cancel()
        let workItem = DispatchWorkItem {
            NotificationCenter.default.post(name: .volumeDiscoveryDidChange, object: nil)
        }
        pendingDiscoveryNotification = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
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

        // Prefer Disk Arbitration metadata, but fall back to the mount point name for volumes whose filesystem label is empty.
        guard let name = displayName(for: url, diskInfo: diskInfo) else {
            return nil
        }

        // Require a BSD disk identifier for fast resolve attempts during mount/unmount operations.
        guard let bsdName = diskInfo[kDADiskDescriptionMediaBSDNameKey] as? String else {
            return nil
        }

        let identityUUID = DiskutilOperator.IdentityUUIDResolver.identityUUID(from: diskInfo)
        let id = identityUUID?.uuidString ?? fallbackID(name: name, bsdName: bsdName, diskInfo: diskInfo)

        let category: Category
        if disk.isDiskImage() {
            category = .diskImage
        } else if let isInternalDevice = diskInfo[kDADiskDescriptionDeviceInternalKey] as? Bool, isInternalDevice {
            category = .internalVolume
        } else {
            category = .external
        }

        let isMediaEjectable = (diskInfo[kDADiskDescriptionMediaEjectableKey] as? Bool) ?? false
        let isEncrypted = (diskInfo[kDADiskDescriptionMediaEncryptedKey] as? Bool) ?? false
        let isAPFS = (diskInfo[kDADiskDescriptionVolumeKindKey] as? String) == "apfs"

        // Include disk images, macOS-ejectable media, and external devices such as Thunderbolt SSDs whose media is not classified as ejectable but can still be unmounted.
        guard category == .diskImage || isMediaEjectable || category == .external else {
            return nil
        }

        if identityUUID == nil {
            Log.volumeOperations.info("Managing volume without Disk Arbitration UUID; \(VolumeLogLabelFormatter.label(uuid: nil, bsdName: bsdName))")
        }

        return Volume(
            id: id,
            identityUUID: identityUUID,
            name: name,
            url: url,
            bsdName: bsdName,
            category: category,
            isEncrypted: isEncrypted,
            isAPFS: isAPFS
        )
    }

    /// Returns the best user-visible name for a mounted volume.
    static func displayName(for url: URL, diskInfo: [NSString: Any]) -> String? {
        if let volumeName = diskInfo[kDADiskDescriptionVolumeNameKey] as? String,
           let name = normalizedName(volumeName) {
            return name
        }

        if let resourceName = url.resourceName(for: .volumeLocalizedNameKey) {
            return resourceName
        }

        if let resourceName = url.resourceName(for: .volumeNameKey) {
            return resourceName
        }

        if let displayName = normalizedName(FileManager.default.displayName(atPath: url.path)) {
            return displayName
        }

        return normalizedName(url.lastPathComponent)
    }

    /// Trims unusable names from filesystem and metadata APIs.
    private static func normalizedName(_ name: String) -> String? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedName.isEmpty ? nil : normalizedName
    }

    /// Builds a best-effort identifier for volumes whose filesystems do not expose Disk Arbitration UUID metadata.
    private static func fallbackID(name: String, bsdName: String, diskInfo: [NSString: Any]) -> String {
        let identityComponents = [
            "fallback",
            diskInfo[kDADiskDescriptionDeviceVendorKey] as? String,
            diskInfo[kDADiskDescriptionDeviceModelKey] as? String,
            diskInfo[kDADiskDescriptionMediaNameKey] as? String,
            diskInfo[kDADiskDescriptionMediaSizeKey].map { String(describing: $0) },
            diskInfo[kDADiskDescriptionVolumeKindKey] as? String,
            name,
            bsdName
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return identityComponents.joined(separator: "|")
    }

}

private extension URL {

    /// Returns a non-empty string resource value for this URL.
    func resourceName(for key: URLResourceKey) -> String? {
        guard let value = try? resourceValues(forKeys: [key]) else {
            return nil
        }

        let name: String?
        switch key {
        case .volumeLocalizedNameKey:
            name = value.volumeLocalizedName
        case .volumeNameKey:
            name = value.volumeName
        default:
            name = nil
        }

        guard let name else {
            return nil
        }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedName.isEmpty ? nil : normalizedName
    }
}
