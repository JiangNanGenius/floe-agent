//
//  ShapeHealth.swift
//  openshape3d — geometry health reporting (docs/FREECAD_PLAYBOOK.md D1)
//
//  Typed Swift face of `OCCTBridge.healthReportForShape:` — the deep
//  BRepCheck/BOP validity report. The typed struct is what tests assert on;
//  the raw dictionary passthrough is what the agent bridge serves, so the
//  two can never disagree about what the kernel said.
//

import OCCTShim
import Foundation

/// A deep validity report over one solid: named per-subshape faults
/// ("Face3: notClosed"), tolerance statistics, sub-shape counts, free
/// boundary wires, and (on request) the slow BOP self-intersection check.
nonisolated struct ShapeHealth: Sendable, Equatable {
    /// One named fault. `subshape` is "Face3"/"Edge17" — a 1-based index into
    /// the shape's own indexed map of that type, so two reports over the same
    /// shape name the same offender. `context`, when present, is the parent
    /// the fault is registered against (a wire can be fine alone and
    /// self-intersecting in its face).
    nonisolated struct Finding: Sendable, Equatable {
        let subshape: String
        let type: String
        let status: String
        let context: String?
    }

    let isValid: Bool
    let findings: [Finding]
    /// True only when the BOP check was requested AND actually completed —
    /// it can be declined (invalid shape), deadline out, or throw.
    let bopCheckRan: Bool
    let bopFindings: [Finding]
    let counts: [String: Int]
    let toleranceMin: Double
    let toleranceAvg: Double
    let toleranceMax: Double
    let volumeMM3: Double
    let openFreeWires: Int
    let closedFreeWires: Int
    /// Set when the check itself failed (null shape, kernel throw) — the
    /// report then says nothing about the shape beyond `isValid == false`.
    let error: String?

    init(dictionary: [String: Any]) {
        isValid = dictionary["valid"] as? Bool ?? false
        findings = Self.findings(dictionary["findings"])
        bopCheckRan = dictionary["bopCheckRan"] as? Bool ?? false
        bopFindings = Self.findings(dictionary["bopFindings"])
        counts = dictionary["counts"] as? [String: Int] ?? [:]
        let tolerance = dictionary["tolerance"] as? [String: Double] ?? [:]
        toleranceMin = tolerance["min"] ?? 0
        toleranceAvg = tolerance["avg"] ?? 0
        toleranceMax = tolerance["max"] ?? 0
        volumeMM3 = dictionary["volumeMM3"] as? Double ?? 0
        openFreeWires = dictionary["openFreeWires"] as? Int ?? 0
        closedFreeWires = dictionary["closedFreeWires"] as? Int ?? 0
        error = dictionary["error"] as? String
    }

    private static func findings(_ value: Any?) -> [Finding] {
        guard let rows = value as? [[String: String]] else { return [] }
        return rows.compactMap { row in
            guard let subshape = row["subshape"], let type = row["type"],
                  let status = row["status"] else { return nil }
            return Finding(subshape: subshape, type: type,
                           status: status, context: row["context"])
        }
    }

    /// One line per fault, for logs and error strings:
    /// "Solid1: notClosed; Shell1 in Solid1: notClosed".
    var findingsSummary: String {
        findings.map { finding in
            let place = finding.context.map { " in \($0)" } ?? ""
            return "\(finding.subshape)\(place): \(finding.status)"
        }.joined(separator: "; ")
    }
}

nonisolated extension OCCTKernel {
    /// Deep validity report — see `ShapeHealth`. `runBOPCheck` adds the slow
    /// `BOPAlgo_ArgumentAnalyzer` pass (self-intersections, small edges…);
    /// it only runs on a shape that already passed `BRepCheck_Analyzer`,
    /// because its findings are advisory and it can take seconds.
    static func healthReport(for handle: BRepHandle,
                             runBOPCheck: Bool = false) -> ShapeHealth {
        ShapeHealth(dictionary: healthReportDictionary(for: handle,
                                                       runBOPCheck: runBOPCheck))
    }

    /// The raw JSON-safe report, exactly as the bridge produced it — what
    /// `/v1/check` serves. Kept alongside the typed accessor so the agent
    /// and the tests read the same bytes.
    static func healthReportDictionary(for handle: BRepHandle,
                                       runBOPCheck: Bool = false) -> [String: Any] {
        OCCTBridge.healthReport(for: handle.shape, runBOPCheck: runBOPCheck)
    }
}
