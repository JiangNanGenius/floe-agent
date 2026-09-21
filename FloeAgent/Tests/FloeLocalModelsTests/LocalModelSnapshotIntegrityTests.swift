// SPDX-License-Identifier: MPL-2.0
//
// Focused tests for the MLX snapshot diagnostics added by the next repair
// slice: deterministic snapshot damage (so "broken files" is not reported as
// "not enough memory"), the load-failure classifier, and the process-wide
// reservation accounting that keeps a local model from being admitted on top
// of a running TinyEMU Linux guest. No MLX container, GPU or real weights are
// involved.

import Foundation
import Testing
import FloeCore
import FloeLocalModelCatalog
import FloeLocalModels

private func makeSafetensors(at url: URL, dataBytes: Int, declaredBytes: Int? = nil, valid: Bool = true) throws {
    let declared = declaredBytes ?? dataBytes
    let header: [String: Any] = valid
        ? ["weight": ["dtype": "F32", "shape": [declared / 4], "data_offsets": [0, declared]]]
        : ["weight": ["dtype": "F32", "shape": [declared / 4], "data_offsets": [0, declared]]]
    let headerData = try JSONSerialization.data(withJSONObject: header)
    var file = Data()
    var length = UInt64(headerData.count).littleEndian
    withUnsafeBytes(of: &length) { file.append(contentsOf: $0) }
    file.append(headerData)
    file.append(Data(repeating: 0, count: dataBytes))
    try file.write(to: url)
}

private func makeSnapshot(directory: URL, dataBytes: Int = 64, declaredBytes: Int? = nil) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try makeSafetensors(at: directory.appendingPathComponent("model.safetensors"), dataBytes: dataBytes, declaredBytes: declaredBytes)
    let config: [String: Any] = ["model_type": "qwen3_5"]
    try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("config.json"))
}

@Suite("LocalModelSnapshotIntegrity")
struct LocalModelSnapshotIntegrityTests {
    @Test("A healthy snapshot has no deterministic problems")
    func healthySnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSnapshot(directory: root)
        #expect(LocalModelSnapshotIntegrity.problems(directory: root, entry: nil).isEmpty)
    }

    @Test("Tensor extents beyond the file are reported as corruption")
    func truncatedTensorData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // Header declares 4096 data bytes; the file only carries 16.
        try makeSnapshot(directory: root, dataBytes: 16, declaredBytes: 4096)
        let problems = LocalModelSnapshotIntegrity.problems(directory: root, entry: nil)
        #expect(problems.count == 1)
        if case .tensorOutOfBounds(_, let tensor) = problems.first {
            #expect(tensor == "weight")
        } else {
            Issue.record("expected tensorOutOfBounds, got \(problems)")
        }
    }

    @Test("A pinned artifact size mismatch is corruption, not memory pressure")
    func catalogSizeMismatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSnapshot(directory: root)
        // The real, selectable entry: a snapshot that kept a valid header but
        // lost bytes (restored from a backup, partial copy) must be reported as
        // a size mismatch rather than being handed to MLX and failing with a
        // generic code 0.
        let entry = try #require(CuratedLocalModelCatalog.entries.first)
        let problems = LocalModelSnapshotIntegrity.problems(directory: root, entry: entry)
        #expect(problems.contains { problem in
            if case .sizeMismatch = problem { return true }
            return false
        })
        // config.json is present and supported, so it is not reported.
        #expect(!problems.contains { problem in
            if case .invalidHeader = problem { return true }
            return false
        })
    }

    @Test("Missing files and unsupported architectures are separate problems")
    func missingAndUnsupported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(LocalModelSnapshotIntegrity.problems(directory: root, entry: nil)
            .contains { if case .missingArtifact = $0 { return true }; return false })
        let config: [String: Any] = ["model_type": "not_a_floe_model"]
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("config.json"))
        #expect(LocalModelSnapshotIntegrity.problems(directory: root, entry: nil)
            .contains { if case .unsupportedModelType = $0 { return true }; return false })
    }
}

