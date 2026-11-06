// SPDX-License-Identifier: MPL-2.0 AND MIT
// The linear beam-segment deflection polynomial below is adapted from
// PyNiteFEA 3.2.1, Pynite/BeamSegZ.py (P_delta=False, constant transverse load).
// https://github.com/JWock82/Pynite
// The local solver specializes its boundary conditions to ONE prismatic
// rectangular Euler-Bernoulli beam. No Python/FEM runtime is embedded.
//
// MIT License — Copyright (c) 2018 D. Craig Brinck
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation

public nonisolated enum CADBuildingLocalAnalysis {
    /// A worker-safe, in-process calculation. The caller owns document identity,
    /// result persistence and a thread-safe cancellation signal. Returns the
    /// `analysis` and `backendVersions` fragment of the former study result.
    public static func evaluate(input: Data,
                                cancelled: @escaping @Sendable () -> Bool = { false }) throws -> Data {
        let request = try CADBuildingLocalStudyInput.read(input, action: "structure", cancelled: cancelled)
        let settings = request.structural
        guard let id = settings.memberID,
              let member = request.model.elements.first(where: { $0.id == id && $0.kind == .beam }) else {
            throw CADBuildingLocalComputationError.invalid("Choose an authored beam for this single-member study.")
        }
        let span = member.lengthMM, width = member.thicknessMM, depth = member.heightMM
        let elasticModulus = settings.elasticModulusNPerMM2, poisson = settings.poissonRatio
        let load = settings.lineLoadNPerMM
        guard [span, width, depth, elasticModulus].allSatisfy({ $0.isFinite && (1...1e7).contains($0) }),
              poisson.isFinite, (0..<0.5).contains(poisson),
              load.isFinite, (0.000001...1e6).contains(load) else {
            throw CADBuildingLocalComputationError.invalid("Use positive beam dimensions, elastic modulus and uniform load, with Poisson ratio from zero to less than 0.5.")
        }
        try CADBuildingLocalStudyInput.checkCancellation(cancelled)
        let inertia = width * depth * depth * depth / 12
        let rigidity = elasticModulus * inertia
        let totalLoad = load * span
        let simple = settings.support == .simplySupported
        let reactionA = simple ? totalLoad / 2 : totalLoad
        let reactionB = simple ? totalLoad / 2 : 0
        let supportMoment = simple ? 0 : load * span * span / 2
        let initialSlope = simple ? -load * span * span * span / (24 * rigidity) : 0
        let criticalX = simple ? span / 2 : span

        // PyNite's linear BeamSegZ polynomial, with w1=w2=-load. Positive
        // local Y is upward; a downward uniform load gives negative dy.
        func displacement(_ x: Double) -> Double {
            if x == 0 || (simple && x == span) { return 0 }
            let x2 = x * x
            return initialSlope * x + reactionA * x2 * x / (6 * rigidity)
                - load * x2 * x2 / (24 * rigidity) - supportMoment * x2 / (2 * rigidity)
        }
        let minimum = displacement(criticalX)
        let reactionSum = reactionA + reactionB
        let maximumMoment = simple ? load * span * span / 8 : supportMoment
        let maximumStress = maximumMoment * depth / (2 * inertia)
        guard minimum.isFinite, abs(minimum) <= 1e15, maximumStress.isFinite,
              abs(reactionSum - totalLoad) <= max(1e-5, totalLoad * 1e-8) else {
            throw CADBuildingLocalComputationError.invalid("The beam result is outside the bounded linear calculation or failed equilibrium.")
        }
        var diagram: [[String: Double]] = []
        for index in 0...16 {
            try CADBuildingLocalStudyInput.checkCancellation(cancelled)
            let x = span * Double(index) / 16
            diagram.append(["xMM": x, "dyMM": displacement(x)])
        }
        var assumptions = ["one straight prismatic rectangular beam", "linear elastic Euler-Bernoulli bending",
                           "uniform downward load over the full span", "authored centre line and section dimensions"]
        if span / depth < 10 { assumptions.append("short/deep beam: omitted shear deformation can be significant") }
        if abs(minimum) / span > 0.01 { assumptions.append("deflection exceeds one percent of span: small-deflection assumption may be unsuitable") }
        let analysis: [String: Any] = [
            "scope": "one rectangular beam with explicitly authored material, supports and uniform load",
            "memberID": id.uuidString, "support": settings.support.rawValue,
            "spanMM": span, "lineLoadNPerMM": load, "minimumDeflectionMM": minimum,
            "minimumDeflectionAtMM": criticalX, "reactionSumN": reactionSum,
            "reactionAN": reactionA, "reactionBN": reactionB, "supportMomentAMagnitudeNMM": supportMoment,
            "elasticModulusNPerMM2": elasticModulus, "poissonRatio": poisson,
            "shearModulusNPerMM2": elasticModulus / (2 * (1 + poisson)),
            "sectionWidthMM": width, "sectionDepthMM": depth, "sectionInertiaMM4": inertia,
            "maximumMomentMagnitudeNMM": maximumMoment, "maximumBendingStressNPerMM2": maximumStress,
            "deflectionSamples": diagram, "assumptions": assumptions,
            "shearDeformationIncluded": false, "meshGeometryUsedForSection": false,
            "wholeBuildingAnalysis": false, "designCodeApproval": false
        ]
        try CADBuildingLocalStudyInput.checkCancellation(cancelled)
        return try JSONSerialization.data(withJSONObject: ["analysis": analysis,
            "backendVersions": ["FloeBeam": "Euler-Bernoulli-UDL-1", "PyNitePolynomial": "3.2.1-MIT-adaptation"]], options: .sortedKeys)
    }
}

