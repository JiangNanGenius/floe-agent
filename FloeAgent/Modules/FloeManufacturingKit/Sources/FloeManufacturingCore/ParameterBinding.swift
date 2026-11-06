// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeManufacturingParameters

extension ManufacturingStudy {
    private static var doubleParameters: [String:WritableKeyPath<Self,Double>] { [
        "stock.radiusMM": \.stock.radiusMM, "stock.zMinMM": \.stock.zMinMM,
        "stock.zMaxMM": \.stock.zMaxMM, "stock.resolutionMM": \.stock.resolutionMM,
        "turning.stepOverMM": \.turning.stepOverMM, "turning.allowanceMM": \.turning.allowanceMM,
        "turning.feedMMPerMinute": \.turning.feedMMPerMinute,
        "milling.angleDegrees": \.milling.angleDegrees, "milling.widthMM": \.milling.widthMM,
        "milling.depthMM": \.milling.depthMM, "milling.startZMM": \.milling.startZMM,
        "milling.endZMM": \.milling.endZMM, "milling.toolRadiusMM": \.milling.toolRadiusMM,
        "milling.toolLengthMM": \.milling.toolLengthMM, "milling.feedMMPerMinute": \.milling.feedMMPerMinute
    ] }
    private static var integerParameters: [String:WritableKeyPath<Self,Int>] { [
        "turning.finishPasses": \.turning.finishPasses,
        "budget.maxCells": \.budget.maxCells, "budget.maxPoses": \.budget.maxPoses,
        "budget.maxTriangles": \.budget.maxTriangles
    ] }
    private static var booleanParameters: [String:WritableKeyPath<Self,Bool>] { [
        "turning.enabled": \.turning.enabled, "milling.enabled": \.milling.enabled
    ] }
    public func boundParameter(_ key: String) -> ManufacturingParameterValue? {
        if key == "stock.shape" { return .string(stock.shape ?? "cylinder") }
        if key == "stock.minMM" || key == "stock.maxMM" { return ParameterProjection.get(stock,path:String(key.dropFirst(6))) }
        if key == "budget.maxFrames" { return .integer(Int64(budget.frameLimit)) }
        if key == "budget.maxRetainedMeshBytes" { return .integer(Int64(budget.retainedMeshByteLimit)) }
        if key.hasPrefix("turningSetup."), let turningSetup { return ParameterProjection.get(turningSetup,path:String(key.dropFirst("turningSetup.".count))) }
        if key.hasPrefix("turningCutting."), let cutting = turningCutting {
            switch key {
            case "turningCutting.spindleMode": return .string(cutting.spindleMode.rawValue)
            case "turningCutting.feedMode": return .string(cutting.feedMode.rawValue)
            case "turningCutting.spindleRPM": return .number(cutting.spindleRPM)
            case "turningCutting.surfaceSpeedMPerMinute": return .number(cutting.surfaceSpeedMPerMinute)
            case "turningCutting.maxSpindleRPM": return .number(cutting.maxSpindleRPM)
            case "turningCutting.feedMMPerRevolution": return .number(cutting.feedMMPerRevolution)
            default: return nil
            }
        }
        if key == "budget.maxCollisionQueries" { return .integer(Int64(budget.collisionQueryLimit)) }
        if let assembly = millingAssembly {
            if key == "millingAssembly.shankDiameterMM" { return .number(assembly.shankDiameterMM) }
            if key == "millingAssembly.holderProfile" { return .array(assembly.holderProfile.map { .array([.number($0.axialMM),.number($0.radiusMM)]) }) }
            if key == "millingAssembly.clearanceMM" { return .number(assembly.clearanceMM) }
        }
        if key == "fixtures" {
            return .array(fixtures.map { .object(["id":.string($0.id),"minMM":.array($0.minMM.map { .number($0) }),"maxMM":.array($0.maxMM.map { .number($0) })]) })
        }
        if let path = Self.doubleParameters[key] { return .number(self[keyPath:path]) }
        if let path = Self.integerParameters[key] { return .integer(Int64(self[keyPath:path])) }
        if let path = Self.booleanParameters[key] { return .boolean(self[keyPath:path]) }
        guard let motion = acMotion else { return nil }
        if key == "acMotion.toolLengthMM" { return .number(motion.toolLengthMM) }
        if key == "acMotion.steps" { return .integer(Int64(motion.steps)) }
        if key == "acMotion.start" { return .array(motion.start.map { .number($0) }) }
        if key == "acMotion.end" { return .array(motion.end.map { .number($0) }) }
        let parts = key.split(separator:".")
        if parts.count == 3, parts[0] == "acMotion", let i = Int(parts[2]), (0..<5).contains(i) {
            if parts[1] == "start", motion.start.indices.contains(i) { return .number(motion.start[i]) }
            if parts[1] == "end", motion.end.indices.contains(i) { return .number(motion.end[i]) }
        }
        return nil
    }
    public func parameterSnapshot(catalog:ManufacturingParameterCatalog = .standard) -> ManufacturingParameterSet {
        var set = parameters ?? .init()
        for descriptor in catalog.parameters {
            if let key = descriptor.binding, let value = boundParameter(key) { set.set(descriptor.id,value) }
            if descriptor.support == .fixed, let value = descriptor.defaultValue { set.set(descriptor.id,value) }
        }
        return set
    }
    public func applyingParameters(_ set:ManufacturingParameterSet,catalog:ManufacturingParameterCatalog = .standard) throws -> Self {
        try Self.checkParameterSet(set,catalog:catalog)
        var draft = self
        var stored = set
        for descriptor in catalog.parameters {
            guard let value = set.value(descriptor.id) else { continue }
            if descriptor.support == .fixed {
                guard descriptor.defaultValue == nil || Self.sameParameterValue(descriptor.defaultValue!,value) else { throw ManufacturingError.invalid("fixed prototype parameter: \(descriptor.id)") }
                stored.remove(descriptor.id)
            } else if let key = descriptor.binding {
                // Without an A/C operation these fields remain configuration only.
                if key.hasPrefix("acMotion."), draft.acMotion == nil { continue }
                if key.hasPrefix("millingAssembly."), draft.millingAssembly == nil { continue }
                if key.hasPrefix("turningCutting."), draft.turningCutting == nil { continue }
                if key.hasPrefix("turningSetup."), draft.turningSetup == nil { continue }
                if key.hasPrefix("camTool.") || key.hasPrefix("camOperation.") { continue }
                try draft.setBoundParameter(key,value)
                stored.remove(descriptor.id)
            }
        }
        draft.parameters = stored
        try draft.validate(requireOperations:false)
        return draft
    }
    private mutating func setBoundParameter(_ key:String,_ value:ManufacturingParameterValue) throws {
        if key.hasPrefix("turningSetup."), let setup = turningSetup {
            turningSetup = try ParameterProjection.setting(setup,path:String(key.dropFirst("turningSetup.".count)),value:value); return
        }
        if ["stock.shape","stock.minMM","stock.maxMM"].contains(key) {
            stock = try ParameterProjection.setting(stock,path:String(key.dropFirst("stock.".count)),value:value)
            // Omit the legacy default so untouched old archive digests remain stable.
            if stock.shape == "cylinder" { stock.shape = nil }
            return
        }
        if key == "budget.maxFrames" || key == "budget.maxRetainedMeshBytes" {
            budget = try ParameterProjection.setting(budget,path:String(key.dropFirst("budget.".count)),value:value)
            if budget.maxFrames == 8 { budget.maxFrames = nil }
            if budget.maxRetainedMeshBytes == 128_000_000 { budget.maxRetainedMeshBytes = nil }
            return
        }
        if key == "fixtures" {
            guard let items = value.arrayValue, items.count <= 16 else { throw ManufacturingError.invalid("fixture count") }
            fixtures = try items.map { item in
                guard let object = item.objectValue, Set(object.keys) == Set(["id","minMM","maxMM"]), let id = object["id"]?.stringValue,
                      let low = object["minMM"]?.arrayValue, let high = object["maxMM"]?.arrayValue,
                      low.count == 3, high.count == 3 else { throw ManufacturingError.invalid("fixture requires only id, minMM[3], maxMM[3]; keep other metadata in extension fields") }
                let minimum = low.compactMap(\.numericMagnitude), maximum = high.compactMap(\.numericMagnitude)
                guard minimum.count == 3, maximum.count == 3 else { throw ManufacturingError.invalid("numeric fixture bounds") }
                return Fixture(id:id,minMM:minimum,maxMM:maximum)
            }
            return
        }
        func number() throws -> Double {
            guard let d = value.numericMagnitude, d.isFinite else { throw ManufacturingError.invalid("numeric parameter: \(key)") }
            return d
        }
        func integer() throws -> Int {
            if let i = value.intValue, let n = Int(exactly:i) { return n }
            if let d = value.doubleValue, d.isFinite, let n = Int(exactly:d) { return n }
            throw ManufacturingError.invalid("integer parameter: \(key)")
        }
        if let path = Self.doubleParameters[key] { self[keyPath:path] = try number(); return }
        if let path = Self.integerParameters[key] { self[keyPath:path] = try integer(); return }
        if let path = Self.booleanParameters[key] {
            guard let b = value.boolValue else { throw ManufacturingError.invalid("boolean parameter: \(key)") }
            self[keyPath:path] = b; return
        }
        if key == "budget.maxCollisionQueries" { budget.maxCollisionQueries = try integer(); return }
        if key.hasPrefix("turningCutting.") {
            guard var cutting = turningCutting else { throw ManufacturingError.invalid("inactive turning speed schedule") }
            switch key {
            case "turningCutting.spindleMode":
                guard let raw = value.stringValue, let mode = TurningCuttingParameters.SpindleMode(rawValue:raw) else { throw ManufacturingError.invalid("spindle mode") }
                cutting.spindleMode = mode
            case "turningCutting.feedMode":
                guard let raw = value.stringValue, let mode = TurningCuttingParameters.FeedMode(rawValue:raw) else { throw ManufacturingError.invalid("feed mode") }
                cutting.feedMode = mode
            case "turningCutting.spindleRPM": cutting.spindleRPM = try number()
            case "turningCutting.surfaceSpeedMPerMinute": cutting.surfaceSpeedMPerMinute = try number()
            case "turningCutting.maxSpindleRPM": cutting.maxSpindleRPM = try number()
            case "turningCutting.feedMMPerRevolution": cutting.feedMMPerRevolution = try number()
            default: throw ManufacturingError.invalid("unbound turning speed parameter: \(key)")
            }
            turningCutting = cutting; return
        }
        if key.hasPrefix("millingAssembly.") {
            guard var assembly = millingAssembly else { throw ManufacturingError.invalid("inactive tool assembly") }
            switch key {
            case "millingAssembly.shankDiameterMM": assembly.shankDiameterMM = try number()
            case "millingAssembly.clearanceMM": assembly.clearanceMM = try number()
            case "millingAssembly.holderProfile":
                guard let points = value.arrayValue, (2...32).contains(points.count) else { throw ManufacturingError.invalid("holder profile count") }
                assembly.holderProfile = try points.map { point in
                    guard let pair = point.arrayValue, pair.count == 2, let axial = pair[0].numericMagnitude, let radius = pair[1].numericMagnitude else {
                        throw ManufacturingError.invalid("holder point requires [distance from tip, radius]")
                    }
                    return HolderProfilePoint(axial,radius)
                }
            default: throw ManufacturingError.invalid("unbound assembly parameter: \(key)")
            }
            millingAssembly = assembly; return
        }
        guard var motion = acMotion else { throw ManufacturingError.invalid("inactive A/C operation") }
        if key == "acMotion.toolLengthMM" { motion.toolLengthMM = try number() }
        else if key == "acMotion.steps" { motion.steps = try integer() }
        else if key == "acMotion.start" || key == "acMotion.end" {
            guard let array = value.arrayValue, array.count == 5 else { throw ManufacturingError.invalid("A/C pose requires [X,Y,Z,A,C]") }
            let values = array.compactMap(\.numericMagnitude)
            guard values.count == 5, values.allSatisfy(\.isFinite) else { throw ManufacturingError.invalid("finite A/C pose") }
            if key == "acMotion.start" { motion.start = values } else { motion.end = values }
        }
        else {
            let parts = key.split(separator:".")
            guard parts.count == 3, parts[0] == "acMotion", let i = Int(parts[2]), (0..<5).contains(i) else { throw ManufacturingError.invalid("unbound parameter: \(key)") }
            if parts[1] == "start" { motion.start[i] = try number() }
            else if parts[1] == "end" { motion.end[i] = try number() }
            else { throw ManufacturingError.invalid("unbound parameter: \(key)") }
        }
        acMotion = motion
    }
    static func checkParameterSet(_ set:ManufacturingParameterSet,catalog:ManufacturingParameterCatalog) throws {
        guard set.formatVersion == ManufacturingParameterSet.supportedFormatVersion else { throw ManufacturingError.invalid("unsupported parameter set version; keep original file") }
        guard set.values.count <= 4096, try encoder.encode(set).count <= 1_000_000 else { throw ManufacturingError.invalid("parameter storage budget") }
        let failures = set.validate(catalog:catalog).filter { $0.code != .unknownParameter }
        guard failures.isEmpty else { throw ManufacturingError.invalid(failures.prefix(4).map { "\($0.parameterID): \($0.message)" }.joined(separator:"; ")) }
    }
    func validateParameterStorage(catalog:ManufacturingParameterCatalog = .standard) throws {
        guard let parameters else { return }
        try Self.checkParameterSet(parameters,catalog:catalog)
        for descriptor in catalog.parameters {
            guard let value = parameters.value(descriptor.id) else { continue }
            if let key = descriptor.binding, let actual = boundParameter(key), !Self.sameParameterValue(value,actual) {
                throw ManufacturingError.invalid("conflicting typed field and parameter: \(descriptor.id)")
            }
            if descriptor.support == .fixed, let fixed = descriptor.defaultValue, !Self.sameParameterValue(value,fixed) {
                throw ManufacturingError.invalid("fixed prototype parameter: \(descriptor.id)")
            }
        }
    }
    static func sameParameterValue(_ a:ManufacturingParameterValue,_ b:ManufacturingParameterValue) -> Bool {
        if let x = a.numericMagnitude, let y = b.numericMagnitude { return x == y }
        if case .array(let xs) = a, case .array(let ys) = b {
            return xs.count == ys.count && zip(xs,ys).allSatisfy { sameParameterValue($0,$1) }
        }
        if case .object(let xs) = a, case .object(let ys) = b {
            return Set(xs.keys) == Set(ys.keys) && xs.allSatisfy { key,value in sameParameterValue(value,ys[key]!) }
        }
        return a == b
    }
}
