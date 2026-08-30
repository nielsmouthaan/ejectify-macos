//
//  DiskutilOperatorTests.swift
//  EjectifyTests
//
//  Created by Codex on 12/08/2026.
//

import Foundation
@preconcurrency import DiskArbitration
import Testing

struct DiskutilOperatorTests {

    struct CommandFixture: CustomTestStringConvertible, Sendable {
        let operation: DiskutilOperator.Operation
        let expected: [String]

        var testDescription: String {
            expected.joined(separator: " ")
        }
    }

    @Test func extractsDiskArbitrationCoreFoundationVolumeUUID() throws {
        let expected = try #require(UUID(uuidString: "D00BE41C-1700-36B1-AC88-821F0129A173"))
        let coreFoundationUUID = try #require(CFUUIDCreateFromString(kCFAllocatorDefault, expected.uuidString as CFString))
        let diskInfo: [NSString: Any] = [kDADiskDescriptionVolumeUUIDKey as NSString: coreFoundationUUID]

        #expect(DiskutilOperator.IdentityUUIDResolver.identityUUID(from: diskInfo) == expected)
    }

    @Test func fallsBackToDiskArbitrationCoreFoundationMediaUUID() throws {
        let expected = try #require(UUID(uuidString: "64BF5490-03D8-3CB2-B236-C54717B8BD4C"))
        let coreFoundationUUID = try #require(CFUUIDCreateFromString(kCFAllocatorDefault, expected.uuidString as CFString))
        let diskInfo: [NSString: Any] = [kDADiskDescriptionMediaUUIDKey as NSString: coreFoundationUUID]

        #expect(DiskutilOperator.IdentityUUIDResolver.identityUUID(from: diskInfo) == expected)
    }

    @Test func volumeUUIDTakesPrecedenceOverMediaUUID() throws {
        let expectedVolumeUUID = try #require(UUID(uuidString: "846BAAA5-9542-4928-8FF2-E571332EAD1D"))
        let mediaUUID = try #require(UUID(uuidString: "96BA994F-3C29-413E-9FA9-36F86D938A51"))
        let volumeCFUUID = try #require(CFUUIDCreateFromString(kCFAllocatorDefault, expectedVolumeUUID.uuidString as CFString))
        let mediaCFUUID = try #require(CFUUIDCreateFromString(kCFAllocatorDefault, mediaUUID.uuidString as CFString))
        let diskInfo: [NSString: Any] = [
            kDADiskDescriptionVolumeUUIDKey as NSString: volumeCFUUID,
            kDADiskDescriptionMediaUUIDKey as NSString: mediaCFUUID
        ]

        #expect(DiskutilOperator.IdentityUUIDResolver.identityUUID(from: diskInfo) == expectedVolumeUUID)
    }

    @Test func acceptsFoundationAndStringUUIDRepresentations() throws {
        let expected = try #require(UUID(uuidString: "31DACA5E-B7FF-350C-A26A-FF05BE808B45"))

        #expect(DiskutilOperator.IdentityUUIDResolver.identityUUID(from: [kDADiskDescriptionVolumeUUIDKey as NSString: expected]) == expected)
        #expect(DiskutilOperator.IdentityUUIDResolver.identityUUID(from: [kDADiskDescriptionVolumeUUIDKey as NSString: expected as NSUUID]) == expected)
        #expect(DiskutilOperator.IdentityUUIDResolver.identityUUID(from: [kDADiskDescriptionVolumeUUIDKey as NSString: expected.uuidString]) == expected)
    }

    @Test func rejectsMissingMalformedAndNonUUIDValues() {
        #expect(DiskutilOperator.IdentityUUIDResolver.identityUUID(from: [:]) == nil)
        #expect(DiskutilOperator.IdentityUUIDResolver.identityUUID(from: [kDADiskDescriptionVolumeUUIDKey as NSString: "not-a-uuid"]) == nil)
        #expect(DiskutilOperator.IdentityUUIDResolver.identityUUID(from: [kDADiskDescriptionVolumeUUIDKey as NSString: 42]) == nil)
    }

