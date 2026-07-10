//
//  Log.swift
//  Ejectify
//
//  Created by Codex on 10/07/2026.
//

#if !EJECTIFY_PRIVILEGED_HELPER
import Diagnostics
#endif
import Foundation
import OSLog

/// Central Ejectify logger that writes to Apple unified logging and, in the app target, Diagnostics.
nonisolated enum Log {

    /// App lifecycle and app-wide setup logging.
    nonisolated static let app = Category(name: "app")

    /// Diagnostics report generation and export logging.
    nonisolated static let diagnostics = Category(name: "diagnostics")

    /// Volume discovery, mount, unmount, and routing logging.
    nonisolated static let volumeOperations = Category(name: "volume-operations")

    /// Display, session, and system power transition logging.
    nonisolated static let powerEvents = Category(name: "power-events")

    /// User preference and onboarding state logging.
    nonisolated static let preferences = Category(name: "preferences")

    /// Updater startup and user-requested update logging.
    nonisolated static let updates = Category(name: "updates")

    /// Global hot-key registration and invocation logging.
    nonisolated static let hotKey = Category(name: "hot-key")

    /// Privileged helper registration, connection, and execution logging.
    nonisolated static let privilegedHelper = Category(name: "privileged-helper")

    /// Sets up DiagnosticsLogger for persisted cross-session app log events.
    nonisolated static func setupDiagnosticsLogger() {
        #if !EJECTIFY_PRIVILEGED_HELPER
        setupDiagnosticsLogger(
            setup: {
                try DiagnosticsLogger.setup()
            },
            systemLogger: OSLogSystemLogWriter()
        )
        #endif
    }

    /// Sets up DiagnosticsLogger using injectable dependencies.
    nonisolated static func setupDiagnosticsLogger(
        setup: () throws -> Void,
        systemLogger: any SystemLogWriting
    ) {
        do {
            try setup()
        } catch {
            systemLogger.log(
                level: .warning,
                category: diagnostics.name,
                message: "Diagnostics logger setup failed; error=\(String(describing: error)); errorDescription=\(error.localizedDescription)"
            )
        }
    }
}

extension Log {

    /// Logging severity used by the Ejectify logging facade.
    enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case log = "LOG"
        case warning = "WARNING"
        case error = "ERROR"
        case fault = "FAULT"

        /// Whether the level is persisted into Diagnostics without an explicit override.
        nonisolated var isIncludedInDiagnosticsByDefault: Bool {
            self != .debug
        }
    }

    /// A predefined logging category with shared system and Diagnostics sinks.
    struct Category: Sendable {

        /// Stable category name used in Apple unified logging and Diagnostics messages.
        let name: String

        /// Apple unified logging sink.
        private let systemLogger: any SystemLogWriting

        /// Diagnostics log sink.
        private let diagnosticsLogger: any DiagnosticsLogWriting

        /// Creates a logging category.
        nonisolated init(
            name: String,
            systemLogger: any SystemLogWriting = OSLogSystemLogWriter(),
            diagnosticsLogger: any DiagnosticsLogWriting = DefaultDiagnosticsLogWriter()
        ) {
            self.name = name
            self.systemLogger = systemLogger
            self.diagnosticsLogger = diagnosticsLogger
        }

        /// Logs development-only detail.
        nonisolated func debug(
            _ message: @autoclosure () -> String,
            includeInDiagnostics: Bool = false,
            file: String = #file,
            function: String = #function,
            line: UInt = #line
        ) {
            write(
                level: .debug,
                message: message(),
                includeInDiagnostics: includeInDiagnostics,
                file: file,
                function: function,
                line: line
            )
        }

        /// Logs an additional diagnostic breadcrumb.
        nonisolated func info(
            _ message: @autoclosure () -> String,
            file: String = #file,
            function: String = #function,
            line: UInt = #line
        ) {
            write(level: .info, message: message(), file: file, function: function, line: line)
        }

        /// Logs an important production breadcrumb.
        nonisolated func log(
            _ message: @autoclosure () -> String,
            file: String = #file,
            function: String = #function,
            line: UInt = #line
        ) {
            write(level: .log, message: message(), file: file, function: function, line: line)
        }

        /// Logs recoverable degraded behavior.
        nonisolated func warning(
            _ message: @autoclosure () -> String,
            file: String = #file,
            function: String = #function,
            line: UInt = #line
        ) {
            write(level: .warning, message: message(), file: file, function: function, line: line)
        }

        /// Logs a failed operation when no Error value is available.
        nonisolated func error(
            _ message: @autoclosure () -> String,
            file: String = #file,
            function: String = #function,
            line: UInt = #line
        ) {
            write(level: .error, message: message(), file: file, function: function, line: line)
        }

        /// Logs a failed operation with its original Error value.
        nonisolated func error(
            _ error: any Error,
            message: @autoclosure () -> String,
            file: String = #file,
            function: String = #function,
            line: UInt = #line
        ) {
            write(level: .error, error: error, message: message(), file: file, function: function, line: line)
        }

        /// Logs a likely bug or violated invariant when no Error value is available.
        nonisolated func fault(
            _ message: @autoclosure () -> String,
            file: String = #file,
            function: String = #function,
            line: UInt = #line
        ) {
            write(level: .fault, message: message(), file: file, function: function, line: line)
        }

        /// Logs a likely bug or violated invariant with its original Error value.
        nonisolated func fault(
            _ error: any Error,
            message: @autoclosure () -> String,
            file: String = #file,
            function: String = #function,
            line: UInt = #line
        ) {
            write(level: .fault, error: error, message: message(), file: file, function: function, line: line)
        }

        private nonisolated func write(
            level: Level,
            message: String,
            includeInDiagnostics: Bool? = nil,
            file: String,
            function: String,
            line: UInt
        ) {
            systemLogger.log(level: level, category: name, message: message)
            let shouldLogToDiagnostics = includeInDiagnostics ?? level.isIncludedInDiagnosticsByDefault
            guard shouldLogToDiagnostics, diagnosticsLogger.isEnabled else {
                return
            }

            diagnosticsLogger.log(
                message: diagnosticsMessage(level: level, message: message),
                file: file,
                function: function,
                line: line
            )
        }

        private nonisolated func write(
            level: Level,
            error: any Error,
            message: String,
            file: String,
            function: String,
            line: UInt
        ) {
            systemLogger.log(
                level: level,
                category: name,
                message: "\(message); error=\(String(describing: error)); errorDescription=\(error.localizedDescription)"
            )
            guard diagnosticsLogger.isEnabled else {
                return
            }

            diagnosticsLogger.log(
                error: error,
                message: diagnosticsMessage(level: level, message: message),
                file: file,
                function: function,
                line: line
            )
        }

        private nonisolated func diagnosticsMessage(level: Level, message: String) -> String {
            "[\(level.rawValue)] [\(name)] \(message)"
        }
    }
}

