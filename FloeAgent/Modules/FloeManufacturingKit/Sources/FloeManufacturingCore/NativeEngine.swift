// SPDX-License-Identifier: MPL-2.0
import Foundation
import TurningNative
import FloeMachiningNative
import Darwin

public final class ComputationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastReport = 0.0
    private var lastPhase = ""
    private let progress: @Sendable (Double, String) -> Void
    private let parent: ComputationControl?
    public init(parent:ComputationControl? = nil,progress: @escaping @Sendable (Double,String) -> Void = { _,_ in }) { self.progress = progress;self.parent = parent }
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } || parent?.isCancelled == true }
    public func report(_ value: Double, _ phase: String) -> Int32 {
        if isCancelled { return 1 }
        let now = Date.timeIntervalSinceReferenceDate
        let deliver = lock.withLock {
            if now-lastReport >= 0.04 || phase != lastPhase || value >= 1 { lastReport = now; lastPhase = phase; return true }
            return false
        }
        if deliver { progress(value.isFinite ? min(1,max(0,value)) : 0,phase) }
        return isCancelled ? 1 : 0
    }
    public func check() throws { if isCancelled { throw ManufacturingError.cancelled } }
}

public protocol ManufacturingComputing: Sendable {
    func compute(_ study: ManufacturingStudy, control: ComputationControl) throws -> ManufacturingArtifact
}

let nativeProgress: @convention(c) (UnsafeMutableRawPointer?,Double,UnsafePointer<CChar>?) -> Int32 = { context, fraction, phase in
    guard let context else { return 1 }
    let control = Unmanaged<ComputationControl>.fromOpaque(context).takeUnretainedValue()
    return control.report(fraction,phase.map { String(cString: $0) } ?? "calculate")
}

