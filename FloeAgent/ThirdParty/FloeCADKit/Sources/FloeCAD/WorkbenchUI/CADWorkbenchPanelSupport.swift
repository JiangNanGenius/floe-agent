//
//  CADWorkbenchPanelSupport.swift
//  FloeCADKit
//
//  Shared building blocks for the Floe-owned workbench panels: number fields
//  with validation, body option lists and Euler<->quaternion conversion used by
//  the assembly transform editor. All panels use these instead of ad-hoc
//  TextFields so numeric input is parsed with one contract.
//
//  SPDX-License-Identifier: MPL-2.0
//

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import simd

/// One selectable document body (id + display name) for panel pickers.
struct CADPanelBodyOption: Identifiable, Hashable {
    let id: UUID
    let name: String
}

/// A validated numeric field: keeps its text, exposes a parsed Double, and
/// shows an inline invalid state. Empty text is `nil` when `allowsEmpty`.
struct CADPanelNumberField: View {
    let title: String
    @Binding var text: String
    var allowsEmpty = false
    var unit: String? = nil
    var identifier: String? = nil

    private var parsed: Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return allowsEmpty ? nil : 0 }
        return Double(trimmed)
    }

    private var isValid: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return allowsEmpty }
        return Double(trimmed) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField("0", text: $text)
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 56)
                    .accessibilityIdentifier(identifier ?? "CADNumber-\(title)")
                if let unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !isValid {
                Text(FloeCADStrings.text("cad.panel.invalidNumber", "Enter a number"))
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// Axis presets used by the assembly constraint editor: explicit, named
/// directions instead of raw vectors (a manual user cannot type quaternions).
enum CADPanelAxisPreset: String, CaseIterable, Identifiable {
    case xPlus, xMinus, yPlus, yMinus, zPlus, zMinus

    var id: String { rawValue }

    var label: String {
        switch self {
        case .xPlus: return "+X"
        case .xMinus: return "−X"
        case .yPlus: return "+Y"
        case .yMinus: return "−Y"
        case .zPlus: return "+Z"
        case .zMinus: return "−Z"
        }
    }

    var vector: SIMD3<Double> {
        switch self {
        case .xPlus: return SIMD3(1, 0, 0)
        case .xMinus: return SIMD3(-1, 0, 0)
        case .yPlus: return SIMD3(0, 1, 0)
        case .yMinus: return SIMD3(0, -1, 0)
        case .zPlus: return SIMD3(0, 0, 1)
        case .zMinus: return SIMD3(0, 0, -1)
        }
    }
}

enum CADPanelTransform {
    /// Quaternion from Euler angles in degrees applied X, then Y, then Z
    /// (extrinsic; R = Rz·Ry·Rx), matching `eulerDegrees(quaternion:)`.
    static func quaternion(eulerDegrees degrees: SIMD3<Double>) -> SIMD4<Double> {
        let (x, y, z) = (degrees.x * .pi / 180 / 2,
                         degrees.y * .pi / 180 / 2,
                         degrees.z * .pi / 180 / 2)
        let (sx, cx) = (sin(x), cos(x))
        let (sy, cy) = (sin(y), cos(y))
        let (sz, cz) = (sin(z), cos(z))
        var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        q = simd_quatd(ix: cx, iy: sx, iz: 0, r: 0) * q
        q = simd_quatd(ix: cy, iy: 0, iz: sy, r: 0) * q
        q = simd_quatd(ix: cz, iy: 0, iz: 0, r: sz) * q
        return SIMD4(q.imag.x, q.imag.y, q.imag.z, q.real)
    }

    /// X→Y→Z Euler angles in degrees from a quaternion (best-effort for the
    /// editor's initial values).
    static func eulerDegrees(quaternion q: SIMD4<Double>) -> SIMD3<Double> {
        let length = simd_length(q)
        guard length > 1e-12 else { return .zero }
        let normalized = simd_quatd(ix: q.x / length, iy: q.y / length,
                                    iz: q.z / length, r: q.w / length)
        let matrix = simd_double3x3(normalized)
        // R = Rz·Ry·Rx (X applied first); rows/cols from the simd columns.
        let sy = -matrix.columns.0.z
        let y = asin(max(-1, min(1, sy)))
        let x: Double
        let z: Double
        if abs(sy) < 0.9999 {
            x = atan2(matrix.columns.1.z, matrix.columns.2.z)
            z = atan2(matrix.columns.0.y, matrix.columns.0.x)
        } else {
            x = atan2(-matrix.columns.2.y, matrix.columns.1.y)
            z = 0
        }
        return SIMD3(x * 180 / .pi, y * 180 / .pi, z * 180 / .pi)
    }

    static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

extension FloeCADDocument {
    /// Bodies as panel options, document order.
    var panelBodyOptions: [CADPanelBodyOption] {
        session.document.bodies.map { CADPanelBodyOption(id: $0.id.raw, name: $0.name) }
    }
}
#endif
