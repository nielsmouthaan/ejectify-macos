//
//  DiagnosticsReportController.swift
//  Ejectify
//
//  Created by Codex on 22/06/2026.
//

import AppKit
import Diagnostics
@preconcurrency import DiskArbitration
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Presents diagnostics export UI and writes generated reports to user-selected locations.
@MainActor
final class DiagnosticsReportController {

    /// Shows a save panel, generates a diagnostics report, and writes it to the selected URL.
    func saveDiagnosticsReport() {
        guard let targetURL = makeSavePanel().runModalResultURL else {
            return
        }

        let snapshot = EjectifyDiagnosticsSnapshot.make()
        let progressAlert = DiagnosticsReportProgressAlert()
        progressAlert.run(targetURL: targetURL, snapshot: snapshot)
    }

    /// Creates the save panel configured for HTML diagnostics reports.
    private func makeSavePanel() -> NSSavePanel {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.html]
        savePanel.canCreateDirectories = true
        savePanel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        savePanel.nameFieldStringValue = "Ejectify-Diagnostics-Report.html"
        savePanel.title = String(localized: "Generate Diagnostics Report")
        savePanel.message = String(localized: "Save the diagnostics report to the chosen location.")
        return savePanel
    }

    /// Reveals a successfully saved diagnostics report in Finder.
    fileprivate static func revealReport(at url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Shows native progress UI while a diagnostics report is generated.
@MainActor
private final class DiagnosticsReportProgressAlert {

    /// Current report generation state backing the alert button behavior.
    private enum State {
        case generating(Task<URL, Error>)
        case generated(URL)
        case failed
    }

    /// Native alert used as the progress window.
    private let alert = NSAlert()

    /// Indeterminate progress indicator for the unified-log collection work.
    private let progressIndicator = NSProgressIndicator(
        frame: NSRect(x: 0, y: 0, width: 240, height: 20)
    )

    /// Current operation state.
    private var state: State?

    /// Observes the detached generation task and updates the alert when it finishes.
    private var completionObserver: Task<Void, Never>?

    /// Generates the report while showing a native cancelable progress alert.
    func run(targetURL: URL, snapshot: EjectifyDiagnosticsSnapshot) {
        configureForProgress()

        let generationTask = Task.detached(priority: .userInitiated) { [snapshot, targetURL] in
            let report = try await EjectifyDiagnosticsReportFactory.make(
                filename: targetURL.lastPathComponent,
                snapshot: snapshot
            )
            try Task.checkCancellation()
            try report.data.write(to: targetURL, options: .atomic)
            try Task.checkCancellation()
            return targetURL
        }
        state = .generating(generationTask)

        completionObserver = Task { [weak self] in
            do {
                let reportURL = try await generationTask.value
                guard !Task.isCancelled else {
                    return
                }

                self?.markGenerated(at: reportURL)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                self?.markFailed(failureDescription: error.localizedDescription)
            }
        }

        let response = alert.runModal()
        completionObserver?.cancel()
        handle(response: response)
    }

    /// Configures the alert for active report generation.
    private func configureForProgress() {
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Generating Diagnostics Report")
        alert.informativeText = String(localized: "Ejectify is collecting relevant log events for the last 24 hours. This can take a while.")
        alert.addButton(withTitle: String(localized: "Cancel"))

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.isHidden = false
        progressIndicator.usesThreadedAnimation = true
        progressIndicator.startAnimation(nil)
        alert.accessoryView = progressIndicator
    }

    /// Updates the alert after the report is written successfully.
    private func markGenerated(at url: URL) {
        state = .generated(url)
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        alert.accessoryView = nil
        alert.messageText = String(localized: "Diagnostics Report Generated")
        alert.informativeText = String(localized: "The diagnostics report has been generated. Click Reveal in Finder to locate it in Finder.")
        alert.buttons.first?.title = String(localized: "Reveal in Finder")
    }

    /// Updates the alert when report generation or writing fails.
    private func markFailed(failureDescription: String) {
        state = .failed
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        alert.accessoryView = nil
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Could not save diagnostics report.")
        alert.informativeText = failureDescription
        alert.buttons.first?.title = String(localized: "OK")
    }

    /// Handles the alert button after the modal session closes.
    private func handle(response: NSApplication.ModalResponse) {
        guard response == .alertFirstButtonReturn else {
            return
        }

        switch state {
        case .generating(let generationTask):
            generationTask.cancel()
        case .generated(let url):
            DiagnosticsReportController.revealReport(at: url)
        case .failed, nil:
            break
        }
    }
}

/// Captures app state needed for diagnostics report generation.
private struct EjectifyDiagnosticsSnapshot: Sendable {

    /// Timestamp at which the diagnostics snapshot was created.
    let generatedAt: Date

    /// Current launch-at-login preference.
    let launchAtLogin: Bool

    /// Current automatic unmount trigger.
    let unmountWhen: String

    /// Current force-unmount preference.
    let forceUnmount: Bool

    /// Current privileged helper daemon status.
    let privilegedHelperStatus: String

    /// Current volume operation routing mode.
    let volumeOperationMode: String

    /// Whether the privileged helper is currently used for volume operations.
    let isUsingPrivilegedHelper: Bool

    /// Whether Disk Arbitration eject notifications are currently muted.
    let areEjectNotificationsMuted: Bool

    /// Whether the global unmount-all hotkey is currently registered.
    let isUnmountAllHotKeyRegistered: Bool

    /// Mounted volumes managed by Ejectify at snapshot time.
    let volumes: [EjectifyVolumeDiagnosticsSnapshot]

    /// Raw mounted filesystem URLs and Disk Arbitration metadata before Ejectify eligibility filtering.
    let mountedVolumeDiscovery: [MountedVolumeDiscoverySnapshot]

    /// Creates a snapshot from the current app state.
    @MainActor
    static func make() -> Self {
        let volumes = Volume.mountedVolumes().map(EjectifyVolumeDiagnosticsSnapshot.init(volume:))
        let mountedVolumeDiscovery = MountedVolumeDiscoverySnapshot.makeAll()
        return Self(
            generatedAt: Date(),
            launchAtLogin: Preference.launchAtLogin,
            unmountWhen: Preference.unmountWhen.rawValue,
            forceUnmount: Preference.forceUnmount,
            privilegedHelperStatus: PrivilegedHelperLifecycleManager.shared.daemonStatus.statusDescription,
            volumeOperationMode: VolumeOperationRouter.shared.executionMode.rawValue,
            isUsingPrivilegedHelper: VolumeOperationRouter.shared.isUsingPrivilegedHelper,
            areEjectNotificationsMuted: Self.areEjectNotificationsMuted(),
            isUnmountAllHotKeyRegistered: AppDelegate.shared.isUnmountAllHotKeyRegistered,
            volumes: volumes,
            mountedVolumeDiscovery: mountedVolumeDiscovery
        )
    }

    /// Returns whether the Disk Arbitration notification mute setting is enabled.
    private static func areEjectNotificationsMuted() -> Bool {
        guard
            let preferences = NSDictionary(contentsOfFile: PrivilegedHelperConfiguration.diskArbitrationPreferencesPath),
            let rawValue = preferences[PrivilegedHelperConfiguration.disableEjectNotificationKey]
        else {
            return false
        }

        if let boolValue = rawValue as? Bool {
            return boolValue
        }

        if let numberValue = rawValue as? NSNumber {
            return numberValue.boolValue
        }

        if let stringValue = rawValue as? String {
            return NSString(string: stringValue).boolValue
        }

        return false
    }
}

/// Captures raw mounted volume metadata before Ejectify applies eligibility filters.
private struct MountedVolumeDiscoverySnapshot: Sendable {

    /// Mounted filesystem path reported by `FileManager`.
    let mountPath: String

    /// Disk Arbitration volume name, when available.
    let volumeName: String

    /// Disk Arbitration BSD disk identifier, when available.
    let bsdName: String

    /// Disk Arbitration volume kind, when available.
    let volumeKind: String

    /// Best available Disk Arbitration UUID, preferring the volume UUID over the media UUID.
    let uuid: String

    /// Disk Arbitration internal-device flag, when available.
    let internalDevice: String

    /// Disk Arbitration ejectable-media flag, when available.
    let mediaEjectable: String

    /// Disk Arbitration removable-media flag, when available.
    let mediaRemovable: String

    /// Creates raw discovery rows for every mounted filesystem URL reported by macOS.
    static func makeAll() -> [Self] {
        guard let mountedVolumeURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) else {
            return []
        }

        let session = DiskArbitrationVolumeOperator.DiskArbitrationSessionFactory.makeSession(dispatchQueue: DispatchQueue.main)
        return mountedVolumeURLs.map { Self(url: $0, session: session) }
    }

    /// Creates one raw discovery row for a mounted filesystem URL.
    private init(url: URL, session: DASession?) {
        mountPath = url.path

        guard let session,
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else {
            volumeName = Self.unavailable
            bsdName = Self.unavailable
            volumeKind = Self.unavailable
            uuid = Self.unavailable
            internalDevice = Self.unavailable
            mediaEjectable = Self.unavailable
            mediaRemovable = Self.unavailable
            return
        }

        guard let diskInfo = DADiskCopyDescription(disk) as? [NSString: Any] else {
            volumeName = Self.unavailable
            bsdName = Self.unavailable
            volumeKind = Self.unavailable
            uuid = Self.unavailable
            internalDevice = Self.unavailable
            mediaEjectable = Self.unavailable
            mediaRemovable = Self.unavailable
            return
        }

        volumeName = Self.stringValue(for: kDADiskDescriptionVolumeNameKey, in: diskInfo)
        bsdName = Self.stringValue(for: kDADiskDescriptionMediaBSDNameKey, in: diskInfo)
        volumeKind = Self.stringValue(for: kDADiskDescriptionVolumeKindKey, in: diskInfo)
        uuid = Self.bestAvailableUUID(in: diskInfo)
        internalDevice = Self.boolValue(for: kDADiskDescriptionDeviceInternalKey, in: diskInfo)
        mediaEjectable = Self.boolValue(for: kDADiskDescriptionMediaEjectableKey, in: diskInfo)
        mediaRemovable = Self.boolValue(for: kDADiskDescriptionMediaRemovableKey, in: diskInfo)
    }

    /// Placeholder used when a Disk Arbitration value is absent.
    private static let unavailable = "-"

    /// Returns a printable string value for a Disk Arbitration description key.
    private static func stringValue(for key: CFString, in diskInfo: [NSString: Any]) -> String {
        guard let value = diskInfo[key] else {
            return unavailable
        }

        if let stringValue = value as? String, !stringValue.isEmpty {
            return stringValue
        }

        let description = String(describing: value)
        return description.isEmpty ? unavailable : description
    }

    /// Returns a printable UUID value for a Disk Arbitration description key.
    private static func uuidValue(for key: CFString, in diskInfo: [NSString: Any]) -> String {
        guard let value = diskInfo[key] else {
            return unavailable
        }

        if let uuid = value as? UUID {
            return uuid.uuidString
        }

        if let uuidString = value as? String, !uuidString.isEmpty {
            return uuidString
        }

        let rawCoreFoundationValue = value as CFTypeRef
        if CFGetTypeID(rawCoreFoundationValue) == CFUUIDGetTypeID() {
            let coreFoundationUUID = rawCoreFoundationValue as! CFUUID
            return CFUUIDCreateString(kCFAllocatorDefault, coreFoundationUUID) as String
        }

        return stringValue(for: key, in: diskInfo)
    }

    /// Returns the same UUID value Ejectify uses when it can identify a volume through Disk Arbitration.
    private static func bestAvailableUUID(in diskInfo: [NSString: Any]) -> String {
        let volumeUUID = uuidValue(for: kDADiskDescriptionVolumeUUIDKey, in: diskInfo)
        if volumeUUID != unavailable {
            return volumeUUID
        }

        return uuidValue(for: kDADiskDescriptionMediaUUIDKey, in: diskInfo)
    }

    /// Returns a printable Boolean value for a Disk Arbitration description key.
    private static func boolValue(for key: CFString, in diskInfo: [NSString: Any]) -> String {
        guard let value = diskInfo[key] else {
            return unavailable
        }

        if let boolValue = value as? Bool {
            return boolValue.diagnosticsDescription
        }

        if let numberValue = value as? NSNumber {
            return numberValue.boolValue.diagnosticsDescription
        }

        return stringValue(for: key, in: diskInfo)
    }
}

