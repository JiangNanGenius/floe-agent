import Foundation
import XCTest
@testable import FloeExecution

final class ARM64MachineConfigurationTests: XCTestCase {
    private final class Headroom: @unchecked Sendable {
        let lock = NSLock()
        private var bytes = Int.max
        func set(_ value: Int) { lock.withLock { bytes = value } }
        func get() -> Int { lock.withLock { bytes } }
    }

    func testLiveMemoryGrowRefusesLowHeadroomWithoutChangingTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firmware = root.appendingPathComponent("loop.bin")
        let loop = Data([0, 0, 0, 0x14]) // ARM64 B .; interpreted, never host executable code.
        try loop.write(to: firmware)
        let disk = root.appendingPathComponent("disk.raw")
        try Data(repeating: 0, count: 4096).write(to: disk)
        let headroom = Headroom()
        let machine = try ARM64GuestMachine(ownership: .init(label: "memory-grow-admission"),
            config: .init(firmware: .init(path: firmware.path, sha256: SHA256Hex.ofData(loop)),
                privateWritableDiskPath: disk.path, ramMiB: 512, possibleVCPUs: 1,
                onlineMemoryEnabled: true), headroomProbe: { headroom.get() })
        try machine.start()
        do {
            let deadline = Date().addingTimeInterval(5)
            while machine.state == .starting, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(machine.state, .running)
            headroom.set(0)
            do {
                _ = try await machine.setMemoryBudget(768)
                XCTFail("Live growth must refuse exhausted process headroom")
            } catch {
                guard case .createFailed(let code, _) = error as? ARM64MachineError else { throw error }
                XCTAssertEqual(code, -6)
            }
            let unchanged = try await machine.memoryBudget()
            XCTAssertEqual(unchanged.targetMiB, 512)
            headroom.set(Int.max)
            let grown = try await machine.setMemoryBudget(768)
            XCTAssertEqual(grown.targetMiB, 768)
            XCTAssertEqual(grown.pluggedMiB, 256, "Without a Linux driver no managed blocks were plugged")
            XCTAssertEqual(machine.state, .running)
        } catch {
            _ = await machine.stop()
            throw error
        }
        _ = await machine.stop()
    }

    func testGPUPreferenceSurvivesOlderJSONAndCPUOnlyChanges() async throws {
        let older = try JSONDecoder().decode(LinuxGuestLifecycleConfig.self,
            from: Data(#"{"vcpus":2,"memoryMB":512}"#.utf8))
        XCTAssertEqual(older.resolvedGPUMemoryMB, 1024)
        XCTAssertEqual(older, .init(vcpus: 2, memoryMB: 512, gpuMemoryMB: 1024))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = ARM64ResidentGuestSessionFactory(root: root)
        try await factory.configureSharedMachine(.init(vcpus: 2, memoryMB: 512, gpuMemoryMB: 1536))
        try await factory.configureSharedMachine(.init(vcpus: 3, memoryMB: 512))
        XCTAssertEqual(factory.preferredSharedConfiguration?.resolvedGPUMemoryMB, 1536)
        let reopened = ARM64ResidentGuestSessionFactory(root: root)
        XCTAssertEqual(reopened.preferredSharedConfiguration?.resolvedGPUMemoryMB, 1536)
        for invalid in [0, 2049] {
            do {
                try await factory.configureSharedMachine(.init(vcpus: 3, memoryMB: 512, gpuMemoryMB: invalid))
                XCTFail("Invalid GPU limit was accepted")
            } catch {}
            XCTAssertEqual(factory.preferredSharedConfiguration?.resolvedGPUMemoryMB, 1536)
        }
        await factory.shutdown()
        await reopened.shutdown()
    }

    private func configuration() -> ARM64MachineConfig {
        .init(firmware: .init(path: "/missing-qualification-firmware", sha256: String(repeating: "a", count: 64)),
              privateWritableDiskPath: "/missing-private-disk", ramMiB: 32, possibleVCPUs: 1)
    }

    func testOptionalRendererPolicyOnlyAppliesWhenADeviceIsRequested() {
        var config = configuration()
        config.gpuAllowsCPUFallback = true
        XCTAssertEqual(ARM64StagedConfig(config).cConfig.gpu.reserved.0, 0)
        config.gpuEnabled = true
        XCTAssertNotEqual(ARM64StagedConfig(config).cConfig.gpu.reserved.0, 0)
        config.gpuAllowsCPUFallback = false
        XCTAssertEqual(ARM64StagedConfig(config).cConfig.gpu.reserved.0, 0)
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
