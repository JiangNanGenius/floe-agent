import Foundation
import XCTest
@testable import FloeExecution

final class ARM64MachineConfigurationTests: XCTestCase {
    private func configuration() -> ARM64MachineConfig {
        .init(firmware: .init(path: "/missing-qualification-firmware", sha256: String(repeating: "a", count: 64)),
              privateWritableDiskPath: "/missing-private-disk", ramMiB: 32, possibleVCPUs: 1)
    }

    func testInvalidMachineShapeIsRefusedWithoutClamping() throws {
        var config = configuration()
        for cores in [0, 6] {
            config.possibleVCPUs = cores
            XCTAssertThrowsError(try config.validated())
        }
        config.possibleVCPUs = 1
        for ram in [0, 1025] {
            config.ramMiB = ram
            XCTAssertThrowsError(try config.validated())
        }
    }

    func testZeroHeadroomRefusesBeforeWorkerOrAssetAccess() throws {
        let machine = try ARM64GuestMachine(ownership: .init(label: "headroom-test"),
            config: configuration(), headroomProbe: { 0 })
        XCTAssertThrowsError(try machine.start()) { error in
            guard case .createFailed(let code, _) = error as? ARM64MachineError else {
                return XCTFail("Expected recoverable allocation refusal, got \(error)")
            }
            XCTAssertEqual(code, -6)
        }
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.currentGeneration, 0)
    }

    func testSharedResourceSettingsAreDurableAndBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = ARM64ResidentGuestSessionFactory(root: root)
        try await factory.configureSharedMachine(.init(vcpus: 3, memoryMB: 1024))
        XCTAssertEqual(factory.preferredSharedConfiguration, .init(vcpus: 3, memoryMB: 1024))
        // The shared runtime supports four online CPUs. Its spare internal
        // CPU slot does not expand the user-facing configuration boundary.
        let fourCores = LinuxGuestLifecycleConfig(vcpus: 4, memoryMB: 1024)
        try await factory.configureSharedMachine(fourCores)
        XCTAssertEqual(factory.preferredSharedConfiguration, fourCores)
        let reopened = ARM64ResidentGuestSessionFactory(root: root)
        XCTAssertEqual(reopened.preferredSharedConfiguration, fourCores)
        for cores in [0, 5] {
            do {
                try await factory.configureSharedMachine(.init(vcpus: cores, memoryMB: 1024))
                XCTFail("Out-of-range core count must fail: \(cores)")
            } catch {}
            XCTAssertEqual(factory.preferredSharedConfiguration, fourCores)
        }
        do {
            try await factory.configureSharedMachine(.init(vcpus: 4, memoryMB: 2048))
            XCTFail("Memory beyond the engine boundary must fail")
        } catch {}
        XCTAssertEqual(reopened.preferredSharedConfiguration, fourCores)
        await factory.shutdown()
        await reopened.shutdown()
    }
}