/// Captures volume metadata in a sendable format for background report generation.
private struct EjectifyVolumeDiagnosticsSnapshot: Sendable {

    /// Ejectify volume identifier.
    let id: String

    /// Disk Arbitration UUID used for resolution when available.
    let diskUUID: String

    /// User-visible volume name.
    let name: String

    /// Mounted filesystem path.
    let path: String

    /// BSD disk identifier, such as `disk6s2`.
    let bsdName: String

    /// Menu grouping category.
    let category: String

    /// Whether Ejectify manages this volume automatically.
    let enabled: Bool

    /// Creates a diagnostics snapshot for a mounted volume.
    init(volume: Volume) {
        id = volume.id
        diskUUID = volume.diskUUID?.uuidString ?? "-"
        name = volume.name
        path = volume.url.path
        bsdName = volume.bsdName
        category = volume.category.diagnosticsDescription
        enabled = volume.enabled
    }
}

/// Creates the Ejectify diagnostics report from a state snapshot.
private enum EjectifyDiagnosticsReportFactory {

    /// Creates an HTML diagnostics report.
    static func make(filename: String, snapshot: EjectifyDiagnosticsSnapshot) async throws -> DiagnosticsReport {
        let logStartDate = Date(timeIntervalSinceNow: -DiagnosticsLogLookback.duration)
        let ejectifyLogCollection = try UnifiedLogCollector.collect(kind: .ejectify(startDate: logStartDate))
        var reporters: [DiagnosticsReporting] = [
            EjectifyDiagnosticsIntroReporter(
                generatedAt: snapshot.generatedAt,
                logLookbackDescription: DiagnosticsLogLookback.description
            ),
            DiagnosticsReporter.DefaultReporter.appSystemMetadata.reporter,
            EjectifyStateReporter(snapshot: snapshot),
            VolumesReporter(
                discoveredVolumes: snapshot.mountedVolumeDiscovery,
                ejectifyVolumes: snapshot.volumes
            ),
            UnifiedLogsReporter(collection: ejectifyLogCollection)
        ]
        try Task.checkCancellation()

        let launchdLogCollection = try UnifiedLogCollector.collect(kind: .launchdServiceManagement(startDate: logStartDate))
        reporters.append(
            UnifiedLogsReporter(
                collection: launchdLogCollection
            )
        )
        try Task.checkCancellation()

        let diskArbitrationLogCollection: UnifiedLogCollection
        if let firstEjectifyLogDate = ejectifyLogCollection.firstEntryDate {
            diskArbitrationLogCollection = try UnifiedLogCollector.collect(
                kind: .diskArbitration(
                    filterTerms: diskArbitrationFilterTerms(from: snapshot),
                    startDate: max(logStartDate, firstEjectifyLogDate)
                )
            )
        } else if let failureMessage = ejectifyLogCollection.failureMessage {
            diskArbitrationLogCollection = .empty(
                title: "Disk Arbitration Logs (\(DiagnosticsLogLookback.title))",
                message: """
                Disk Arbitration logs were skipped because Ejectify logs could not be read: \(failureMessage).
                """
            )
        } else {
            diskArbitrationLogCollection = .empty(
                title: "Disk Arbitration Logs (\(DiagnosticsLogLookback.title))",
                message: """
                Disk Arbitration logs were skipped because no matching Ejectify log entries were found in \(DiagnosticsLogLookback.description).
                """
            )
        }

        try Task.checkCancellation()
        reporters.append(
            UnifiedLogsReporter(
                collection: diskArbitrationLogCollection
            )
        )

        let report = await DiagnosticsReporter.create(
            filename: filename,
            using: reporters,
            reportTitle: "Ejectify Diagnostics Report"
        )
        try Task.checkCancellation()
        return report
    }

