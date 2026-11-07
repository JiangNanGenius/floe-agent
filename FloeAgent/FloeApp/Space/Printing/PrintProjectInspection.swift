// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeTools

struct PrintObjectGeometryInspection: Codable, Sendable {
    let objectID: UUID
    let plateID: UUID
    let meshAsset: String
    let meshSHA256: String?
    let triangleCount: Int?
    let minimum: [Double]?
    let maximum: [Double]?
    let sizeMM: [Double]?
    let unavailableReason: String?
}
struct PrintGeometryInspection: Codable, Sendable {
    let revision: UInt64
    let units: String
    let coordinateSpace: String
    let complete: Bool
    let objects: [PrintObjectGeometryInspection]
}

extension PrintProjectSession {
    /// Measure the verified immutable mesh actually referenced by each object.
    /// Names and source dimensions never substitute for the current geometry.
    func inspectionData(cancellation: CancellationToken) async throws -> Data {
        let frozen = document
        var rows: [PrintObjectGeometryInspection] = []
        var measured: [String: (hash: String, triangles: Int, low: [Double], high: [Double])] = [:]
        var inspectedBytes = 0
        var complete = true
        for object in frozen.objects ?? [] {
            try cancellation.throwIfCancelled(); try Task.checkCancellation()
            var reason: String?
            if measured[object.meshAsset] == nil {
                if inspectedBytes >= 128 * 1_024 * 1_024 { reason = "The 128 MiB inspection budget was reached. This object's dimensions have not been measured." }
                else {
                    do {
                        let mesh = try await disk.meshAsset(object.meshAsset)
                        inspectedBytes += mesh.positions.count * MemoryLayout<Float>.stride
                        let b = Self.bounds(mesh)
                        measured[object.meshAsset] = (mesh.sha256, mesh.positions.count / 9, b.low, b.high)
                    } catch {
                        if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
                        reason = "The stored mesh could not be verified: " + error.localizedDescription
                    }
                }
            }
            let value = measured[object.meshAsset]
            if value == nil { complete = false }
            rows.append(.init(objectID: object.id, plateID: object.plateID, meshAsset: object.meshAsset,
                meshSHA256: value?.hash, triangleCount: value?.triangles, minimum: value?.low,
                maximum: value?.high, sizeMM: value.map { zip($0.high, $0.low).map { $0.0 - $0.1 } }, unavailableReason: reason))
        }
        try cancellation.throwIfCancelled(); try Task.checkCancellation()
        guard document.revision == frozen.revision else { throw PersonalContentError.changedDocument }
        var resolved = frozen
        resolved.processSettings = Self.resolvedProcessSettings(frozen.processSettings, preset: frozen.preset)
        guard var state = try JSONSerialization.jsonObject(with: StudioToolOutput.data(resolved)) as? [String: Any] else {
            throw PersonalContentError.invalidProject
        }
        let geometry = PrintGeometryInspection(revision: frozen.revision, units: "mm",
            coordinateSpace: "Bed-centred XY, Z above the bed. Object transforms are baked into each immutable mesh. Dimensions describe that mesh, including its current orientation; no transform is inferred from its name.",
            complete: complete, objects: rows)
        state["geometry"] = try JSONSerialization.jsonObject(with: StudioToolOutput.data(geometry))
        state["resultIsCurrent"] = resultIsCurrent
        state["needsSlicing"] = !resultIsCurrent
        return try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
    }
}
#endif
