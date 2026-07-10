//
//  LogTests.swift
//  EjectifyTests
//
//  Created by Codex on 10/07/2026.
//

import Foundation
import Testing

struct LogTests {

    @Test func setupSucceedsWithoutSystemWarning() {
        let systemWriter = RecordingSystemLogWriter()
        var didRunSetup = false

        Log.setupDiagnosticsLogger(
            setup: {
                didRunSetup = true
            },
            systemLogger: systemWriter
        )

        #expect(didRunSetup)
        #expect(systemWriter.entries.isEmpty)
    }

    @Test func setupFailureWritesSystemWarning() throws {
        let systemWriter = RecordingSystemLogWriter()

        Log.setupDiagnosticsLogger(
            setup: {
                throw TestError.example
            },
            systemLogger: systemWriter
        )

        let entry = try #require(systemWriter.entries.first)
        #expect(entry.level == .warning)
        #expect(entry.category == "diagnostics")
        #expect(entry.message.contains("Diagnostics logger setup failed"))
        #expect(entry.message.contains(TestError.example.localizedDescription))
    }

    @Test func infoWritesToBothSinksWithPersistedFormatting() throws {
        let systemWriter = RecordingSystemLogWriter()
        let diagnosticsWriter = RecordingDiagnosticsLogWriter()
        let category = Log.Category(
            name: "testing",
            systemLogger: systemWriter,
            diagnosticsLogger: diagnosticsWriter
        )

        category.info("Operation selected; source=test")

        let systemEntry = try #require(systemWriter.entries.first)
        #expect(systemEntry.level == .info)
        #expect(systemEntry.category == "testing")
        #expect(systemEntry.message == "Operation selected; source=test")
        let diagnosticsEntry = try #require(diagnosticsWriter.entries.first)
        #expect(diagnosticsEntry == .message("[INFO] [testing] Operation selected; source=test"))
    }

    @Test func debugWritesOnlyToSystemByDefault() {
        let systemWriter = RecordingSystemLogWriter()
        let diagnosticsWriter = RecordingDiagnosticsLogWriter()
        let category = Log.Category(
            name: "testing",
            systemLogger: systemWriter,
            diagnosticsLogger: diagnosticsWriter
        )

        category.debug("Development detail")

        #expect(systemWriter.entries.map(\.level) == [.debug])
        #expect(diagnosticsWriter.entries.isEmpty)
    }

    @Test func debugCanOptInToDiagnostics() {
        let systemWriter = RecordingSystemLogWriter()
        let diagnosticsWriter = RecordingDiagnosticsLogWriter()
        let category = Log.Category(
            name: "testing",
            systemLogger: systemWriter,
            diagnosticsLogger: diagnosticsWriter
        )

        category.debug("Support detail", includeInDiagnostics: true)

        #expect(systemWriter.entries.map(\.level) == [.debug])
        #expect(diagnosticsWriter.entries == [.message("[DEBUG] [testing] Support detail")])
    }

    @Test func messageOnlyErrorWritesToBothSinks() {
        let systemWriter = RecordingSystemLogWriter()
        let diagnosticsWriter = RecordingDiagnosticsLogWriter()
        let category = Log.Category(
            name: "testing",
            systemLogger: systemWriter,
            diagnosticsLogger: diagnosticsWriter
        )

        category.error("Operation failed; status=1")

        #expect(systemWriter.entries.map(\.level) == [.error])
        #expect(diagnosticsWriter.entries == [.message("[ERROR] [testing] Operation failed; status=1")])
    }

    @Test func errorValueUsesDiagnosticsErrorSink() throws {
        let systemWriter = RecordingSystemLogWriter()
        let diagnosticsWriter = RecordingDiagnosticsLogWriter()
        let category = Log.Category(
            name: "testing",
            systemLogger: systemWriter,
            diagnosticsLogger: diagnosticsWriter
        )

        category.error(TestError.example, message: "Operation failed")

        let systemEntry = try #require(systemWriter.entries.first)
        #expect(systemEntry.level == .error)
        #expect(systemEntry.message.contains(TestError.example.localizedDescription))
        #expect(diagnosticsWriter.entries == [
            .error(message: "[ERROR] [testing] Operation failed", description: TestError.example.localizedDescription)
        ])
    }

    @Test func disabledDiagnosticsSinkReceivesNothing() {
        let systemWriter = RecordingSystemLogWriter()
        let diagnosticsWriter = RecordingDiagnosticsLogWriter(isEnabled: false)
        let category = Log.Category(
            name: "testing",
            systemLogger: systemWriter,
            diagnosticsLogger: diagnosticsWriter
        )

        category.log("Helper-style event")

        #expect(systemWriter.entries.map(\.level) == [.log])
        #expect(diagnosticsWriter.entries.isEmpty)
        #expect(Log.DisabledDiagnosticsLogWriter().isEnabled == false)
    }

    @Test func liveDiagnosticsWriterIsDisabledDuringTests() {
        #expect(Log.LiveDiagnosticsLogWriter.isRunningTests)
        #expect(Log.LiveDiagnosticsLogWriter().isEnabled == false)
    }
}

private enum TestError: LocalizedError {
    case example

    var errorDescription: String? {
        "Example failure"
    }
}

private final class RecordingSystemLogWriter: Log.SystemLogWriting, @unchecked Sendable {

    struct Entry: Equatable, Sendable {
        let level: Log.Level
        let category: String
        let message: String
    }

    private let lock = NSLock()
    private var storedEntries: [Entry] = []

    var entries: [Entry] {
        lock.withLock { storedEntries }
    }

    nonisolated func log(level: Log.Level, category: String, message: String) {
        lock.withLock {
            storedEntries.append(Entry(level: level, category: category, message: message))
        }
    }
}

private final class RecordingDiagnosticsLogWriter: Log.DiagnosticsLogWriting, @unchecked Sendable {

    enum Entry: Equatable, Sendable {
        case message(String)
        case error(message: String, description: String)
    }

    let isEnabled: Bool
    private let lock = NSLock()
    private var storedEntries: [Entry] = []

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    var entries: [Entry] {
        lock.withLock { storedEntries }
    }

    nonisolated func log(message: String, file _: String, function _: String, line _: UInt) {
        lock.withLock {
            storedEntries.append(.message(message))
        }
    }

    nonisolated func log(error: any Error, message: String, file _: String, function _: String, line _: UInt) {
        lock.withLock {
            storedEntries.append(.error(message: message, description: error.localizedDescription))
        }
    }
}