    /// Returns terms used to keep Disk Arbitration logs relevant to Ejectify and current volumes.
    private static func diskArbitrationFilterTerms(from snapshot: EjectifyDiagnosticsSnapshot) -> [String] {
        let ejectifyVolumeTerms = snapshot.volumes.flatMap { volume in
            [volume.name, volume.bsdName, volume.id]
        }
        let discoveredVolumeTerms = snapshot.mountedVolumeDiscovery.flatMap { volume in
            [volume.volumeName, volume.bsdName, volume.uuid]
        }
        let unavailableTerms = Set(["-"])

        return (["Ejectify"] + ejectifyVolumeTerms + discoveredVolumeTerms)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !unavailableTerms.contains($0) }
    }
}

/// Defines the unified-log time window included in diagnostics reports.
private enum DiagnosticsLogLookback {

    /// Maximum age of unified-log entries included in the diagnostics report.
    static let duration: TimeInterval = 24 * 60 * 60

    /// Lowercase phrase used in explanatory report text.
    static let description = "the last 24 hours"

    /// Title-case phrase used in report chapter titles.
    static let title = "Last 24 Hours"
}

/// Generates the introductory report chapter.
private struct EjectifyDiagnosticsIntroReporter: DiagnosticsReporting {

    /// Snapshot creation time.
    let generatedAt: Date