@Suite("LocalModelLoadFailure")
struct LocalModelLoadFailureTests {
    @Test("Memory hints classify as insufficient memory")
    func memoryHint() {
        let error = NSError(domain: "MLX.MLXError", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "Failed to allocate 3 GB: out of memory"
        ])
        #expect(LocalModelLoadFailure.classify(error: error, mappedBytes: 3_000, headroomBytes: 4_000)
            == .insufficientMemory(required: 3_000, physical: 4_000))
    }

    @Test("A model larger than the headroom classifies as insufficient memory even without a hint")
    func sizeOverrunsHeadroom() {
        let error = NSError(domain: "MLX.MLXError", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "MLX container initialization failed"
        ])
        #expect(LocalModelLoadFailure.classify(error: error, mappedBytes: 5_000, headroomBytes: 4_000)
            == .insufficientMemory(required: 5_000, physical: 4_000))
    }

    @Test("Deterministic snapshot damage wins over a memory verdict")
    func snapshotWins() {
        let error = NSError(domain: "MLX.MLXError", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "allocation failed"
        ])
        let kind = LocalModelLoadFailure.classify(
            error: error,
            snapshotProblems: [.truncatedHeader(artifact: "model.safetensors")],
            mappedBytes: 5_000,
            headroomBytes: 1_000
        )
        guard case .corruptSnapshot(let reason) = kind else {
            Issue.record("expected corruptSnapshot, got \(kind)")
            return
        }
        #expect(reason.contains("model.safetensors"))
    }

    @Test("An unrecognized failure keeps its domain and code")
    func unknownKeepsClassAndCode() {
        let error = NSError(domain: "MLX.MLXError", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "unsupported operation"
        ])
        #expect(LocalModelLoadFailure.classify(error: error, mappedBytes: 1, headroomBytes: 1_000)
            == .unknown("domain MLX.MLXError, code 7"))
    }
}

@Suite("ResidentMemoryReservations", .serialized)
struct ResidentMemoryReservationTests {
    @Test("Reservations replace, clear and sum by owner")
    func reservationAccounting() {
        ResidentMemoryReservations.removeAll()
        defer { ResidentMemoryReservations.removeAll() }
        #expect(ResidentMemoryReservations.totalBytes() == 0)

        ResidentMemoryReservations.set(id: "linux-guest:a", bytes: 256 * 1_048_576)
        #expect(ResidentMemoryReservations.totalBytes() == 268_435_456)

        // Re-setting the same owner replaces instead of stacking.
        ResidentMemoryReservations.set(id: "linux-guest:a", bytes: 512 * 1_048_576)
        #expect(ResidentMemoryReservations.totalBytes() == 536_870_912)

        ResidentMemoryReservations.set(id: "linux-guest:b", bytes: 128 * 1_048_576)
        #expect(ResidentMemoryReservations.totalBytes() == 671_088_640)

        ResidentMemoryReservations.clear(id: "linux-guest:a")
        #expect(ResidentMemoryReservations.totalBytes() == 134_217_728)
        ResidentMemoryReservations.clear(id: "linux-guest:b")
        #expect(ResidentMemoryReservations.totalBytes() == 0)
    }

    @Test("A live reservation shrinks the local-model allowance")
    func reservationShrinksHeadroom() {
        ResidentMemoryReservations.removeAll()
        defer { ResidentMemoryReservations.removeAll() }
        let gib: UInt64 = 1_073_741_824
        // Without the guest a 3.03 GB snapshot fits an 8 GiB allowance.
        #expect(LocalInferenceResourcePolicy.canLoad(
            mappedBytes: 3_034_300_695,
            physicalMemoryBytes: 8 * gib
        ))
        // A full 1.5 GB guest budget makes the same load impossible.
        ResidentMemoryReservations.set(id: "linux-guest:test", bytes: Int64(1536 * 1_048_576))
        #expect(!LocalInferenceResourcePolicy.canLoad(
            mappedBytes: 3_034_300_695,
            physicalMemoryBytes: 4 * gib
        ))
        #expect(ResidentMemoryReservations.reservedBytes(id: "linux-guest:test") == 1_610_612_736)
    }
}
