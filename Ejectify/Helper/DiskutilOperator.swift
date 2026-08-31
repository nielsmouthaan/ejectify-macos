//
//  DiskutilOperator.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 25/02/2026.
//

import Darwin
@preconcurrency import DiskArbitration
import Foundation

/// Executes the fixed set of diskutil commands used by Ejectify after validating targets through Disk Arbitration.
enum DiskutilOperator {

    /// Creates configured Disk Arbitration sessions for shared app and helper usage.
    enum DiskArbitrationSessionFactory {

        /// Creates a Disk Arbitration session and binds callback delivery to the provided queue.
        static func makeSession(dispatchQueue: DispatchQueue) -> DASession? {
            guard let session = DASessionCreate(kCFAllocatorDefault) else {
                return nil
            }
            DASessionSetDispatchQueue(session, dispatchQueue)
            return session
        }
    }

    /// Extracts the stable volume UUID, with the media UUID as a fallback.
    enum IdentityUUIDResolver {

        /// Returns the UUID used by Ejectify to identify a volume.
        static func identityUUID(from diskInfo: [NSString: Any]) -> UUID? {
            volumeUUID(from: diskInfo) ?? mediaUUID(from: diskInfo)
        }

        /// Returns the volume UUID from Disk Arbitration metadata.
        static func volumeUUID(from diskInfo: [NSString: Any]) -> UUID? {
            uuid(from: diskInfo, key: kDADiskDescriptionVolumeUUIDKey)
        }

        /// Returns the media UUID from Disk Arbitration metadata.
        static func mediaUUID(from diskInfo: [NSString: Any]) -> UUID? {
            uuid(from: diskInfo, key: kDADiskDescriptionMediaUUIDKey)
        }

        /// Converts a bridged Disk Arbitration UUID value into a Foundation UUID.
        private static func uuid(from diskInfo: [NSString: Any], key: CFString) -> UUID? {
            guard let value = diskInfo[key as NSString] else {
                return nil
            }
            if let uuid = value as? UUID {
                return uuid
            }
            if let uuid = value as? NSUUID {
                return uuid as UUID
            }
            if let value = value as? String {
                return UUID(uuidString: value)
            }

            // Disk Arbitration declares both UUID description keys as CFUUID. Swift bridges these values as __NSCFType rather than UUID or NSUUID.
            let coreFoundationValue = value as CFTypeRef
            guard CFGetTypeID(coreFoundationValue) == CFUUIDGetTypeID() else {
                return nil
            }
            let coreFoundationUUID = coreFoundationValue as! CFUUID
            let uuidString = CFUUIDCreateString(kCFAllocatorDefault, coreFoundationUUID) as String
            return UUID(uuidString: uuidString)
        }
    }

    /// Supported diskutil mutations.
    enum Operation: Equatable, Sendable {
        case mount
        case unmount(force: Bool)
        case eject(force: Bool)

        /// Stable operation name used in diagnostics.
        var operationName: String {
            switch self {
            case .mount:
                return "mount"
            case .unmount:
                return "unmount"
            case .eject:
                return "eject"
            }
        }

        /// Whether this operation requests diskutil's force option.
        var isForced: Bool {
            switch self {
            case .mount:
                return false
            case .unmount(let force), .eject(let force):
                return force
            }
        }

        /// Arguments passed directly to diskutil after target resolution.
        func arguments(bsdName: String) -> [String] {
            switch self {
            case .mount:
                return ["mount", bsdName]
            case .unmount(let force):
                return ["unmount"] + (force ? ["force"] : []) + [bsdName]
            case .eject(let force):
                return ["eject"] + (force ? ["force"] : []) + [bsdName]
            }
        }
    }

    /// Why a diskutil child stopped.
    enum TerminationReason: String, Equatable, Sendable {
        case exit
        case signal
        case timeout
        case launchFailure
        case targetUnavailable
        case targetAmbiguous
        case invalidTarget
    }

    /// Semantic result of a diskutil operation.
    enum Outcome: String, Equatable, Sendable {
        case succeeded
        case failed
        case timedOut
        case launchFailed
        case targetUnavailable
        case targetAmbiguous
        case invalidTarget
    }