    /// Human-readable unified-log time window included in the report.
    let logLookbackDescription: String

    /// Creates the report chapter.
    nonisolated(nonsending) func report() async -> DiagnosticsChapter {
        let generatedAtText = DiagnosticsDateFormatter.string(from: generatedAt)
        let html = """
        <p>This diagnostics report was generated by Ejectify and saved locally on this Mac. It can help troubleshoot mounting, unmounting, privileged helper, and Disk Arbitration behavior.</p>
        <p>Generated at <i>\(DiagnosticsHTML.escape(generatedAtText))</i>.</p>
        <p>The log chapters in this report include only matching events from \(DiagnosticsHTML.escape(logLookbackDescription)).</p>
        """
        return DiagnosticsChapter(title: "Information", diagnostics: html, shouldShowTitle: false)
    }
}

/// Generates a report chapter for Ejectify preferences and runtime state.
private struct EjectifyStateReporter: DiagnosticsReporting {

    /// Snapshot to render.
    let snapshot: EjectifyDiagnosticsSnapshot

    /// Creates the report chapter.
    nonisolated(nonsending) func report() async -> DiagnosticsChapter {
        let rows: [(String, String)] = [
            ("Launch at login", snapshot.launchAtLogin.diagnosticsDescription),
            ("Unmount when", snapshot.unmountWhen),
            ("Force unmount", snapshot.forceUnmount.diagnosticsDescription),
            ("Privileged helper status", snapshot.privilegedHelperStatus),
            ("Volume operation mode", snapshot.volumeOperationMode),
            ("Using privileged helper", snapshot.isUsingPrivilegedHelper.diagnosticsDescription),
            ("Eject notifications muted", snapshot.areEjectNotificationsMuted.diagnosticsDescription),
            ("Unmount-all hotkey registered", snapshot.isUnmountAllHotKeyRegistered.diagnosticsDescription)
        ]

        return DiagnosticsChapter(title: "Ejectify State", diagnostics: DiagnosticsHTML.table(rows))
    }
}

