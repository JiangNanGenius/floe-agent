// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeManufacturingParameters

public enum ManufacturingParameterScope: Hashable, Sendable {
    case study, tool(String), operation(String)
}

/// A descriptor's binding is relative to its selected owner. Unrelated and
/// future metadata is preserved, without projecting study-wide settings onto
/// every tool or operation.
public extension ManufacturingStudy {
    func parameterSnapshot(scope:ManufacturingParameterScope,catalog:ManufacturingParameterCatalog = .standard) -> ManufacturingParameterSet {
        if scope == .study { return parameterSnapshot(catalog:catalog) }
        var set:ManufacturingParameterSet
        switch scope {
        case .tool(let id): set = cam?.tools.first { $0.id == id }?.parameters ?? .init()
        case .operation(let id): set = cam?.operations.first { $0.id == id }?.parameters ?? .init()
        case .study: set = .init()
        }
        for d in catalog.parameters {
            if let binding = d.binding, let value = boundParameter(binding,scope:scope) { set.set(d.id,value) }
        }
        return set
    }
    func boundParameter(_ key:String,scope:ManufacturingParameterScope) -> ManufacturingParameterValue? {
        switch scope {
        case .study: return boundParameter(key)
        case .tool(let id):
            guard key.hasPrefix("camTool."), let tool = cam?.tools.first(where:{ $0.id == id }) else { return nil }
            return ParameterProjection.get(tool,path:String(key.dropFirst("camTool.".count)))
        case .operation(let id):
            guard key.hasPrefix("camOperation."), let op = cam?.operations.first(where:{ $0.id == id }) else { return nil }
            return ParameterProjection.get(op,path:String(key.dropFirst("camOperation.".count)))
        }
    }
    func applyingParameters(_ set:ManufacturingParameterSet,scope:ManufacturingParameterScope,catalog:ManufacturingParameterCatalog = .standard) throws -> Self {
        if scope == .study { return try applyingParameters(set,catalog:catalog) }
        try Self.checkParameterSet(set,catalog:catalog)
        var draft = self, stored = set
        switch scope {
        case .tool(let id):
            guard let index = draft.cam?.tools.firstIndex(where:{ $0.id == id }), var tool = draft.cam?.tools[index] else { throw ManufacturingError.invalid("tool owner no longer exists") }
            for d in catalog.parameters {
                guard let binding = d.binding, binding.hasPrefix("camTool."), let value = set.value(d.id) else { continue }
                let path = String(binding.dropFirst("camTool.".count))
                if path.hasPrefix("assembly."), tool.assembly == nil { continue }
                tool = try ParameterProjection.setting(tool,path:path,value:value); stored.remove(d.id)
            }
            tool.parameters = stored; draft.cam?.tools[index] = tool
        case .operation(let id):
            guard let index = draft.cam?.operations.firstIndex(where:{ $0.id == id }), var op = draft.cam?.operations[index] else { throw ManufacturingError.invalid("operation owner no longer exists") }
            for d in catalog.parameters {
                guard let binding = d.binding, binding.hasPrefix("camOperation."), let value = set.value(d.id) else { continue }
                let path = String(binding.dropFirst("camOperation.".count))
                if path.hasPrefix("cutting."), op.cutting == nil { continue }
                op = try ParameterProjection.setting(op,path:path,value:value); stored.remove(d.id)
            }
            op.parameters = stored; draft.cam?.operations[index] = op
        case .study: break
        }
        try draft.validate(requireOperations:false); return draft
    }
    func includesParameter(_ descriptor:ManufacturingParameterDescriptor,scope:ManufacturingParameterScope) -> Bool {
        switch scope {
        case .study: return !["camTool","camOperation"].contains(descriptor.groupID)
        case .tool: return ["camTool","tool"].contains(descriptor.groupID)
        case .operation: return ["camOperation","feeds","milling","motion","millingOps","holes","threads","fiveAxis","export"].contains(descriptor.groupID)
        }
    }
    /// Dynamic support accounts for the selected strategy, in addition to
    /// whether the field is stored in a typed owner.
    func parameterIsActive(_ descriptor:ManufacturingParameterDescriptor,scope:ManufacturingParameterScope) -> Bool {
        guard descriptor.support == .previewUsed, let key = descriptor.binding, boundParameter(key,scope:scope) != nil else { return false }
        if scope == .study {
            if key == "stock.radiusMM" { return !stock.isBox }
            if key == "stock.minMM" || key == "stock.maxMM" { return stock.isBox }
            if key.hasPrefix("turningSetup.") {
                if ["turningSetup.horizontalFeedMMPerMinute","turningSetup.verticalFeedMMPerMinute"].contains(key) { return turning.enabled && turningCutting?.feedMode != .mmPerRevolution }
                return turning.enabled
            }
            if key.hasPrefix("turningCutting.") {
                if key == "turningCutting.spindleRPM" { return turning.enabled && turningCutting?.spindleMode == .fixedRPM }
                if key == "turningCutting.surfaceSpeedMPerMinute" { return turning.enabled && turningCutting?.spindleMode == .constantSurfaceSpeed }
                if key == "turningCutting.feedMMPerRevolution" { return turning.enabled && turningCutting?.feedMode == .mmPerRevolution }
                return turning.enabled
            }
        }
        if case .operation(let id) = scope, let op = cam?.operations.first(where:{ $0.id == id }) {
            guard op.enabled else { return false }
            let field = String(key.dropFirst("camOperation.".count))
            if field == "dwellSeconds" { return op.strategy == "drill" && op.cycle == "counterBore" }
            if field == "peckDepthMM" { return op.strategy == "drill" && ["peck","chipBreak"].contains(op.cycle) }
            if field == "chipBreakRetractMM" { return op.strategy == "drill" && op.cycle == "chipBreak" }
            if ["cycle","holesUVMM","breakThroughMM"].contains(field) { return op.strategy == "drill" || (field == "breakThroughMM" && ["pocket","contour"].contains(op.strategy)) }
            if field == "depthMM" || field == "stepDownMM" { return op.strategy != "surfaceRaster" && op.strategy != "drill" || (field == "depthMM" && op.strategy == "drill") }
            if field == "stepOverMM" { return ["face","pocket","surfaceRaster","swarf"].contains(op.strategy) }
            if field == "climb" || field == "springPasses" { return op.strategy == "contour" }
            if field == "centerUVMM", op.strategy == "swarf" { return true }
            if ["centerUVMM","radiusMM"].contains(field) { return ["pocket","contour"].contains(op.strategy) && op.contourUVMM.isEmpty }
            if field == "contourUVMM" { return op.strategy == "contour" && !op.contourUVMM.isEmpty }
            if ["minUVMM","maxUVMM"].contains(field) { return ["face","surfaceRaster"].contains(op.strategy) }
            if field == "wallStockMM" { return ["pocket","contour","surfaceRaster"].contains(op.strategy) }
            if field == "floorStockMM" { return ["face","pocket","contour"].contains(op.strategy) }
            if field == "cutting.feedPerToothMM" { return op.cutting?.mode == "perTooth" }
            if field == "cutting.feedPerRevolutionMM" { return op.cutting?.mode == "perRevolution" }
            if field == "feedMMPerMinute" { return op.cutting == nil || op.cutting?.mode == "perMinute" }
        }
        if case .tool(let id) = scope, let tool = cam?.tools.first(where:{ $0.id == id }), key == "camTool.tipAngleDegrees" { return tool.kind == "drill" }
        return true
    }
}