    /// Structured result retained after raw process output has been discarded.
    struct OperationResult: Equatable, Sendable {
        let outcome: Outcome
        let exitCode: Int32?
        let terminationReason: TerminationReason
        let durationMilliseconds: Int

        /// Whether the requested semantic state was reached.
        var success: Bool {
            outcome == .succeeded
        }

        /// Whether the child exceeded its process deadline.
        var timedOut: Bool {
            terminationReason == .timeout
        }
    }

    /// Live lock state for an encrypted APFS volume.
    enum LockState: String, Equatable, Sendable {
        case locked
        case unlocked
        case unknown
    }

    /// Privacy-safe structured metadata returned by APFS unlock.
    struct APFSMetadata: Equatable, Sendable {
        let diskManagementErrorCode: Int?
        let rateLimitBackoff: Bool?
        let rateLimitLockout: Bool?
    }

    /// Result of one APFS unlock request.
    enum UnlockOutcome: String, Equatable, Sendable {
        case succeeded
        case invalidPassword
        case failed
        case timedOut
        case launchFailed
        case targetUnavailable
        case targetAmbiguous
        case invalidTarget
    }

    /// Structured unlock result with no raw output or password data.
    struct UnlockResult: Equatable, Sendable {
        let outcome: UnlockOutcome
        let exitCode: Int32?
        let terminationReason: TerminationReason
        let durationMilliseconds: Int
        let metadata: APFSMetadata

        /// Whether diskutil reported a successful unlock.
        var success: Bool {
            outcome == .succeeded
        }

        /// Whether the child exceeded its process deadline.
        var timedOut: Bool {
            terminationReason == .timeout
        }
    }

    /// Captures one direct child-process execution before its raw output is discarded.
    struct ProcessResult: Sendable {
        let exitCode: Int32?
        let terminationReason: TerminationReason
        let durationMilliseconds: Int
        let stdout: Data

        /// Whether the child exceeded its process deadline.
        var timedOut: Bool {
            terminationReason == .timeout
        }
    }

    /// Abstraction used to test command execution deterministically.
    protocol ProcessRunning: Sendable {
        func run(arguments: [String], standardInput: Data?, timeout: TimeInterval) -> ProcessResult
    }

    /// Runs diskutil directly, retains bounded plist output when requested, and enforces a deadline.
    final class ProcessRunner: ProcessRunning, @unchecked Sendable {

        /// Maximum amount retained from structured standard output while the rest is drained.
        static let maximumRetainedOutputBytes = 64 * 1024

        /// Executable invoked by this runner. Production always uses diskutil, while tests may use controlled fixtures.
        private let executableURL: URL

        /// Creates a direct process runner.
        init(executableURL: URL = URL(fileURLWithPath: "/usr/sbin/diskutil")) {
            self.executableURL = executableURL
        }

        /// Appends a bounded prefix while remaining thread-safe across drain queues.
        private final class BoundedData: @unchecked Sendable {
            private let lock = NSLock()
            private var storage = Data()

            func append(_ data: Data) {
                lock.lock()
                defer { lock.unlock() }
                let remaining = ProcessRunner.maximumRetainedOutputBytes - storage.count
                guard remaining > 0 else {
                    return
                }
                storage.append(data.prefix(remaining))
            }

            var value: Data {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
        }

        /// Executes a fixed diskutil argument list without using a shell.
        func run(arguments: [String], standardInput: Data?, timeout: TimeInterval) -> ProcessResult {
            let startedAt = ContinuousClock.now
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let capturesStandardOutput = arguments.contains("-plist")
            let standardOutputPipe = capturesStandardOutput ? Pipe() : nil
            let standardInputPipe = standardInput == nil ? nil : Pipe()
            process.standardOutput = standardOutputPipe ?? FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = standardInputPipe

            let standardOutput = BoundedData()
            let drainGroup = DispatchGroup()
            if let standardOutputPipe {
                drain(pipe: standardOutputPipe, into: standardOutput, group: drainGroup)
            }

            let terminationSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                terminationSemaphore.signal()
            }