    @Test(arguments: [
        CommandFixture(operation: .mount, expected: ["mount", "disk7s1"]),
        CommandFixture(operation: .unmount(force: false), expected: ["unmount", "disk7s1"]),
        CommandFixture(operation: .unmount(force: true), expected: ["unmount", "force", "disk7s1"]),
        CommandFixture(operation: .eject(force: false), expected: ["eject", "disk7s1"]),
        CommandFixture(operation: .eject(force: true), expected: ["eject", "force", "disk7s1"])
    ])
    func constructsFixedCommandArguments(_ fixture: CommandFixture) {
        #expect(fixture.operation.arguments(bsdName: "disk7s1") == fixture.expected)
    }

    @Test(arguments: ["disk0", "disk7s1", "disk12s2s1"])
    func acceptsBSDNames(_ bsdName: String) {
        #expect(DiskutilOperator.isValidBSDName(bsdName))
    }

    @Test(arguments: ["/dev/disk7s1", "disk7s1 -force", "-disk7", "Disk7", "volume", "disk"])
    func rejectsPathsNamesAndOptions(_ target: String) {
        #expect(DiskutilOperator.isValidBSDName(target) == false)
    }

    @Test func keepsValidatedOriginalWhenUUIDHasDuplicateMatches() {
        let resolution = DiskutilOperator.targetResolution(
            originalBSDName: "disk7s1",
            originalMatchesIdentity: true,
            matchingBSDNames: ["disk7s1", "disk13s1"],
            hasIdentityUUID: true
        )
        #expect(resolution == .resolved(bsdName: "disk7s1"))
    }

    @Test func followsOneUniqueUUIDMatchWhenBSDNameChanged() {
        let resolution = DiskutilOperator.targetResolution(
            originalBSDName: "disk7s1",
            originalMatchesIdentity: false,
            matchingBSDNames: ["disk13s1"],
            hasIdentityUUID: true
        )
        #expect(resolution == .resolved(bsdName: "disk13s1"))
    }

    @Test func rejectsAmbiguousUUIDMatches() {
        let resolution = DiskutilOperator.targetResolution(
            originalBSDName: "disk7s1",
            originalMatchesIdentity: false,
            matchingBSDNames: ["disk13s1", "disk15s1"],
            hasIdentityUUID: true
        )
        #expect(resolution == .ambiguous)
    }

