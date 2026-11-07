// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Machine families backed by the current native single-spindle engines.
/// A family does not imply a manufacturer's complete collision model.
public struct ManufacturingMachineSetup: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case lathe, milling3Axis, milling5AxisAC, turnMill
    }
    public var kind: Kind
    public var coordinateFrame: ManufacturingCAM.Frame
    public init(kind: Kind, coordinateFrame: ManufacturingCAM.Frame = .init()) {
        self.kind = kind; self.coordinateFrame = coordinateFrame
    }
}

public extension ManufacturingStudy {
    /// Applies the selected executable machine family, rather than saving a
    /// display-only picker. Disabled CAM operations remain available to edit.
    func applyingMachineSetup(_ setup: ManufacturingMachineSetup) throws -> Self {
        try setup.coordinateFrame.validate()
        var value = self
        value.machineSetup = setup
        switch setup.kind {
        case .lathe, .turnMill:
            let bounds = stock.bounds
            value.stock.radiusMM = max(stock.radiusMM, hypot(max(abs(bounds.min[0]), abs(bounds.max[0])), max(abs(bounds.min[1]), abs(bounds.max[1]))))
            value.stock.shape = nil; value.stock.minMM = nil; value.stock.maxMM = nil
            let b = value.stock.bounds
            while zip(b.min,b.max).reduce(1.0, { $0 * (ceil(($1.1-$1.0)/value.stock.resolutionMM)+1) }) > Double(value.budget.maxCells), value.stock.resolutionMM < 4 {
                value.stock.resolutionMM = min(4, value.stock.resolutionMM * 1.1)
            }
            value.turning.enabled = true
            value = try value.applyingTurningSetup(value.configuredTurningSetup, enabled: true)
            value.milling.enabled = false
            value.acMotion = nil
            for index in value.cam?.operations.indices ?? (0..<0) {
                value.cam?.operations[index].acSeed = nil
                if setup.kind == .turnMill { value.cam?.operations[index].frame = setup.coordinateFrame }
                if setup.kind == .lathe { value.cam?.operations[index].enabled = false }
            }
        case .milling3Axis, .milling5AxisAC:
            value.turning.enabled = false; value.milling.enabled = false
            value.acMotion = nil
            for index in value.cam?.operations.indices ?? (0..<0) {
                value.cam?.operations[index].frame = setup.coordinateFrame
                value.cam?.operations[index].acSeed = setup.kind == .milling5AxisAC ? [0,0,50,0,0] : nil
            }
            if setup.kind == .milling5AxisAC {
                for index in value.cam?.tools.indices ?? (0..<0) {
                    if value.cam?.tools[index].gaugeLengthMM == nil { value.cam?.tools[index].gaugeLengthMM = 50 }
                }
            }
        }
        try value.validate(requireOperations: false)
        return value
    }
}
