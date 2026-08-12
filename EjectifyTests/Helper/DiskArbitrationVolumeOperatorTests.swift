//
//  DiskArbitrationVolumeOperatorTests.swift
//  EjectifyTests
//
//  Created by Codex on 12/08/2026.
//

@preconcurrency import DiskArbitration
import Testing

struct DiskArbitrationVolumeOperatorTests {

    @Test func normalEjectSkipsExplicitUnmount() {
        var operations: [String] = []

        let result = DiskArbitrationVolumeOperator.performEjectSequence(
            forceUnmount: false,
            unmountWholeDisk: {
                operations.append("unmount")
                return successfulResult()
            },
            eject: {
                operations.append("eject")
                return successfulResult()
            }
        )

        #expect(result.success)
        #expect(operations == ["eject"])
    }

    @Test func forcedUnmountCompletesBeforeEject() {
        var operations: [String] = []

        let result = DiskArbitrationVolumeOperator.performEjectSequence(
            forceUnmount: true,
            unmountWholeDisk: {
                operations.append("unmount")
                return successfulResult()
            },
            eject: {
                operations.append("eject")
                return successfulResult()
            }
        )

        #expect(result.success)
        #expect(result.message == "Forced whole-disk unmount completed before eject")
        #expect(operations == ["unmount", "eject"])
    }

    @Test func forcedUnmountFailurePreventsEject() {
        var didRequestEject = false
        let busyStatus = DAReturn(kDAReturnBusy)

        let result = DiskArbitrationVolumeOperator.performEjectSequence(
            forceUnmount: true,
            unmountWholeDisk: {
                operationResult(success: false, message: "Disk is busy", status: busyStatus)
            },
            eject: {
                didRequestEject = true
                return successfulResult()
            }
        )

        #expect(result.success == false)
        #expect(didRequestEject == false)
        #expect(result.message == "Forced whole-disk unmount before eject failed: Disk is busy")
        #expect(result.status == busyStatus)
    }

    @Test func alreadyUnmountedForceEjectPreparationContinuesWithEject() {
        var didRequestEject = false

        let result = DiskArbitrationVolumeOperator.performEjectSequence(
            forceUnmount: true,
            unmountWholeDisk: {
                operationResult(
                    success: false,
                    message: "Disk is not mounted",
                    status: Int32(kDAReturnNotMounted)
                )
            },
            eject: {
                didRequestEject = true
                return successfulResult()
            }
        )

        #expect(result.success)
        #expect(didRequestEject)
    }

    @Test func forcedUnmountTimeoutPreventsEject() {
        var didRequestEject = false

        let result = DiskArbitrationVolumeOperator.performEjectSequence(
            forceUnmount: true,
            unmountWholeDisk: {
                operationResult(success: false, message: "forced whole-disk unmount timed out")
            },
            eject: {
                didRequestEject = true
                return successfulResult()
            }
        )

        #expect(result.success == false)
        #expect(didRequestEject == false)
        #expect(result.message == "Forced whole-disk unmount before eject failed: forced whole-disk unmount timed out")
        #expect(result.status == nil)
    }

    @Test func ejectFailureAfterForcedUnmountIsPreserved() {
        let unsupportedStatus = DAReturn(kDAReturnUnsupported)

        let result = DiskArbitrationVolumeOperator.performEjectSequence(
            forceUnmount: true,
            unmountWholeDisk: successfulResult,
            eject: {
                operationResult(success: false, message: "Eject was rejected", status: unsupportedStatus)
            }
        )

        #expect(result.success == false)
        #expect(result.message == "Eject after forced whole-disk unmount failed: Eject was rejected")
        #expect(result.status == unsupportedStatus)
    }

    @Test func forcedEjectPreparationUsesForceAndWholeDiskOptions() {
        let options = DiskArbitrationVolumeOperator.forcedEjectUnmountOptions

        #expect(options & DADiskUnmountOptions(kDADiskUnmountOptionForce) != 0)
        #expect(options & DADiskUnmountOptions(kDADiskUnmountOptionWhole) != 0)
        #expect(options == DADiskUnmountOptions(kDADiskUnmountOptionForce | kDADiskUnmountOptionWhole))
    }

    /// Creates a successful operation result for sequence tests.
    private func successfulResult() -> DiskArbitrationVolumeOperator.OperationResult {
        operationResult(success: true)
    }

    /// Creates an operation result with concise defaults for sequence tests.
    private func operationResult(
        success: Bool,
        message: String? = nil,
        status: DAReturn? = nil
    ) -> DiskArbitrationVolumeOperator.OperationResult {
        DiskArbitrationVolumeOperator.OperationResult(
            success: success,
            message: message,
            status: status
        )
    }
}