enum ParameterProjection {
    static func get<T:Encodable>(_ value:T,path:String) -> ManufacturingParameterValue? {
        guard let data = try? ManufacturingStudy.encoder.encode(value), let object = try? JSONSerialization.jsonObject(with:data) else { return nil }
        var current:Any = object
        for part in path.split(separator:".") {
            guard let next = (current as? [String:Any])?[String(part)] else { return nil }; current = next
        }
        guard let raw = try? JSONSerialization.data(withJSONObject:current,options:.fragmentsAllowed) else { return nil }
        return try? .fromRawJSON(raw)
    }
    static func setting<T:Codable>(_ value:T,path:String,value replacement:ManufacturingParameterValue) throws -> T {
        var object = try JSONSerialization.jsonObject(with:ManufacturingStudy.encoder.encode(value)) as! [String:Any]
        func patch(_ object:inout [String:Any],_ parts:ArraySlice<String>) throws {
            guard let first = parts.first else { throw ManufacturingError.invalid("empty parameter binding") }
            if parts.count == 1 { object[first] = plain(replacement); return }
            guard var nested = object[first] as? [String:Any] else { throw ManufacturingError.invalid("inactive parameter owner: "+path) }
            try patch(&nested,parts.dropFirst()); object[first] = nested
        }
        try patch(&object,ArraySlice(path.split(separator:".").map(String.init)))
        return try JSONDecoder().decode(T.self,from:JSONSerialization.data(withJSONObject:object,options:.sortedKeys))
    }
    private static func plain(_ value:ManufacturingParameterValue) -> Any {
        switch value {
        case .number(let x): return x
        case .integer(let x): return x
        case .boolean(let x): return x
        case .string(let x): return x
        case .array(let xs): return xs.map(plain)
        case .object(let xs): return xs.mapValues(plain)
        case .null: return NSNull()
        }
    }
}