public nonisolated enum CADBuildingLocalComputationError: Error, LocalizedError, Sendable {
    case invalid(String), budget(String), geometry(String), timedOut
    public var code: String {
        switch self {
        case .invalid: return "invalid_local_building_input"
        case .budget: return "local_building_budget_exceeded"
        case .geometry: return "local_building_geometry_refused"
        case .timedOut: return "timeout"
        }
    }
    public var errorDescription: String? {
        switch self {
        case let .invalid(message), let .budget(message), let .geometry(message): return message
        case .timedOut: return "The local coordination reached its time limit. Split the study into fewer elements."
        }
    }
}

/// The existing input.json contract, decoded without filesystem or executable
/// inputs. Shared only by the two native numerical adapters in this module.
nonisolated struct CADBuildingLocalStudyInput: Decodable, Sendable {
    static let maximumInputBytes = 64 * 1024 * 1024
    static let maximumTriangles = 500_000
    let schemaVersion: Int
    let action: String
    let revision: Int
    let changeCount: Int
    let modelSHA256: String
    let model: CADBuildingDocument
    let geometry: [Geometry]
    let structural: CADBuildingStructuralSettings

    nonisolated struct Geometry: Decodable, Sendable {
        let elementID: UUID
        let bodyID: UUID
        let verticesM: [[Double]]
        let indices: [UInt32]
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, action, revision, changeCount, modelSHA256, model, geometry, structural
    }
    private nonisolated struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyKey.self)
        let allowed: Set<String> = ["schemaVersion", "action", "revision", "changeCount", "modelSHA256", "model", "geometry", "structural"]
        guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
            throw CADBuildingLocalComputationError.invalid("This local study contains unknown input fields.")
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        action = try container.decode(String.self, forKey: .action)
        revision = try container.decode(Int.self, forKey: .revision)
        changeCount = try container.decode(Int.self, forKey: .changeCount)
        modelSHA256 = try container.decode(String.self, forKey: .modelSHA256)
        model = try container.decode(CADBuildingDocument.self, forKey: .model)
        geometry = try container.decode([Geometry].self, forKey: .geometry)
        if container.contains(.structural) {
            let settings = try container.nestedContainer(keyedBy: AnyKey.self, forKey: .structural)
            let fields: Set<String> = ["memberID", "support", "elasticModulusNPerMM2", "poissonRatio", "lineLoadNPerMM"]
            guard Set(settings.allKeys.map(\.stringValue)).isSubset(of: fields) else {
                throw CADBuildingLocalComputationError.invalid("This local study contains unsupported structural settings.")
            }
            structural = try container.decode(CADBuildingStructuralSettings.self, forKey: .structural)
        } else { structural = CADBuildingStructuralSettings() }
    }
    static func read(_ data: Data, action expected: String,
                     cancelled: @Sendable () -> Bool) throws -> Self {
        try checkCancellation(cancelled)
        guard !data.isEmpty, data.count <= maximumInputBytes else {
            throw CADBuildingLocalComputationError.budget("The local study input exceeds 64 MiB.")
        }
        let request = try JSONDecoder().decode(Self.self, from: data)
        try checkCancellation(cancelled)
        guard request.schemaVersion == 1, request.action == expected,
              request.revision >= 0, request.changeCount >= 0,
              request.geometry.count <= 4_096 else {
            throw CADBuildingLocalComputationError.invalid("Unsupported local study version, action or geometry count.")
        }
        try request.model.validate()
        guard Set(request.geometry.map(\.bodyID)).count == request.geometry.count else {
            throw CADBuildingLocalComputationError.invalid("The geometry contains duplicate body identities.")
        }
        var total = 0, totalVertices = 0
        let identities = Set(request.model.elements.map(\.id))
        for mesh in request.geometry {
            try checkCancellation(cancelled)
            guard identities.contains(mesh.elementID), !mesh.verticesM.isEmpty,
                  mesh.verticesM.count <= 1_500_000, !mesh.indices.isEmpty, mesh.indices.count % 3 == 0 else {
                throw CADBuildingLocalComputationError.invalid("The study contains empty, unowned or incomplete mesh geometry.")
            }
            total += mesh.indices.count / 3
            totalVertices += mesh.verticesM.count
            guard total <= maximumTriangles, totalVertices <= 1_500_000 else {
                throw CADBuildingLocalComputationError.budget("The local study exceeds 500,000 triangles or 1,500,000 vertices.")
            }
            for (index, point) in mesh.verticesM.enumerated() {
                if index % 512 == 0 { try checkCancellation(cancelled) }
                guard point.count == 3, point.allSatisfy({ $0.isFinite && abs($0) <= 1e6 }) else {
                    throw CADBuildingLocalComputationError.invalid("The study contains invalid metre coordinates.")
                }
            }
            for (offset, index) in mesh.indices.enumerated() {
                if offset % 1_536 == 0 { try checkCancellation(cancelled) }
                guard Int(index) < mesh.verticesM.count else {
                    throw CADBuildingLocalComputationError.invalid("The study references a missing mesh vertex.")
                }
            }
        }
        return request
    }
    static func checkCancellation(_ cancelled: @Sendable () -> Bool) throws {
        if cancelled() || Task.isCancelled { throw CancellationError() }
    }
}