/// Generates a combined report chapter for macOS-discovered and Ejectify-managed volumes.
private struct VolumesReporter: DiagnosticsReporting {

    /// Mounted volume snapshots reported by macOS and Disk Arbitration.
    let discoveredVolumes: [MountedVolumeDiscoverySnapshot]

    /// Mounted volume snapshots managed by Ejectify.
    let ejectifyVolumes: [EjectifyVolumeDiagnosticsSnapshot]

    /// Creates the report chapter.
    nonisolated(nonsending) func report() async -> DiagnosticsChapter {
        let rows = makeRows()
        guard !rows.isEmpty else {
            return DiagnosticsChapter(title: "Volumes", diagnostics: "<p>No mounted volumes were present when the report was generated.</p>")
        }

        let header = """
        <table>
        <tr><th>Name</th><th>UUID</th><th>BSD</th><th>Kind</th><th>Internal</th><th>Ejectable</th><th>Removable</th><th>Supported</th><th>Enabled</th></tr>
        """
        let body = rows
            .map { row in
                """
                <tr><td>\(DiagnosticsHTML.escape(row.name))</td><td>\(DiagnosticsHTML.escape(row.uuid))</td><td>\(DiagnosticsHTML.escape(row.bsdName))</td><td>\(DiagnosticsHTML.escape(row.kind))</td><td>\(DiagnosticsHTML.escape(row.internalDevice))</td><td>\(DiagnosticsHTML.escape(row.ejectable))</td><td>\(DiagnosticsHTML.escape(row.removable))</td><td>\(DiagnosticsHTML.escape(row.presentedInEjectify))</td><td>\(DiagnosticsHTML.escape(row.activatedInEjectify))</td></tr>
                """
            }
            .joined()
        let html = header + body + "</table>"

        return DiagnosticsChapter(title: "Volumes", diagnostics: html)
    }

    /// Builds one row per mounted volume, preserving Ejectify-only rows if the snapshot changes during collection.
    private func makeRows() -> [VolumeDiagnosticsRow] {
        let ejectifyVolumesByPath = ejectifyVolumes.reduce(into: [String: EjectifyVolumeDiagnosticsSnapshot]()) { result, volume in
            result[volume.path] = volume
        }
        let discoveredRows = discoveredVolumes.map { discoveredVolume in
            VolumeDiagnosticsRow(
                discoveredVolume: discoveredVolume,
                ejectifyVolume: ejectifyVolumesByPath[discoveredVolume.mountPath]
            )
        }
        let discoveredPaths = Set(discoveredVolumes.map(\.mountPath))
        let ejectifyOnlyRows = ejectifyVolumes
            .filter { !discoveredPaths.contains($0.path) }
            .map(VolumeDiagnosticsRow.init(ejectifyVolume:))

        return (discoveredRows + ejectifyOnlyRows)
            .sorted { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }
    }
}