extension Log {

    /// Sink that writes app logs to Apple unified logging.
    protocol SystemLogWriting: Sendable {

        /// Writes a log message at the given level and category.
        nonisolated func log(level: Level, category: String, message: String)
    }

    /// Sink that writes support-worthy logs to Diagnostics.
    protocol DiagnosticsLogWriting: Sendable {

        /// Whether Diagnostics logging should be attempted.
        nonisolated var isEnabled: Bool { get }

        /// Writes a Diagnostics message event.
        nonisolated func log(message: String, file: String, function: String, line: UInt)

        /// Writes a Diagnostics error event.
        nonisolated func log(error: any Error, message: String, file: String, function: String, line: UInt)
    }

    /// Apple unified logging sink backed by OSLog Logger.
    private struct OSLogSystemLogWriter: SystemLogWriting {

        /// Subsystem used by the current target.
        private let subsystem: String

        /// Creates an OSLog-backed system log writer.
        nonisolated init(subsystem: String = Self.defaultSubsystem) {
            self.subsystem = subsystem
        }

        /// Writes a log message to Apple unified logging.
        nonisolated func log(level: Level, category: String, message: String) {
            let logger = Logger(subsystem: subsystem, category: category)
            switch level {
            case .debug:
                logger.debug("\(message, privacy: .public)")
            case .info:
                logger.info("\(message, privacy: .public)")
            case .log:
                logger.log("\(message, privacy: .public)")
            case .warning:
                logger.warning("\(message, privacy: .public)")
            case .error:
                logger.error("\(message, privacy: .public)")
            case .fault:
                logger.fault("\(message, privacy: .public)")
            }
        }

        /// Default subsystem for the current compilation target.
        private nonisolated static var defaultSubsystem: String {
            #if EJECTIFY_PRIVILEGED_HELPER
            PrivilegedHelperConfiguration.machServiceName
            #else
            Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify"
            #endif
        }
    }

    /// Disabled Diagnostics sink used by the privileged helper and explicit tests.
    struct DisabledDiagnosticsLogWriter: DiagnosticsLogWriting {

        /// Whether Diagnostics logging should be attempted.
        nonisolated let isEnabled = false

        /// Creates a disabled Diagnostics writer.
        nonisolated init() {
        }

        /// Ignores a Diagnostics message event.
        nonisolated func log(message _: String, file _: String, function _: String, line _: UInt) {
        }

        /// Ignores a Diagnostics error event.
        nonisolated func log(error _: any Error, message _: String, file _: String, function _: String, line _: UInt) {
        }
    }

    #if !EJECTIFY_PRIVILEGED_HELPER
    /// Diagnostics sink backed by AvdLee DiagnosticsLogger.
    struct LiveDiagnosticsLogWriter: DiagnosticsLogWriting {

        /// Creates a live Diagnostics log writer.
        nonisolated init() {
        }

        /// Whether Diagnostics is ready and appropriate to write to.
        nonisolated var isEnabled: Bool {
            DiagnosticsLogger.isSetUp() && Self.isRunningTests == false
        }

        /// Writes a Diagnostics message event.
        nonisolated func log(message: String, file: String, function: String, line: UInt) {
            guard isEnabled else {
                return
            }

            DiagnosticsLogger.log(message: message, file: file, function: function, line: line)
        }

        /// Writes a Diagnostics error event.
        nonisolated func log(error: any Error, message: String, file: String, function: String, line: UInt) {
            guard isEnabled else {
                return
            }

            DiagnosticsLogger.log(error: error, description: message, file: file, function: function, line: line)
        }

        /// Whether the current process is running a test bundle.
        nonisolated static var isRunningTests: Bool {
            let environment = ProcessInfo.processInfo.environment
            return environment["XCTestConfigurationFilePath"] != nil
                || environment["XCTestBundlePath"] != nil
                || ProcessInfo.processInfo.arguments.contains { argument in
                    argument.hasSuffix(".xctest") || argument.contains(".xctest/")
                }
                || NSClassFromString("XCTest.XCTestCase") != nil
                || NSClassFromString("XCTestCase") != nil
        }
    }

    private typealias DefaultDiagnosticsLogWriter = LiveDiagnosticsLogWriter
    #else
    private typealias DefaultDiagnosticsLogWriter = DisabledDiagnosticsLogWriter
    #endif
}