            do {
                try process.run()
            } catch {
                try? standardInputPipe?.fileHandleForWriting.close()
                try? standardOutputPipe?.fileHandleForReading.close()
                return ProcessResult(
                    exitCode: nil,
                    terminationReason: .launchFailure,
                    durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                    stdout: standardOutput.value
                )
            }

            if let standardInput, let standardInputPipe {
                standardInputPipe.fileHandleForWriting.write(standardInput)
                try? standardInputPipe.fileHandleForWriting.close()
            }

            let didTimeOut = terminationSemaphore.wait(timeout: .now() + timeout) == .timedOut
            if didTimeOut {
                process.terminate()
                if terminationSemaphore.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = terminationSemaphore.wait(timeout: .now() + 1)
                }
            }

            _ = drainGroup.wait(timeout: .now() + 1)
            let terminationReason: TerminationReason
            let exitCode: Int32?
            if didTimeOut {
                terminationReason = .timeout
                exitCode = nil
            } else {
                terminationReason = process.terminationReason == .exit ? .exit : .signal
                exitCode = process.terminationReason == .exit ? process.terminationStatus : nil
            }

            return ProcessResult(
                exitCode: exitCode,
                terminationReason: terminationReason,
                durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                stdout: standardOutput.value
            )
        }

        /// Drains a pipe on a dedicated queue while retaining only a bounded prefix.
        private func drain(pipe: Pipe, into output: BoundedData, group: DispatchGroup) {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                while let data = try? pipe.fileHandleForReading.read(upToCount: 8 * 1024), !data.isEmpty {
                    output.append(data)
                }
            }
        }

        /// Converts monotonic elapsed time to diagnostics-friendly milliseconds.
        private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
            let duration = start.duration(to: .now)
            return Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
        }
    }

    /// Result of validating or re-resolving a volume identity.
    enum TargetResolution: Equatable, Sendable {
        case resolved(bsdName: String)
        case unavailable
        case ambiguous
        case invalid
    }

    /// Default per-process deadline.
    static let processTimeout: TimeInterval = 60

    /// DiskManagement error used when an APFS passphrase is rejected.
    private static let authenticationRejectedErrorCode = -69591

    /// Queue and session used for synchronous Disk Arbitration identity checks.
    private static let diskArbitrationQueue = DispatchQueue(label: "nl.nielsmouthaan.Ejectify.DiskutilOperator.DiskArbitration")
    private static let diskArbitrationSession = DiskArbitrationSessionFactory.makeSession(dispatchQueue: diskArbitrationQueue)

    /// Runs one mount, unmount, or eject request.
    static func perform(
        identityUUID: UUID?,
        bsdName: String,
        operation: Operation,
        runner: any ProcessRunning = ProcessRunner(),
        timeout: TimeInterval = processTimeout
    ) -> OperationResult {
        let resolution = resolveTarget(identityUUID: identityUUID, bsdName: bsdName)
        guard case .resolved(let liveBSDName) = resolution else {
            return resolution.operationFailureResult()
        }

        let processResult = runner.run(arguments: operation.arguments(bsdName: liveBSDName), standardInput: nil, timeout: timeout)
        return classifyOperationResult(processResult: processResult)
    }

    /// Classifies a process result without retaining raw output.
    static func classifyOperationResult(processResult: ProcessResult) -> OperationResult {
        let outcome: Outcome
        if processResult.terminationReason == .exit, processResult.exitCode == 0 {
            outcome = .succeeded
        } else if processResult.terminationReason == .timeout {
            outcome = .timedOut
        } else if processResult.terminationReason == .launchFailure {
            outcome = .launchFailed
        } else {
            outcome = .failed
        }

        return OperationResult(
            outcome: outcome,
            exitCode: processResult.exitCode,
            terminationReason: processResult.terminationReason,
            durationMilliseconds: processResult.durationMilliseconds
        )
    }

    /// Reads authoritative encrypted APFS lock state through structured diskutil output.
    static func lockState(
        identityUUID: UUID?,
        bsdName: String,
        runner: any ProcessRunning = ProcessRunner(),
        timeout: TimeInterval = processTimeout
    ) -> LockState {
        guard case .resolved(let liveBSDName) = resolveTarget(identityUUID: identityUUID, bsdName: bsdName) else {
            return .unknown
        }
        let result = runner.run(arguments: ["info", "-plist", liveBSDName], standardInput: nil, timeout: timeout)
        return classifyLockState(processResult: result)
    }

    /// Unlocks one encrypted APFS volume using a passphrase supplied only on standard input.
    static func unlock(
        identityUUID: UUID?,
        bsdName: String,
        password: String,
        runner: any ProcessRunning = ProcessRunner(),
        timeout: TimeInterval = processTimeout
    ) -> UnlockResult {
        let resolution = resolveTarget(identityUUID: identityUUID, bsdName: bsdName)
        guard case .resolved(let liveBSDName) = resolution else {
            return resolution.unlockFailureResult()
        }

        return unlockResolved(
            bsdName: liveBSDName,
            password: password,
            runner: runner,
            timeout: timeout
        )
    }

    /// Runs and classifies APFS unlock after the volume identity has already been resolved.
    static func unlockResolved(
        bsdName: String,
        password: String,
        runner: any ProcessRunning,
        timeout: TimeInterval
    ) -> UnlockResult {
        let input = Data((password + "\n").utf8)
        let processResult = runner.run(
            arguments: ["apfs", "unlockVolume", bsdName, "-stdinpassphrase", "-plist"],
            standardInput: input,
            timeout: timeout
        )
        let plist = propertyList(from: processResult.stdout)
        let metadata = apfsMetadata(from: plist)
        let outcome: UnlockOutcome
        if processResult.terminationReason == .exit,
           processResult.exitCode == 0,
           (plist?["Success"] as? Bool) != false {
            outcome = .succeeded
        } else if metadata.diskManagementErrorCode == authenticationRejectedErrorCode,
                  metadata.rateLimitBackoff != true,
                  metadata.rateLimitLockout != true {
            outcome = .invalidPassword
        } else if processResult.terminationReason == .timeout {
            outcome = .timedOut
        } else if processResult.terminationReason == .launchFailure {
            outcome = .launchFailed
        } else {
            outcome = .failed
        }

        return UnlockResult(
            outcome: outcome,
            exitCode: processResult.exitCode,
            terminationReason: processResult.terminationReason,
            durationMilliseconds: processResult.durationMilliseconds,
            metadata: metadata
        )
    }

    /// Validates a BSD identifier accepted by the fixed helper endpoints.
    static func isValidBSDName(_ bsdName: String) -> Bool {
        bsdName.range(of: #"^disk[0-9]+(?:s[0-9]+){0,2}$"#, options: .regularExpression) != nil
    }

    /// Resolves the last-known BSD name, then scans for exactly one UUID match when it has changed.
    static func resolveTarget(identityUUID: UUID?, bsdName: String) -> TargetResolution {
        guard isValidBSDName(bsdName) else {
            return .invalid
        }
        guard let session = diskArbitrationSession else {
            return .unavailable
        }

        let originalMatchesIdentity: Bool
        if let disk = createDisk(session: session, bsdName: bsdName),
           let description = DADiskCopyDescription(disk) as? [NSString: Any] {
            originalMatchesIdentity = identityUUID == nil || IdentityUUIDResolver.identityUUID(from: description) == identityUUID
        } else {
            originalMatchesIdentity = false
        }
        if originalMatchesIdentity {
            return .resolved(bsdName: bsdName)
        }

        let matches = identityUUID.map { liveBSDNames(session: session, matching: $0) } ?? []
        return targetResolution(
            originalBSDName: bsdName,
            originalMatchesIdentity: originalMatchesIdentity,
            matchingBSDNames: matches,
            hasIdentityUUID: identityUUID != nil
        )
    }

    /// Applies deterministic ambiguity rules after Disk Arbitration metadata has been collected.
    static func targetResolution(
        originalBSDName: String,
        originalMatchesIdentity: Bool,
        matchingBSDNames: [String],
        hasIdentityUUID: Bool
    ) -> TargetResolution {
        if originalMatchesIdentity {
            return .resolved(bsdName: originalBSDName)
        }
        guard hasIdentityUUID else {
            return .unavailable
        }
        if matchingBSDNames.count == 1, let match = matchingBSDNames.first {
            return .resolved(bsdName: match)
        }
        return matchingBSDNames.isEmpty ? .unavailable : .ambiguous
    }

    /// Classifies structured diskutil info output.
    static func classifyLockState(processResult: ProcessResult) -> LockState {
        guard processResult.terminationReason == .exit,
              processResult.exitCode == 0,
              let plist = propertyList(from: processResult.stdout),
              (plist["FilesystemType"] as? String)?.lowercased() == "apfs",
              plist["Encryption"] as? Bool == true,
              let locked = plist["Locked"] as? Bool else {
            return .unknown
        }
        return locked ? .locked : .unlocked
    }

    /// Parses privacy-safe APFS status fields from plist output.
    static func apfsMetadata(from plist: [String: Any]?) -> APFSMetadata {
        APFSMetadata(
            diskManagementErrorCode: plist?["DiskManagementErrorCode"] as? Int,
            rateLimitBackoff: plist?["RateLimitStateBackoff"] as? Bool,
            rateLimitLockout: plist?["RateLimitStateLockout"] as? Bool
        )
    }

    /// Parses a property list dictionary from bounded process output.
    static func propertyList(from data: Data) -> [String: Any]? {
        guard !data.isEmpty else {
            return nil
        }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    /// Creates one Disk Arbitration object for a validated BSD name.
    private static func createDisk(session: DASession, bsdName: String) -> DADisk? {
        bsdName.withCString { pointer in
            DADiskCreateFromBSDName(kCFAllocatorDefault, session, pointer)
        }
    }

    /// Scans live BSD devices and returns every identity UUID match.
    private static func liveBSDNames(session: DASession, matching identityUUID: UUID) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter(isValidBSDName).filter { candidate in
            guard let disk = createDisk(session: session, bsdName: candidate),
                  let description = DADiskCopyDescription(disk) as? [NSString: Any] else {
                return false
            }
            return IdentityUUIDResolver.identityUUID(from: description) == identityUUID
        }
    }
}