/// Render-ready diagnostics row for one volume.
private struct VolumeDiagnosticsRow: Sendable {

    /// Stable internal sort key for deterministic report output.
    let sortKey: String

    /// User-visible volume name.
    let name: String

    /// Best available Disk Arbitration UUID.
    let uuid: String

    /// BSD disk identifier, such as `disk6s2`.
    let bsdName: String

    /// Filesystem kind reported by Disk Arbitration.
    let kind: String

    /// Whether Disk Arbitration reports the device as internal.
    let internalDevice: String

    /// Whether Disk Arbitration reports the media as ejectable.
    let ejectable: String

    /// Whether Disk Arbitration reports the media as removable.
    let removable: String

    /// Whether the volume is present in Ejectify's managed-volume list.
    let presentedInEjectify: String

    /// Whether Ejectify automatic handling is enabled for the volume.
    let activatedInEjectify: String

    /// Creates a row from a macOS-discovered volume and its matching Ejectify volume, when present.
    init(discoveredVolume: MountedVolumeDiscoverySnapshot, ejectifyVolume: EjectifyVolumeDiagnosticsSnapshot?) {
        sortKey = discoveredVolume.mountPath
        name = Self.preferredValue(discoveredVolume.volumeName, fallback: ejectifyVolume?.name)
        uuid = Self.preferredValue(discoveredVolume.uuid, fallback: ejectifyVolume?.diskUUID)
        bsdName = Self.preferredValue(discoveredVolume.bsdName, fallback: ejectifyVolume?.bsdName)
        kind = discoveredVolume.volumeKind
        internalDevice = discoveredVolume.internalDevice
        ejectable = discoveredVolume.mediaEjectable
        removable = discoveredVolume.mediaRemovable
        presentedInEjectify = (ejectifyVolume != nil).diagnosticsDescription
        activatedInEjectify = ejectifyVolume?.enabled.diagnosticsDescription ?? Self.notApplicable
    }

    /// Creates a row for an Ejectify-managed volume that was not present in the raw discovery snapshot.
    init(ejectifyVolume: EjectifyVolumeDiagnosticsSnapshot) {
        sortKey = ejectifyVolume.path
        name = ejectifyVolume.name
        uuid = ejectifyVolume.diskUUID
        bsdName = ejectifyVolume.bsdName
        kind = Self.unavailable
        internalDevice = Self.unavailable
        ejectable = Self.unavailable
        removable = Self.unavailable
        presentedInEjectify = true.diagnosticsDescription
        activatedInEjectify = ejectifyVolume.enabled.diagnosticsDescription
    }

    /// Placeholder used when a value cannot apply to the row.
    private static let notApplicable = "-"

    /// Placeholder used when a metadata value is absent.
    private static let unavailable = "-"

    /// Returns the primary value unless it is unavailable, then falls back to Ejectify's matching model value.
    private static func preferredValue(_ value: String, fallback: String?) -> String {
        guard value == unavailable, let fallback, !fallback.isEmpty else {
            return value
        }

        return fallback
    }
}

/// Generates report chapters from macOS unified logging.
private struct UnifiedLogsReporter: DiagnosticsReporting {

    /// Preformatted unified-log collection to render.
    let collection: UnifiedLogCollection

    /// Creates the report chapter.
    nonisolated(nonsending) func report() async -> DiagnosticsChapter {
        DiagnosticsChapter(title: collection.title, diagnostics: collection.html)
    }
}

/// Contains the rendered output and metadata for one unified-log query.
private struct UnifiedLogCollection: Sendable {

    /// Report chapter title.
    let title: String

    /// Rendered HTML for the log chapter body.
    let html: String

    /// Earliest matching log entry date in this collection.
    let firstEntryDate: Date?

    /// Error message when reading this log collection failed.
    let failureMessage: String?

    /// Creates an empty log collection with a plain explanatory message.
    static func empty(title: String, message: String) -> Self {
        Self(title: title, html: "<p>\(DiagnosticsHTML.escape(message))</p>", firstEntryDate: nil, failureMessage: nil)
    }
}

/// Reads relevant macOS unified log entries.
private enum UnifiedLogCollector {

    /// Defines which unified-log subset to collect.
    enum Kind: Sendable {
        case ejectify(startDate: Date)
        case launchdServiceManagement(startDate: Date)
        case diskArbitration(filterTerms: [String], startDate: Date)
    }