    @Test func reportsUnavailableWhenIdentityCannotBeFound() {
        #expect(DiskutilOperator.targetResolution(
            originalBSDName: "disk7s1",
            originalMatchesIdentity: false,
            matchingBSDNames: [],
            hasIdentityUUID: true
        ) == .unavailable)
        #expect(DiskutilOperator.targetResolution(
            originalBSDName: "disk7s1",
            originalMatchesIdentity: false,
            matchingBSDNames: [],
            hasIdentityUUID: false
        ) == .unavailable)
    }

    @Test func zeroExitIsSuccessful() {
        let result = DiskutilOperator.classifyOperationResult(
            processResult: processResult(exitCode: 0),
            operation: .unmount(force: false),
            reconciledState: .unmounted,
            resolvedBSDName: "disk7s1"
        )
        #expect(result.outcome == .succeeded)
        #expect(result.success)
    }

    @Test(arguments: [
        (DiskutilOperator.Operation.mount, DiskutilOperator.ReconciledState.mounted),
        (.unmount(force: false), .unmounted),
        (.eject(force: false), .absent)
    ])
    func reconciledStateCanSatisfyFailedCommand(
        operation: DiskutilOperator.Operation,
        state: DiskutilOperator.ReconciledState
    ) {
        let result = DiskutilOperator.classifyOperationResult(
            processResult: processResult(exitCode: 1),
            operation: operation,
            reconciledState: state,
            resolvedBSDName: "disk7s1"
        )
        #expect(result.outcome == .satisfiedAfterReconciliation)
        #expect(result.success)
    }

    @Test func timeoutRemainsDistinctWhenStateWasNotSatisfied() {
        let result = DiskutilOperator.classifyOperationResult(
            processResult: processResult(exitCode: SIGTERM, reason: .timeout, timedOut: true),
            operation: .eject(force: false),
            reconciledState: .mounted,
            resolvedBSDName: "disk7s1"
        )
        #expect(result.outcome == .timedOut)
        #expect(result.timedOut)
        #expect(result.success == false)
    }

    @Test func launchFailureRemainsDistinct() {
        let result = DiskutilOperator.classifyOperationResult(
            processResult: processResult(exitCode: nil, reason: .launchFailure),
            operation: .mount,
            reconciledState: .unmounted,
            resolvedBSDName: "disk7s1"
        )
        #expect(result.outcome == .launchFailed)
    }

    @Test func processRunnerReportsLaunchFailure() {
        let runner = DiskutilOperator.ProcessRunner(executableURL: URL(fileURLWithPath: "/private/tmp/ejectify-does-not-exist"))
        let result = runner.run(arguments: [], standardInput: nil, timeout: 0.1)
        #expect(result.terminationReason == .launchFailure)
        #expect(result.exitCode == nil)
    }

    @Test func processRunnerTimesOutAndBoundsOutput() {
        let runner = DiskutilOperator.ProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/yes"))
        let result = runner.run(arguments: [], standardInput: nil, timeout: 0.05)
        #expect(result.timedOut)
        #expect(result.terminationReason == .timeout)
        #expect(result.stdout.count <= DiskutilOperator.ProcessRunner.maximumRetainedOutputBytes)
        #expect(result.stderr.count <= DiskutilOperator.ProcessRunner.maximumRetainedOutputBytes)
    }

    @Test func unlockPassphraseUsesOnlyStandardInput() {
        let runner = RecordingRunner(result: processResult(exitCode: 0, stdout: successUnlockPlist()))
        let result = DiskutilOperator.unlockResolved(
            bsdName: "disk7s1",
            password: "secret passphrase",
            runner: runner,
            timeout: 60
        )

        #expect(result.success)
        #expect(runner.arguments == ["apfs", "unlockVolume", "disk7s1", "-stdinpassphrase", "-plist"])
        #expect(runner.arguments.contains(where: { $0.contains("secret") }) == false)
        #expect(runner.standardInput == Data("secret passphrase\n".utf8))
        #expect(runner.timeout == 60)
    }

    @Test func unlockPreservesStructuredRateLimitMetadata() {
        let output = try! PropertyListSerialization.data(
            fromPropertyList: [
                "Success": false,
                "DiskManagementErrorCode": -69591,
                "RateLimitStateBackoff": true,
                "RateLimitStateLockout": false
            ],
            format: .xml,
            options: 0
        )
        let runner = RecordingRunner(result: processResult(exitCode: 1, stdout: output))
        let result = DiskutilOperator.unlockResolved(
            bsdName: "disk7s1",
            password: "secret",
            runner: runner,
            timeout: 60
        )

        #expect(result.outcome == .failed)
        #expect(result.metadata.diskManagementErrorCode == -69591)
        #expect(result.metadata.rateLimitBackoff == true)
        #expect(result.metadata.rateLimitLockout == false)
    }

    private func processResult(
        exitCode: Int32?,
        reason: DiskutilOperator.TerminationReason = .exit,
        timedOut: Bool = false,
        stdout: Data = Data(),
        stderr: Data = Data()
    ) -> DiskutilOperator.ProcessResult {
        DiskutilOperator.ProcessResult(
            exitCode: exitCode,
            terminationReason: reason,
            durationMilliseconds: 12,
            timedOut: timedOut,
            stdout: stdout,
            stderr: stderr
        )
    }

    private func successUnlockPlist() -> Data {
        try! PropertyListSerialization.data(
            fromPropertyList: ["Success": true],
            format: .xml,
            options: 0
        )
    }
}

private final class RecordingRunner: DiskutilOperator.ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let result: DiskutilOperator.ProcessResult
    private var argumentsStorage: [String] = []
    private var standardInputStorage: Data?
    private var timeoutStorage: TimeInterval = 0

    init(result: DiskutilOperator.ProcessResult) {
        self.result = result
    }

    var arguments: [String] {
        lock.withLock { argumentsStorage }
    }

    var standardInput: Data? {
        lock.withLock { standardInputStorage }
    }

    var timeout: TimeInterval {
        lock.withLock { timeoutStorage }
    }

    func run(arguments: [String], standardInput: Data?, timeout: TimeInterval) -> DiskutilOperator.ProcessResult {
        lock.withLock {
            argumentsStorage = arguments
            standardInputStorage = standardInput
            timeoutStorage = timeout
        }
        return result
    }
}