private extension DiskutilOperator.TargetResolution {

    /// Converts a failed target resolution into an operation result without launching diskutil.
    func operationFailureResult() -> DiskutilOperator.OperationResult {
        let outcome: DiskutilOperator.Outcome
        let reason: DiskutilOperator.TerminationReason
        switch self {
        case .unavailable:
            outcome = .targetUnavailable
            reason = .targetUnavailable
        case .ambiguous:
            outcome = .targetAmbiguous
            reason = .targetAmbiguous
        case .invalid:
            outcome = .invalidTarget
            reason = .invalidTarget
        case .resolved:
            preconditionFailure("Resolved targets do not produce failure results")
        }
        return DiskutilOperator.OperationResult(
            outcome: outcome,
            exitCode: nil,
            terminationReason: reason,
            durationMilliseconds: 0
        )
    }

    /// Converts a failed target resolution into an unlock result without launching diskutil.
    func unlockFailureResult() -> DiskutilOperator.UnlockResult {
        let outcome: DiskutilOperator.UnlockOutcome
        let reason: DiskutilOperator.TerminationReason
        switch self {
        case .unavailable:
            outcome = .targetUnavailable
            reason = .targetUnavailable
        case .ambiguous:
            outcome = .targetAmbiguous
            reason = .targetAmbiguous
        case .invalid:
            outcome = .invalidTarget
            reason = .invalidTarget
        case .resolved:
            preconditionFailure("Resolved targets do not produce failure results")
        }
        return DiskutilOperator.UnlockResult(
            outcome: outcome,
            exitCode: nil,
            terminationReason: reason,
            durationMilliseconds: 0,
            metadata: DiskutilOperator.APFSMetadata(
                diskManagementErrorCode: nil,
                rateLimitBackoff: nil,
                rateLimitLockout: nil
            )
        )
    }
}