    /// Collects and formats unified log entries for a chapter.
    static func collect(kind: Kind) throws -> UnifiedLogCollection {
        let title = kind.title

        do {
            try Task.checkCancellation()
            let store = try OSLogStore(scope: .system)
            let entries = try store.getEntries(with: [], at: kind.startPosition(in: store), matching: kind.predicate)
            let dateFormatter = DiagnosticsDateFormatter.make()
            let logOutput = try formatEntries(entries, dateFormatter: dateFormatter)
            try Task.checkCancellation()

            guard let firstEntryDate = logOutput.firstEntryDate else {
                return UnifiedLogCollection(
                    title: title,
                    html: "<p>\(DiagnosticsHTML.escape(kind.emptyResultMessage))</p>",
                    firstEntryDate: nil,
                    failureMessage: nil
                )
            }

            return UnifiedLogCollection(
                title: title,
                html: DiagnosticsHTML.pre(logOutput.lines),
                firstEntryDate: firstEntryDate,
                failureMessage: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let message = "Unable to read \(title) from the unified log: \(error.localizedDescription)"
            return UnifiedLogCollection(
                title: title,
                html: DiagnosticsHTML.pre(message),
                firstEntryDate: nil,
                failureMessage: error.localizedDescription
            )
        }
    }

    /// Formats matching log entries while tracking the first matching entry date.
    private static func formatEntries(
        _ entries: AnySequence<OSLogEntry>,
        dateFormatter: ISO8601DateFormatter
    ) throws -> (lines: String, firstEntryDate: Date?) {
        var lines: [String] = []
        var firstEntryDate: Date?

        for entry in entries {
            try Task.checkCancellation()

            guard let logEntry = entry as? OSLogEntryLog else {
                continue
            }

            if firstEntryDate == nil {
                firstEntryDate = logEntry.date
            }

            lines.append(format(entry: logEntry, dateFormatter: dateFormatter))
        }

        return (lines.joined(separator: "\n"), firstEntryDate)
    }

    /// Formats a unified-log entry into one readable line.
    private static func format(entry: OSLogEntryLog, dateFormatter: ISO8601DateFormatter) -> String {
        let date = DiagnosticsDateFormatter.string(from: entry.date, using: dateFormatter)
        let level = entry.level.diagnosticsDescription
        return "\(date) \(level) \(entry.process)[\(entry.processIdentifier)] [\(entry.subsystem):\(entry.category)] \(entry.composedMessage)"
    }
}

/// Provides stable date formatting for report content.
private enum DiagnosticsDateFormatter {

    /// Creates a formatter for report timestamps.
    static func make() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// Formats a date as an ISO-8601 string.
    static func string(from date: Date) -> String {
        string(from: date, using: make())
    }

    /// Formats a date as an ISO-8601 string using an existing formatter.
    static func string(from date: Date, using formatter: ISO8601DateFormatter) -> String {
        formatter.string(from: date)
    }
}

/// HTML helpers for custom diagnostics chapters.
private enum DiagnosticsHTML {

    /// Escapes text for safe insertion into HTML.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Renders key/value rows as an HTML table.
    static func table(_ rows: [(String, String)]) -> String {
        var html = "<table>"
        for (key, value) in rows {
            html += "<tr><th>\(escape(key))</th><td>\(escape(value))</td></tr>"
        }
        html += "</table>"
        return html
    }

    /// Renders escaped text in a preformatted block.
    static func pre(_ value: String) -> String {
        "<pre>\(escape(value))</pre>"
    }
}

private extension NSSavePanel {

    /// Runs the panel and returns the selected URL when the user confirms.
    var runModalResultURL: URL? {
        runModal() == .OK ? url : nil
    }
}

private extension Bool {

    /// Human-readable diagnostics value.
    var diagnosticsDescription: String {
        self ? "Yes" : "No"
    }
}

private extension Volume.Category {

    /// Human-readable diagnostics category.
    var diagnosticsDescription: String {
        switch self {
        case .internalVolume:
            return "Internal"
        case .external:
            return "External"
        case .diskImage:
            return "Disk Image"
        }
    }
}

private extension UnifiedLogCollector.Kind {

    /// Report chapter title for this log subset.
    var title: String {
        switch self {
        case .ejectify:
            return "Ejectify Logs (\(DiagnosticsLogLookback.title))"
        case .launchdServiceManagement:
            return "Launchd and ServiceManagement Logs (\(DiagnosticsLogLookback.title))"
        case .diskArbitration:
            return "Disk Arbitration Logs (\(DiagnosticsLogLookback.title))"
        }
    }

