//
//  KernelCaptureReplay.swift
//  openshape3d — replay a capture bundle (docs/FREECAD_PLAYBOOK.md D3)
//
//  Runs a `KernelCapture` bundle back through the SAME `OCCTKernel` entry
//  points the app uses, so a failure captured live becomes an offline,
//  single-command reproduction — and, dropped into
//  openshape3dTests/Fixtures/Captures, a permanent regression test
//  (`KernelCaptureReplayTests`). FreeCAD's equivalent is the frozen-`.brep`
//  regression pattern: a failing shape from a real model, committed next to
//  the test and replayed through the same op.
//
//  Inputs load through `shapeFromSerializedForDiagnostics:` — NO healing —
//  because the replay must hand the op exactly what the failing op saw.
//

import OCCTShim
import Foundation

#if DEBUG

nonisolated enum KernelCaptureReplay {

    nonisolated struct Outcome {
        let op: String
        let succeeded: Bool
        /// Typed error on failure; result health on success (a replay that
        /// "succeeds" with an invalid or wrong-volume result is still a bug,
        /// which is why the outcome carries more than a Bool).
        let detail: String
        let volumeMM3: Double?
    }

    nonisolated enum ReplayError: Error, CustomStringConvertible {
        case badBundle(String)
        var description: String {
            switch self { case let .badBundle(reason): return reason }
        }
    }

    static func manifest(bundleAt bundle: URL) throws -> [String: Any] {
        let url = bundle.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else {
            throw ReplayError.badBundle(
                "no readable manifest.json in \(bundle.lastPathComponent)")
        }
        return manifest
    }

    static func replay(bundleAt bundle: URL) throws -> Outcome {
        let manifest = try manifest(bundleAt: bundle)
        guard let op = manifest["op"] as? String else {
            throw ReplayError.badBundle("manifest names no op")
        }
        let params = manifest["params"] as? [String: Any] ?? [:]

        var inputs: [String: BRepHandle] = [:]
        var order: [String] = []
        for row in manifest["inputs"] as? [[String: Any]] ?? [] {
            guard let label = row["label"] as? String,
                  let file = row["file"] as? String else { continue }
            guard let blob = try? Data(contentsOf: bundle.appendingPathComponent(file)) else {
                throw ReplayError.badBundle("input file \(file) is missing")
            }
            guard let shape = OCCTBridge.rawShape(fromSerialized: blob) else {
                throw ReplayError.badBundle("input file \(file) does not deserialize")
            }
            inputs[label] = BRepHandle(shape)
            order.append(label)
        }

        func input(_ label: String) throws -> BRepHandle {
            guard let handle = inputs[label] else {
                throw ReplayError.badBundle("manifest names no '\(label)' input")
            }
            return handle
        }
        func number(_ key: String) throws -> Double {
            guard let value = params[key] as? Double else {
                throw ReplayError.badBundle("params.\(key) is missing")
            }
            return value
        }
        func points() -> [SIMD3<Double>] {
            (params["points"] as? [[Double]] ?? []).compactMap {
                $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil
            }
        }

        switch op {
        case "boolean":
            let code = params["op"] as? Int ?? 0
            return outcome(op, OCCTKernel.booleanResult(
                try input("a"), try input("b"), op: code).map(\.handle))
        case "fillet":
            // Identity-addressed captures carry edgeIndices; point-matched
            // captures carry points + tolerance. Replay whichever was used.
            if let indices = params["edgeIndices"] as? [Int] {
                return outcome(op, OCCTKernel.filletResult(
                    try input("shape"), edgeIndices: indices,
                    radius: try number("radius")))
            }
            return outcome(op, OCCTKernel.filletResult(
                try input("shape"), at: points(),
                radius: try number("radius"), tolerance: try number("tolerance")))
        case "chamfer":
            if let indices = params["edgeIndices"] as? [Int] {
                return outcome(op, OCCTKernel.chamferResult(
                    try input("shape"), edgeIndices: indices,
                    distance: try number("distance")))
            }
            return outcome(op, OCCTKernel.chamferResult(
                try input("shape"), at: points(),
                distance: try number("distance"), tolerance: try number("tolerance")))
        case "shell":
            return outcome(op, OCCTKernel.shellResult(
                try input("shape"), openingAt: points(),
                thickness: try number("thickness"), tolerance: try number("tolerance")))
        case "removeFaces":
            return outcome(op, OCCTKernel.removingFacesResult(
                try input("shape"), at: points(), tolerance: try number("tolerance")))
        case "snapshot":
            // A snapshot has no op to re-run; replaying it means health-
            // checking every captured body, which is what you took it FOR.
            let reports = order.compactMap { label in
                inputs[label].map { (label, OCCTKernel.healthReport(for: $0)) }
            }
            let sick = reports.filter { !$0.1.isValid }
            let detail = sick.isEmpty
                ? "\(reports.count) bodies, all valid"
                : sick.map { "\($0.0): \($0.1.findingsSummary)" }.joined(separator: " | ")
            return Outcome(op: op, succeeded: sick.isEmpty,
                           detail: detail, volumeMM3: nil)
        default:
            throw ReplayError.badBundle("unsupported op '\(op)'")
        }
    }

    private static func outcome(_ op: String,
                                _ result: Result<BRepHandle, OCCTOpError>) -> Outcome {
        switch result {
        case let .success(handle):
            let health = OCCTKernel.healthReport(for: handle)
            return Outcome(
                op: op, succeeded: true,
                detail: health.isValid
                    ? "valid result"
                    : "INVALID result: \(health.findingsSummary)",
                volumeMM3: OCCTKernel.volume(handle))
        case let .failure(error):
            return Outcome(op: op, succeeded: false,
                           detail: String(describing: error), volumeMM3: nil)
        }
    }
}

#endif