public struct NativeManufacturingEngine: ManufacturingComputing {
    public init() {}
    public func compute(_ study: ManufacturingStudy, control: ComputationControl) throws -> ManufacturingArtifact {
        try compute(study,startingStock:nil,control:control)
    }
    /// Continue the same part without rebuilding its original stock. Toolpaths
    /// and material remain in part coordinates across spindle transfers.
    public func compute(_ study: ManufacturingStudy, startingStock: ManufacturingStockState?, control: ComputationControl) throws -> ManufacturingArtifact {
        try study.validate(); try control.check()
        try startingStock?.validateFreshContinuation(for:study)
        let start = Date()
        let fingerprint = try study.fingerprint()
        let context = Unmanaged.passUnretained(control).toOpaque()
        var nativeStudy = study
        nativeStudy.parameters = nil // Stored process metadata is not native input.
        nativeStudy.turningCutting = nil // Swift evaluates the speed law over the native cutting paths.
        nativeStudy.cam = (study.cam?.enabledOperations.isEmpty ?? true) ? nil : try study.cam?.nativeInput()
        let input = try nativeStudy.encoded()
        var request = try JSONSerialization.jsonObject(with: input) as! [String:Any]
        if let startingStock {
            request["initialStockState"] = try JSONSerialization.jsonObject(with:ManufacturingStudy.encoder.encode(startingStock))
        }
        var turningWarnings = [String]()
        var turningReceipt:TurningSetup.Receipt?
        if study.turning.enabled {
            var plannerStudy = nativeStudy
            if study.turningApproach == .negativeZ {
                plannerStudy.profile = nativeStudy.profile.reversed().map { .init($0.radiusMM,-$0.zMM) }
                plannerStudy.stock.zMinMM = -nativeStudy.stock.zMaxMM
                plannerStudy.stock.zMaxMM = -nativeStudy.stock.zMinMM
            }
            let planningInput = try plannerStudy.encoded()
            let plan = try String(decoding:planningInput,as:UTF8.self).withCString { json -> Data in
                guard let response = fm_turn_plan(json,nativeProgress,context) else { throw ManufacturingError.native("empty turning response") }
                defer { fm_turn_free(response) }
                return try checkedReply(response)
            }
            try control.check()
            var object = try JSONSerialization.jsonObject(with: plan) as! [String:Any]
            if study.turningApproach == .negativeZ {
                guard var paths = object["paths"] as? [[String:Any]] else { throw ManufacturingError.native("negative-Z turning plan shape") }
                for i in paths.indices {
                    guard let points = paths[i]["points"] as? [[Double]],points.allSatisfy({ $0.count == 2 }) else { throw ManufacturingError.native("negative-Z turning path coordinates") }
                    paths[i]["points"] = points.map { [$0[0],-$0[1]] }
                }
                object["paths"] = paths
                turningWarnings.append("Turning planned in the opposite axial frame; mapped into immutable part coordinates. Insert angles remain in the local machining frame.")
            }
            if let expected = study.turningSetup {
                guard let receipt = object["setupReceipt"] else { throw ManufacturingError.native("turning setup receipt missing; update native component") }
                turningReceipt = try JSONDecoder().decode(TurningSetup.Receipt.self,from:JSONSerialization.data(withJSONObject:receipt))
                try turningReceipt?.validate(expected:expected)
            }
            request["turningPlan"] = object
            turningWarnings += object["warnings"] as? [String] ?? []
        } else { request["turningPlan"] = ["ok":true,"paths":[],"warnings":[],"backend":"turning-disabled"] }
        let payload = try JSONSerialization.data(withJSONObject: request,options: [.sortedKeys])
        let output = try String(decoding:payload,as:UTF8.self).withCString { json -> Data in
            guard let response = fm_core_execute(json,nativeProgress,context) else { throw ManufacturingError.native("empty core response") }
            defer { fm_core_free(response) }
            return try checkedReply(response)
        }
        try control.check()
        var result = try JSONDecoder().decode(ManufacturingResult.self,from: output)
        // Only a fresh native execution requires this capability. Archived R1-R9
        // results retain their original mesh and remain readable without migration.
        guard result.capabilities.contains("declared-stock-boundary-v1") else {
            throw ManufacturingError.native("Rebuild the native component with the declared stock boundary correction; the bundled library is older than this source")
        }
        for i in result.paths.indices {
            if result.paths[i].kind.hasPrefix("turning-") { result.paths[i].toolID = study.turningToolID }
            else if result.paths[i].kind == "milling-slot" { result.paths[i].toolID = study.millingToolID }
        }
        result.turningSetupReceipt = turningReceipt
        result.processAssessment = try (study.isProcessAssessmentEnabled ? study.processRequirements : nil).map { try TurningProcessAssessment.evaluate(study:study,requirements:$0) }
        if (study.turningCutting != nil && study.turning.enabled) || !(study.cam?.enabledOperations.isEmpty ?? true) {
            result.cuttingTimeline = try CuttingTimeline.plan(paths:result.paths,study:study,checkCancellation:{ try control.check() })
            if study.turning.enabled, study.turningCutting?.feedMode == .mmPerRevolution {
                for index in result.paths.indices where result.paths[index].kind.hasPrefix("turning-") { result.paths[index].feedMMPerMinute = nil }
            }
            if study.turningCutting != nil { result.capabilities.append("native-swift-turning-css-feed-per-revolution-cutting-time") }
            if !(study.cam?.enabledOperations.isEmpty ?? true) {
                result.capabilities.append("native-swift-explicit-cam-linear-motion-and-dwell-time")
                result.warnings.append("Nominal time includes explicit linear moves and dwell. Excludes missing links, acceleration, spindle transients, tool changes and rotary-axis time. Stock playback uses operation snapshots.")
            } else {
                result.warnings.append("Nominal cutting time includes only supplied linear cutting paths; excludes rapid links, acceleration, spindle transients, tool changes and A/C motion time.")
            }
        }
        for warning in turningWarnings where !result.warnings.contains(warning) { result.warnings.append(warning) }
        try result.validate(for: study)
        if let startingStock {
            guard let end = result.stockState else { throw ManufacturingError.native("native component cannot continue remaining material") }
            try end.validateContinuation(from:startingStock)
            guard abs(result.initialMM3-startingStock.remainingMM3) < max(0.01,result.initialMM3*1e-8) else {
                throw ManufacturingError.native("native component reset remaining material")
            }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        return .init(studyID:study.id,inputSHA256:fingerprint,result:result,elapsedSeconds:Date().timeIntervalSince(start),processPeakBytes:UInt64(max(0,usage.ru_maxrss)),startingStockSHA256:try startingStock?.fingerprint())
    }
    public func acMotion(_ request: ManufacturingStudy.ACMotion, control: ComputationControl = .init()) throws -> [ManufacturingResult.Pose] {
        let data = try ManufacturingStudy.encoder.encode(request)
        let context = Unmanaged.passUnretained(control).toOpaque()
        let output = try String(decoding:data,as:UTF8.self).withCString { json -> Data in
            guard let response = fm_core_ac(json,nativeProgress,context) else { throw ManufacturingError.native("empty AC response") }
            defer { fm_core_free(response) }; return try checkedReply(response)
        }
        struct Reply: Decodable { var poses: [ManufacturingResult.Pose] }
        try control.check()
        return try JSONDecoder().decode(Reply.self,from: output).poses
    }
    func checkedReply(_ pointer: UnsafeMutablePointer<CChar>) throws -> Data {
        // Bound the scan before constructing a Swift String/Data copy. Native
        // result buffers are valid NUL-terminated C strings by the thin ABI.
        let length = strnlen(pointer,64_000_001)
        guard length <= 64_000_000 else { throw ManufacturingError.native("native response exceeds the 64 MB output budget") }
        let data = Data(bytes:pointer,count:length)
        struct Reply: Decodable { var ok: Bool; var error: String? }
        let reply = try JSONDecoder().decode(Reply.self,from:data)
        guard reply.ok else {
            if ["cancelled","canceled"].contains(reply.error?.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() ?? "") { throw ManufacturingError.cancelled }
            throw ManufacturingError.native(reply.error ?? "unknown native error")
        }
        return data
    }
}

/// Service owns native work. A view cancellation requests cooperative cancellation,
/// then the task remains alive until the synchronous native function has returned.
public actor ManufacturingService {
    private let engine: any ManufacturingComputing
    private var controls: [UUID:ComputationControl] = [:]
    public init(engine: any ManufacturingComputing = NativeManufacturingEngine()) { self.engine = engine }
    public func calculate(_ study: ManufacturingStudy, progress: @escaping @Sendable (Double,String)->Void = { _,_ in }) async throws -> ManufacturingArtifact {
        try study.validate()
        let id = UUID(), control = ComputationControl(progress: progress)
        controls[id] = control
        defer { controls.removeValue(forKey:id) }
        let engine = self.engine
        return try await withTaskCancellationHandler {
            let value = try await Task.detached(priority:.userInitiated) { try engine.compute(study,control:control) }.value
            try control.check(); try Task.checkCancellation()
            guard value.studyID == study.id, value.inputSHA256 == (try study.fingerprint()) else { throw ManufacturingError.stale }
            try value.result.validate(for:study)
            return value
        } onCancel: { control.cancel() }
    }
    public func cancelAll() { for control in controls.values { control.cancel() } }
    public var activeCount: Int { controls.count }
}