    /// Predicate used for unified-log filtering.
    var predicate: NSPredicate {
        switch self {
        case .ejectify:
            return NSPredicate(
                format: "subsystem == %@ OR subsystem == %@",
                LoggingConfiguration.subsystem,
                PrivilegedHelperConfiguration.machServiceName
            )
        case .launchdServiceManagement:
            return launchdServiceManagementPredicate()
        case .diskArbitration(let filterTerms, _):
            return diskArbitrationPredicate(filterTerms: filterTerms)
        }
    }

    /// Start position for unified-log enumeration.
    func startPosition(in store: OSLogStore) -> OSLogPosition? {
        switch self {
        case .ejectify(let startDate), .launchdServiceManagement(let startDate), .diskArbitration(_, let startDate):
            return store.position(date: startDate)
        }
    }

    /// Empty-state message for this log chapter.
    var emptyResultMessage: String {
        switch self {
        case .ejectify:
            return "No matching Ejectify log entries were found in \(DiagnosticsLogLookback.description)."
        case .launchdServiceManagement(let startDate):
            let startDateText = DiagnosticsDateFormatter.string(from: startDate)
            return "No matching error-or-fault Ejectify-related launchd or ServiceManagement log entries were found from \(startDateText) to now."
        case .diskArbitration(_, let startDate):
            let startDateText = DiagnosticsDateFormatter.string(from: startDate)
            return "No matching error-or-fault Disk Arbitration log entries were found from \(startDateText) to now."
        }
    }

    /// Ejectify identifiers used to keep launchd and ServiceManagement logs specific to this app.
    private var ejectifyLaunchdTerms: [String] {
        [
            "nl.nielsmouthaan.Ejectify",
            PrivilegedHelperConfiguration.machServiceName,
            "nl.nielsmouthaan.Ejectify-LaunchAtLoginHelper",
            "EjectifyPrivilegedHelper"
        ]
    }

    /// Builds a launchd and ServiceManagement predicate that requires both relevant system sources and Ejectify identifiers.
    private func launchdServiceManagementPredicate() -> NSPredicate {
        let messagePredicates = Array(repeating: "eventMessage CONTAINS[c] %@", count: ejectifyLaunchdTerms.count)
            .joined(separator: " OR ")
        let sourcePredicate = """
        process == %@ OR process == %@ OR subsystem CONTAINS[c] %@ OR subsystem CONTAINS[c] %@ OR subsystem CONTAINS[c] %@
        """
        let format = "(\(warningOrHigherPredicate)) AND (\(sourcePredicate)) AND (\(messagePredicates))"
        let arguments = ([
            "launchd",
            "smd",
            "com.apple.xpc",
            "ServiceManagement",
            "BackgroundTaskManagement"
        ] + ejectifyLaunchdTerms) as [Any]

        return NSPredicate(format: format, argumentArray: arguments)
    }

    /// Unified-log predicate fragment for warnings and more severe entries represented by OSLogStore.
    private var warningOrHigherPredicate: String {
        "messageType == error OR messageType == fault"
    }

    /// Broad Disk Arbitration terms that are relevant to Ejectify's mount and unmount behavior.
    private var diskArbitrationActionTerms: [String] {
        ["mount", "unmount", "eject", "approval", "dissent", "dissenter"]
    }

    /// Builds a Disk Arbitration predicate with the action and volume filters pushed into OSLogStore.
    private func diskArbitrationPredicate(filterTerms: [String]) -> NSPredicate {
        let searchTerms = diskArbitrationActionTerms + filterTerms.filter { !$0.isEmpty }
        let messagePredicates = Array(repeating: "eventMessage CONTAINS[c] %@", count: searchTerms.count)
            .joined(separator: " OR ")
        let format = "(\(warningOrHigherPredicate)) AND subsystem == %@ AND (\(messagePredicates))"
        let arguments = (["com.apple.DiskArbitration.diskarbitrationd"] + searchTerms) as [Any]

        return NSPredicate(format: format, argumentArray: arguments)
    }
}

private extension OSLogEntryLog.Level {

    /// Human-readable diagnostics log level.
    var diagnosticsDescription: String {
        switch self {
        case .debug:
            return "DEBUG"
        case .info:
            return "INFO"
        case .notice:
            return "NOTICE"
        case .error:
            return "ERROR"
        case .fault:
            return "FAULT"
        case .undefined:
            return "UNDEFINED"
        @unknown default:
            return "UNKNOWN"
        }
    }
}
