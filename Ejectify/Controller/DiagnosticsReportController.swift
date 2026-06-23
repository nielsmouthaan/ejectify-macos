//
//  DiagnosticsReportController.swift
//  Ejectify
//
//  Created by Codex on 22/06/2026.
//

import AppKit
import Diagnostics
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
        Task.detached(priority: .userInitiated) { [snapshot, targetURL] in
            do {
                let report = await EjectifyDiagnosticsReportFactory.make(
                    filename: targetURL.lastPathComponent,
                    snapshot: snapshot
                )
                try report.data.write(to: targetURL, options: .atomic)
                await Self.revealReport(at: targetURL)
            } catch {
                let failureDescription = error.localizedDescription
                await Self.showSaveFailureAlert(failureDescription: failureDescription)
            }
        }
    }

    /// Creates the save panel configured for HTML diagnostics reports.
    private func makeSavePanel() -> NSSavePanel {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.html]
        savePanel.canCreateDirectories = true
        savePanel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        savePanel.nameFieldStringValue = "Ejectify-Diagnostics-Report.html"
        savePanel.title = String(localized: "Save Diagnostics Report")
        savePanel.message = String(localized: "Save the diagnostics report to the chosen location.")
        return savePanel
    }

    /// Reveals a successfully saved diagnostics report in Finder.
    private static func revealReport(at url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Shows a user-friendly alert when diagnostics report generation or writing fails.
    private static func showSaveFailureAlert(failureDescription: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Could not save diagnostics report.")
        alert.informativeText = failureDescription
        alert.runModal()
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

    /// Creates a snapshot from the current app state.
    @MainActor
    static func make() -> Self {
        let volumes = Volume.mountedVolumes().map(EjectifyVolumeDiagnosticsSnapshot.init(volume:))
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
            volumes: volumes
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

/// Captures volume metadata in a sendable format for background report generation.
private struct EjectifyVolumeDiagnosticsSnapshot: Sendable {

    /// Stable volume UUID.
    let id: String

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
        id = volume.id.uuidString
        name = volume.name
        path = volume.url.path
        bsdName = volume.bsdName
        category = volume.category.diagnosticsDescription
        enabled = volume.enabled
    }
}

/// Creates the Ejectify diagnostics report from a state snapshot.
private enum EjectifyDiagnosticsReportFactory {

    /// Maximum age of unified-log entries included in the diagnostics report.
    private static let logLookbackDuration: TimeInterval = 24 * 60 * 60

    /// Creates an HTML diagnostics report.
    static func make(filename: String, snapshot: EjectifyDiagnosticsSnapshot) async -> DiagnosticsReport {
        let logStartDate = Date(timeIntervalSinceNow: -logLookbackDuration)
        let ejectifyLogCollection = UnifiedLogCollector.collect(kind: .ejectify(startDate: logStartDate))
        var reporters: [DiagnosticsReporting] = [
            EjectifyDiagnosticsIntroReporter(generatedAt: snapshot.generatedAt),
            DiagnosticsReporter.DefaultReporter.appSystemMetadata.reporter,
            EjectifyStateReporter(snapshot: snapshot),
            MountedVolumesReporter(volumes: snapshot.volumes),
            UnifiedLogsReporter(collection: ejectifyLogCollection)
        ]
        let launchdLogCollection = UnifiedLogCollector.collect(kind: .launchdServiceManagement(startDate: logStartDate))
        reporters.append(
            UnifiedLogsReporter(
                collection: launchdLogCollection
            )
        )

        let diskArbitrationLogCollection: UnifiedLogCollection
        if let firstEjectifyLogDate = ejectifyLogCollection.firstEntryDate {
            diskArbitrationLogCollection = UnifiedLogCollector.collect(
                kind: .diskArbitration(
                    filterTerms: diskArbitrationFilterTerms(from: snapshot),
                    startDate: max(logStartDate, firstEjectifyLogDate)
                )
            )
        } else if let failureMessage = ejectifyLogCollection.failureMessage {
            diskArbitrationLogCollection = .empty(
                title: "Disk Arbitration Logs",
                message: """
                Disk Arbitration logs were skipped because Ejectify logs could not be read: \(failureMessage).
                """
            )
        } else {
            diskArbitrationLogCollection = .empty(
                title: "Disk Arbitration Logs",
                message: """
                Disk Arbitration logs were skipped because no matching Ejectify log entries were found in the last 24 hours.
                """
            )
        }

        reporters.append(
            UnifiedLogsReporter(
                collection: diskArbitrationLogCollection
            )
        )

        return await DiagnosticsReporter.create(
            filename: filename,
            using: reporters,
            reportTitle: "Ejectify Diagnostics Report"
        )
    }

    /// Returns terms used to keep Disk Arbitration logs relevant to Ejectify and current volumes.
    private static func diskArbitrationFilterTerms(from snapshot: EjectifyDiagnosticsSnapshot) -> [String] {
        let volumeTerms = snapshot.volumes.flatMap { volume in
            [volume.name, volume.bsdName, volume.id]
        }
        return (["Ejectify"] + volumeTerms)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// Generates the introductory report chapter.
private struct EjectifyDiagnosticsIntroReporter: DiagnosticsReporting {

    /// Snapshot creation time.
    let generatedAt: Date

    /// Creates the report chapter.
    nonisolated(nonsending) func report() async -> DiagnosticsChapter {
        let generatedAtText = DiagnosticsDateFormatter.string(from: generatedAt)
        let html = """
        <p>This diagnostics report was generated by Ejectify and saved locally on this Mac. It can help troubleshoot mounting, unmounting, privileged helper, and Disk Arbitration behavior.</p>
        <p>Generated at <i>\(DiagnosticsHTML.escape(generatedAtText))</i>.</p>
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

/// Generates a report chapter for mounted volumes.
private struct MountedVolumesReporter: DiagnosticsReporting {

    /// Mounted volume snapshots to render.
    let volumes: [EjectifyVolumeDiagnosticsSnapshot]

    /// Creates the report chapter.
    nonisolated(nonsending) func report() async -> DiagnosticsChapter {
        guard !volumes.isEmpty else {
            return DiagnosticsChapter(title: "Mounted Volumes", diagnostics: "<p>No managed volumes were mounted when the report was generated.</p>")
        }

        let header = """
        <table>
        <tr><th>Name</th><th>UUID</th><th>BSD Name</th><th>Path</th><th>Category</th><th>Enabled</th></tr>
        """
        let body = volumes
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { volume in
                """
                <tr><td>\(DiagnosticsHTML.escape(volume.name))</td><td>\(DiagnosticsHTML.escape(volume.id))</td><td>\(DiagnosticsHTML.escape(volume.bsdName))</td><td>\(DiagnosticsHTML.escape(volume.path))</td><td>\(DiagnosticsHTML.escape(volume.category))</td><td>\(DiagnosticsHTML.escape(volume.enabled.diagnosticsDescription))</td></tr>
                """
            }
            .joined()
        let html = header + body + "</table>"

        return DiagnosticsChapter(title: "Mounted Volumes", diagnostics: html)
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
    static func collect(kind: Kind) -> UnifiedLogCollection {
        let title = kind.title

        do {
            let store = try OSLogStore(scope: .system)
            let entries = try store.getEntries(with: [], at: kind.startPosition(in: store), matching: kind.predicate)
            let dateFormatter = DiagnosticsDateFormatter.make()
            let logOutput = formatEntries(entries, dateFormatter: dateFormatter)

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
    ) -> (lines: String, firstEntryDate: Date?) {
        var lines = ""
        var firstEntryDate: Date?

        for entry in entries {
            guard let logEntry = entry as? OSLogEntryLog else {
                continue
            }

            if firstEntryDate == nil {
                firstEntryDate = logEntry.date
            }

            if !lines.isEmpty {
                lines += "\n"
            }

            lines += format(entry: logEntry, dateFormatter: dateFormatter)
        }

        return (lines, firstEntryDate)
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
            return "Ejectify Logs"
        case .launchdServiceManagement:
            return "Launchd and ServiceManagement Logs"
        case .diskArbitration:
            return "Disk Arbitration Logs"
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
            return "No matching Ejectify log entries were found in the last 24 hours."
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
