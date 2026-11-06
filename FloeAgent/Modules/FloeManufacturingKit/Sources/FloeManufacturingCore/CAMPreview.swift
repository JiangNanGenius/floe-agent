// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum CAMPreviewSource:Codable,Sendable {
    case study(ManufacturingStudy,ManufacturingArtifact)
    case cell(VirtualMachineProject,CellSimulationArtifact)
}

/// A portable preview retains the real source/result and optional bounded view
/// settings. Opening revalidates the source before the UI can restore a cursor.
public enum CAMPreviewArchive {
    private struct Payload:Codable { var formatVersion = 1;var source:CAMPreviewSource;var viewState:Data?;var sourceKey:String }
    private struct Envelope:Codable { var payload:Payload;var payloadSHA256:String }
    public static func save(source:CAMPreviewSource,viewState:Data? = nil,to url:URL,control:ComputationControl = .init()) throws {
        try control.check()
        guard viewState?.count ?? 0 <= 32_768 else { throw ManufacturingError.archive("CAM preview view-state budget") }
        let program = try CAMPreviewProgram(source:source,control:control)
        let payload = Payload(source:source,viewState:viewState,sourceKey:program.sourceKey)
        let envelope = Envelope(payload:payload,payloadSHA256:try ResearchArchive.digest(payload))
        let data = try ManufacturingStudy.encoder.encode(envelope)
        guard data.count<=ResearchArchive.byteLimit else { throw ManufacturingError.archive("CAM preview archive byte budget") }
        try control.check()
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:url,options:.atomic)
    }
    public static func open(_ url:URL) throws -> (source:CAMPreviewSource,viewState:Data?) {
        guard try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max <= ResearchArchive.byteLimit else { throw ManufacturingError.archive("CAM preview archive byte budget") }
        let envelope = try JSONDecoder().decode(Envelope.self,from:Data(contentsOf:url)),payload = envelope.payload
        guard payload.formatVersion == 1,payload.viewState?.count ?? 0 <= 32_768,
              envelope.payloadSHA256 == (try ResearchArchive.digest(payload)) else { throw ManufacturingError.archive("CAM preview archive identity") }
        guard payload.sourceKey == (try CAMPreviewProgram(source:payload.source).sourceKey) else { throw ManufacturingError.stale }
        return (payload.source,payload.viewState)
    }
}
public struct CAMPreviewChapter:Sendable,Identifiable {
    public var id:String
    public var name:String
    public var kind:String
    public var toolName:String?
    public var start:Double?
    public var end:Double?
    public var pathIDs:[String]
    public var jobID:String
}
public struct CAMPreviewPath:Sendable,Identifiable {
    public var id:String
    public var chapterID:String
    public var jobID:String
    public var pathIndex:Int
    public var kind:String
    public var moveType:String?
    public var pointsMM:[[Double]]
    public var frame:CellRigidTransform
    public var start:Double?
    public var end:Double?
}
public struct CAMPreviewTool:Sendable,Identifiable {
    public var id:String
    public var chapterID:String
    public var name:String
    public var tipMM:[Double]
    public var axis:[Double]
    public var pathID:String
    public var pointIndex:Int
    public var feedMMPerMinute:Double?
    public var rpm:Double?
    public var phaseDegrees:Double?
    public var turning:Bool
    public var joints:[Double]? = nil
    public var insertSetup:TurningSetup? = nil
    public var insertOutline:[[Double]]? = nil
    public var definition:ManufacturingCAM.Tool? = nil
    public var displayFrame:CellRigidTransform? = nil
    public var gaugeLengthMM:Double? = nil
    public var turningApproach:TurningApproach? = nil
}
public struct CAMPreviewFrame:Sendable {
    public var position:Double
    public var scene:VirtualScene
    public var paths:[CAMPreviewPath]
    public var tools:[CAMPreviewTool]
    public var activeChapterIDs:[String]
    public var coverage:[String]
    public var latheStock:Bool
    public var latheStockRadiusMM:Double?
    public var latheDatumZMM:Double?
    public var machine:CAMMachinePresentation? = nil
}

/// Source-bound viewing data. A timeable source uses its actual CuttingTimeline;
/// an untimed standalone source uses geometric distance, never invented seconds.
/// Each original path is separate: absent traverse geometry is never connected.
public struct CAMPreviewProgram:Sendable {
    public enum Metric:String,Sendable { case seconds,distance }
    public let source:CAMPreviewSource
    public let sourceKey:String
    public let name:String
    public let metric:Metric
    public let extent:Double
    public let chapters:[CAMPreviewChapter]
    public let paths:[CAMPreviewPath]
    public let boundaries:[Double]
    public let resolutionMM:Double
    public let warnings:[String]
    private struct Job:Sendable {
        var id:String
        var study:ManufacturingStudy
        var artifact:ManufacturingArtifact
        var displayPaths:[ManufacturingResult.Path]
        var start:Double
        var end:Double
        var worldFromWorkpiece:CellRigidTransform
        var workpieceID:String?
        var distanceSegments:[DistanceSegment]
        var phaseAtSegment:[Double]
        var insertSetup:TurningSetup
    }
    private struct DistanceSegment:Sendable {
        var pathIndex:Int;var pointIndex:Int;var start:Double;var length:Double
    }
    private let jobs:[Job]
    private let replay:VirtualCellReplay?

    // Narrow bridge for source inspection, keeping internal scheduling jobs private.
    func inspectionSource(jobID:String,pathIndex:Int)->(study:ManufacturingStudy,path:ManufacturingResult.Path,appliedTurningSetup:TurningSetup?)? {
        guard let job = jobs.first(where:{ $0.id == jobID }),job.displayPaths.indices.contains(pathIndex) else { return nil }
        return (job.study,job.displayPaths[pathIndex],job.artifact.result.turningSetupReceipt?.applied)
    }

    public init(source:CAMPreviewSource,control:ComputationControl = .init()) throws {
        self.source = source
        var jobs = [Job](),chapters = [CAMPreviewChapter](),paths = [CAMPreviewPath](),boundaries = [0.0],warnings = [String]()
        let metric:Metric,extent:Double,name:String,key:String,replay:VirtualCellReplay?
        switch source {
        case .study(let study,let artifact):
            try control.check();try study.validate()
            guard artifact.studyID == study.id,artifact.inputSHA256 == (try study.fingerprint()) else { throw ManufacturingError.stale }
            try artifact.result.validate(for:study)
            let timed = study.acMotion == nil ? artifact.result.cuttingTimeline : nil
            metric = timed == nil ? .distance : .seconds;name = study.name
            key = try ResearchArchive.digest([artifact.inputSHA256,ResearchArchive.digest(artifact)])
            let displayPaths = Self.displayPaths(artifact.result)
            let distances = Self.distances(displayPaths)
            extent = timed?.totalSeconds ?? distances.last.map { $0.start+$0.length } ?? 0
            jobs = [.init(id:"study",study:study,artifact:artifact,displayPaths:displayPaths,start:0,end:extent,worldFromWorkpiece:.identity,
                distanceSegments:distances,phaseAtSegment:Self.phaseStarts(timed),insertSetup:study.configuredTurningSetup)]
            replay = nil
            if timed == nil { warnings.append("This source has no complete time law. Playback position is geometric path distance, not machining time; no unprovided machine-axis motion is inferred.") }
        case .cell(let project,let artifact):
            try control.check();try artifact.validate(for:project.cell)
            try project.scene.validate(for:project.cell.cell)
            let value = try VirtualCellReplay(project:project.cell,artifact:artifact,control:control)
            replay = value;metric = .seconds;extent = value.durationSeconds;name = project.cell.cell.name
            key = try ResearchArchive.digest([ResearchArchive.digest(project),ResearchArchive.digest(artifact)])
            for entry in artifact.schedule.steps {
                try control.check();boundaries += [entry.startSeconds,entry.endSeconds]
                guard let step = artifact.executedCell.steps.first(where:{ $0.id == entry.stepID }) else { throw ManufacturingError.stale }
                if case .operate(let op) = step.action,let result = artifact.jobs.first(where:{ $0.stepID == entry.stepID }) {
                    jobs.append(.init(id:entry.stepID,study:op.study,artifact:result.artifact,displayPaths:Self.displayPaths(result.artifact.result),start:entry.startSeconds,end:entry.endSeconds,
                        worldFromWorkpiece:result.worldFromWorkpiece,workpieceID:result.workpieceID,
                        distanceSegments:[],phaseAtSegment:Self.phaseStarts(result.artifact.result.cuttingTimeline),insertSetup:op.study.configuredTurningSetup))
                } else {
                    chapters.append(.init(id:entry.stepID,name:Self.actionName(step.action),kind:"machine",start:entry.startSeconds,end:entry.endSeconds,pathIDs:[],jobID:entry.stepID))
                }
            }
        }
        guard extent.isFinite,extent >= 0 else { throw ManufacturingError.invalid("CAM preview extent") }
        var pointCount = 0
        for job in jobs {
            try control.check()
            let timeline = metric == .seconds ? job.artifact.result.cuttingTimeline : nil
            let timedSpans = Dictionary(grouping:timeline?.segments ?? [],by: \.pathIndex)
            let distanceSpans = Dictionary(grouping:job.distanceSegments,by: \.pathIndex)
            var orderedKeys = [String](),grouped = [String:[Int]]()
            for (i,path) in job.displayPaths.enumerated() {
                pointCount += path.points.count
                guard pointCount <= 1_000_000 else { throw ManufacturingError.invalid("CAM preview retained path point budget") }
                let group = job.id+":"+(path.operationID ?? path.kind)
                if grouped[group] == nil { orderedKeys.append(group);grouped[group] = [] }
                grouped[group]!.append(i)
                let spans = timedSpans[i] ?? []
                let distances = distanceSpans[i] ?? []
                let start = metric == .distance ? distances.first?.start : spans.first.map { job.start+$0.startSeconds }
                let end = metric == .distance ? distances.last.map { $0.start+$0.length } : spans.last.map { job.start+$0.startSeconds+$0.durationSeconds }
                paths.append(.init(id:job.id+":path:\(i)",chapterID:group,jobID:job.id,pathIndex:i,kind:path.kind,moveType:path.moveType,
                    pointsMM:path.points,frame:job.worldFromWorkpiece,start:start,end:end))
            }
            for group in orderedKeys {
                let indices = grouped[group]!,members = paths.filter { $0.chapterID == group },first = job.displayPaths[indices[0]]
                let operation = job.study.cam?.operations.first { $0.id == first.operationID }
                let tool = job.study.cam?.tools.first { $0.id == first.toolID }
                chapters.append(.init(id:group,name:operation?.name ?? first.kind,kind:first.kind,toolName:tool?.name,
                    start:members.compactMap(\.start).min(),end:members.compactMap(\.end).max(),pathIDs:members.map(\.id),jobID:job.id))
            }
            if let timeline {
                boundaries += timeline.segments.flatMap { [job.start+$0.startSeconds,job.start+$0.startSeconds+$0.durationSeconds] }
                if !timeline.excludedPathIndices.isEmpty { warnings.append("\(job.study.name): \(timeline.excludedPathIndices.count) paths have no timed motion and remain visible as untimed geometry.") }
            } else if metric == .distance { boundaries += job.distanceSegments.flatMap { [$0.start,$0.start+$0.length] } }
        }
        self.name = name;sourceKey = key;self.metric = metric;self.extent = extent
        self.jobs = jobs;self.replay = replay;self.paths = paths
        self.chapters = chapters.sorted { ($0.start ?? .infinity,$0.jobID,$0.id) < ($1.start ?? .infinity,$1.jobID,$1.id) }
        self.boundaries = Array(Set(boundaries+[extent])).filter { $0 >= 0 && $0 <= extent }.sorted()
        resolutionMM = jobs.map { $0.study.stock.resolutionMM }.min() ?? 1
        self.warnings = warnings+["Material changes at retained operation stages; the viewer does not recompute continuous removal.",
            "Paths show supplied TCP geometry. Missing traverses, tool-change movements and general machine IK are not synthesized.",
            "Additional tool-head silhouettes in the viewer are schematic and do not enter collision queries."]
    }
    public func nextBoundary(from position:Double,forward:Bool,within range:ClosedRange<Double>? = nil)->Double {
        let r = range ?? 0...extent
        if forward { return boundaries.first { $0 > position+1e-8 && r.contains($0) } ?? r.upperBound }
        return boundaries.last { $0 < position-1e-8 && r.contains($0) } ?? r.lowerBound
    }
    public func frame(at position:Double) throws -> CAMPreviewFrame {
        guard position.isFinite else { throw ManufacturingError.invalid("CAM preview position") }
        let t = max(0,min(extent,position))
        var paths = paths,tools = [CAMPreviewTool](),coverage = warnings,scene:VirtualScene
        let cellSnapshot = try replay?.snapshot(at:t)
        if case .cell(let project,let artifact) = source,let cellSnapshot {
            scene = try VirtualMachineSceneBuilder.build(configuration:project.scene,project:project.cell,artifact:artifact,snapshot:cellSnapshot)
            for i in paths.indices {
                guard let job = jobs.first(where:{ $0.id == paths[i].jobID }),!paths[i].kind.hasPrefix("turning-"),
                      let part = cellSnapshot.workpieces.first(where:{ $0.id == job.workpieceID }) else { continue }
                // Once a job is complete, retain its actual machining placement;
                // future/current jobs follow their workpiece, not an unrelated spindle.
                paths[i].frame = t >= job.end ? job.worldFromWorkpiece : part.worldFromWorkpiece
            }
            coverage += cellSnapshot.warnings
        } else { scene = .init(seconds:t,bodies:[],allowedContactPairs:[],warnings:[]) }
        for job in jobs {
            let active = replay == nil || (job.start <= t && (t < job.end || t == extent && job.end == extent))
            guard active else { continue }
            let result = job.artifact.result,local = max(0,t-job.start)
            let sample:CuttingTimeline.Sample?,pointIndex:Int
            if metric == .seconds,let timeline = result.cuttingTimeline {
                sample = try timeline.sample(atSeconds:min(timeline.totalSeconds,local))
                pointIndex = sample.map { timeline.segments[$0.segmentIndex].startPointIndex } ?? 0
            } else if metric == .distance,let span = job.distanceSegments.last(where:{ $0.start <= t }) ?? job.distanceSegments.first {
                let path = job.displayPaths[span.pathIndex],f = span.length > 0 ? max(0,min(1,(t-span.start)/span.length)) : 0
                let a = path.points[span.pointIndex],b = path.points[span.pointIndex+1]
                sample = .init(pointMM:zip(a,b).map { $0+($1-$0)*f },pathIndex:span.pathIndex,segmentIndex:0,rpm:nil,feedMMPerMinute:path.feedMMPerMinute ?? 0)
                pointIndex = span.pointIndex
            } else { sample = nil;pointIndex = 0 }
            guard let sample,job.displayPaths.indices.contains(sample.pathIndex) else { continue }
            let path = job.displayPaths[sample.pathIndex],turning = path.kind.hasPrefix("turning-")
            let pathID = job.id+":path:\(sample.pathIndex)",chapterID = job.id+":"+(path.operationID ?? path.kind)
            var axis = turning ? [1.0,0,0] : [0.0,0,1]
            let ac = path.kind == "ac" && result.acPoses?.count == path.points.count ? result.acPoses : nil
            let suppliedAxes = path.toolAxes ?? ac?.map(\.axis)
            var interpolationFraction = 0.0
            if let axes = suppliedAxes,axes.indices.contains(pointIndex) {
                axis = axes[pointIndex]
                if axes.indices.contains(pointIndex+1),path.points.indices.contains(pointIndex+1) {
                    let a = path.points[pointIndex],b = path.points[pointIndex+1],delta = zip(a,b).map { $1-$0 }
                    let dd = delta.reduce(0.0) { $0+$1*$1 }
                    let f = dd > 1e-16 ? zip(zip(a,sample.pointMM).map { $1-$0 },delta).reduce(0.0) { $0+$1.0*$1.1 }/dd : 0
                    interpolationFraction = max(0,min(1,f))
                    axis = try ToolAxisInterpolation.interpolate(axes[pointIndex],axes[pointIndex+1],fraction:max(0,min(1,f)))
                }
            } else if path.kind == "milling-slot" { let a = job.study.milling.angleDegrees * .pi/180;axis = [cos(a),sin(a),0] }
            let placement = paths.first(where:{ $0.id == pathID })?.frame ?? job.worldFromWorkpiece
            let worldAxis = (0..<3).map { row in (0..<3).reduce(0.0) { $0+placement.rotation[row*3+$1]*axis[$1] } }
            let operation = job.study.cam?.operations.first(where:{ $0.id == path.operationID })
            let rpm = turning ? sample.rpm : operation?.cutting?.toolSpindleRPM
            let phase:Double?
            if metric == .seconds,turning,let timeline = result.cuttingTimeline,job.phaseAtSegment.indices.contains(sample.segmentIndex) {
                let segment = timeline.segments[sample.segmentIndex],elapsed = min(segment.durationSeconds,max(0,local-segment.startSeconds))
                let fraction = Self.segmentFraction(segment,point:sample.pointMM)
                phase = job.phaseAtSegment[sample.segmentIndex]+Self.phase(segment,elapsed:elapsed,fraction:fraction)
            } else { phase = metric == .seconds ? rpm.map { 6*$0*local } : nil }
            let name = job.study.cam?.tools.first(where:{ $0.id == path.toolID })?.name ?? (turning ? "turning-tool" : "cutting-tool")
            tools.append(.init(id:job.id,chapterID:chapterID,name:name,tipMM:placement.applied(to:sample.pointMM),axis:worldAxis,
                pathID:pathID,pointIndex:pointIndex,feedMMPerMinute:sample.feedMMPerMinute > 0 ? sample.feedMMPerMinute : nil,
                rpm:rpm,phaseDegrees:phase,turning:turning))
            if turning {
                tools[tools.count-1].insertSetup = job.insertSetup
                tools[tools.count-1].turningApproach = job.study.turningApproach
                tools[tools.count-1].insertOutline = result.turningSetupReceipt?.toolProfile.map { [$0[0],$0[1]*(job.study.turningApproach == .negativeZ ? -1 : 1)] }
            } else {
                var definition = job.study.cam?.tools.first { $0.id == path.toolID }
                if definition == nil,["milling-slot","ac"].contains(path.kind) {
                    var legacy = ManufacturingCAM.Tool(id:job.study.millingToolID ?? "slot-tool",name:"cutting-tool",diameterMM:job.study.milling.toolRadiusMM*2,cuttingLengthMM:job.study.milling.toolLengthMM)
                    legacy.assembly = job.study.millingAssembly;definition = legacy
                }
                tools[tools.count-1].definition = definition
                tools[tools.count-1].gaugeLengthMM = job.study.acMotion?.toolLengthMM ?? definition?.gaugeLengthMM
            }
            tools[tools.count-1].displayFrame = placement.composed(with:try VirtualMachineSceneBuilder.alignedFrame(tip:sample.pointMM,axis:axis))
            if let joints = path.joints ?? ac?.map(\.joints),joints.indices.contains(pointIndex) {
                var value = joints[pointIndex]
                if joints.indices.contains(pointIndex+1),joints[pointIndex+1].count == value.count {
                    value = zip(value,joints[pointIndex+1]).map { $0+($1-$0)*interpolationFraction }
                }
                tools[tools.count-1].joints = value
            }
            if replay == nil { scene = try Self.studyScene(job:job,position:t,path:path,sample:sample,tool:tools.last!) }
            if sample.pathIndex > 0,pointIndex == 0 {
                let before = job.displayPaths[sample.pathIndex-1].points.last
                if let before,let first = path.points.first,Self.distance(before,first)>1e-7 { coverage.append("The preceding path has no supplied connecting traverse. The cursor changes to the next known path; that transition is not a simulated safe move.") }
            }
        }
        scene.warnings += coverage
        let active = tools.map(\.chapterID)+chapters.filter { $0.kind == "machine" && ($0.start ?? .infinity)<=t && t<($0.end ?? -.infinity) }.map(\.id)
        var frame = CAMPreviewFrame(position:t,scene:scene,paths:paths,tools:tools,activeChapterIDs:active,coverage:Array(Set(coverage)).sorted(),
            latheStock:replay == nil && jobs.first.map { $0.study.turning.enabled && !$0.study.stock.isBox } == true,
            latheStockRadiusMM:replay == nil ? jobs.first?.study.stock.radiusMM : nil,
            latheDatumZMM:replay == nil ? jobs.first?.study.stock.zMinMM : nil)
        if replay == nil,let study = jobs.first?.study { frame.machine = try CAMMachinePresentation.study(study,tools:tools) }
        return frame
    }
    private static func distances(_ paths:[ManufacturingResult.Path])->[DistanceSegment] {
        var result = [DistanceSegment](),cursor = 0.0
        for (i,path) in paths.enumerated() where path.points.count > 1 {
            for j in 0..<path.points.count-1 { let d = distance(path.points[j],path.points[j+1]);result.append(.init(pathIndex:i,pointIndex:j,start:cursor,length:d));cursor += d }
        }
        return result
    }
    private static func displayPaths(_ result:ManufacturingResult)->[ManufacturingResult.Path] {
        guard let poses = result.acPoses,!poses.isEmpty,!result.paths.contains(where:{ $0.kind == "ac" }) else { return result.paths }
        // Native AC receipts already contain the exact sampled TCP, unit axis
        // and physical rotary coordinates. This is a view of that evidence,
        // not a newly planned path or a new time law.
        return result.paths+[.init(kind:"ac",points:poses.map(\.tipMM),toolAxes:poses.map(\.axis),joints:poses.map(\.joints))]
    }
    private static func distance(_ a:[Double],_ b:[Double])->Double { sqrt(zip(a,b).reduce(0.0) { $0+($1.0-$1.1)*($1.0-$1.1) }) }
    private static func segmentFraction(_ s:CuttingTimeline.Segment,point:[Double])->Double { s.lengthMM>0 ? max(0,min(1,distance(s.startPointMM,point)/s.lengthMM)) : 0 }
    private static func phaseStarts(_ timeline:CuttingTimeline?)->[Double] {
        var value = 0.0,result = [Double]()
        for s in timeline?.segments ?? [] { result.append(value);value += phase(s,elapsed:s.durationSeconds,fraction:1) }
        return result
    }
    /// Turning phase from the recorded speed/feed law. Per-revolution feed gives
    /// exact revolutions by distance. CSS/per-minute integrates the capped 1/r law.
    private static func phase(_ s:CuttingTimeline.Segment,elapsed:Double,fraction:Double)->Double {
        guard let rpm = s.startRPM else { return 0 }
        if s.feedMode == .mmPerRevolution,let feed = s.feedMMPerRevolution,feed>0,s.lengthMM>0 { return 360*s.lengthMM*fraction/feed }
        guard s.spindleMode == .constantSurfaceSpeed,let speed = s.surfaceSpeedMPerMinute,let cap = s.maxSpindleRPM,
              let r0 = s.radiusStartMM,let r1 = s.radiusEndMM,s.durationSeconds>0 else { return 6*rpm*elapsed }
        let dr = r1-r0,k = speed*1000/(2*Double.pi),f = elapsed/s.durationSeconds
        if abs(dr)<1e-12 { return 6*min(cap,k/max(r0,1e-12))*elapsed }
        let crossing = (k/cap-r0)/dr
        let cuts = ([0.0,f]+(crossing>0 && crossing<f ? [crossing] : [])).sorted()
        var integral = 0.0
        for i in 1..<cuts.count {
            let a = cuts[i-1],b = cuts[i],mid = r0+dr*(a+b)/2
            if mid<=k/cap { integral += cap*(b-a) }
            else { integral += k/dr*log((r0+dr*b)/(r0+dr*a)) }
        }
        return 6*s.durationSeconds*integral
    }
    private static func actionName(_ action:CellAction)->String {
        switch action { case .spindle:return "spindle";case .chuck:return "chuck";case .synchronize:return "synchronize";case .transfer:return "transfer";case .operate(let op):return op.study.name;case .wait:return "wait";case .barrier:return "barrier";default:return "machine-event" }
    }
    private static func studyScene(job:Job,position:Double,path:ManufacturingResult.Path,sample:CuttingTimeline.Sample,tool:CAMPreviewTool) throws -> VirtualScene {
        let study = job.study,result = job.artifact.result,frames = result.frames ?? []
        let stageName = path.operationID.map { "cam-"+$0 } ?? (path.kind == "milling-slot" ? "milling" : path.kind)
        let current = result.stages.firstIndex(where:{ $0.name == stageName })
        let finished = current.map { Set(["initial","continued"]+result.stages.prefix($0).map(\.name)) } ?? Set(["initial","continued"])
        let frame = position>=job.end ? nil : frames.last(where:{ finished.contains($0.name) }) ?? frames.first
        let vertices = frame?.vertices ?? result.vertices,triangles = frame?.triangles ?? result.triangles
        let phase = tool.turning ? (tool.phaseDegrees ?? 0)*Double.pi/180 : 0,c = cos(phase),s = sin(phase)
        let stockFrame = CellRigidTransform(rotation:[c,-s,0,s,c,0,0,0,1],translationMM:[0,0,0])
        var bodies = [VirtualSceneBody](),warnings = [String]()
        if !triangles.isEmpty { bodies.append(.init(id:"stock",role:"stock",groupID:"stock",geometryKey:"study:\(frame?.name ?? "final")",frame:stockFrame,
            shape:.init(type:.mesh,vertices:vertices,triangles:triangles),geometryClass:.triangleSurface)) }
        for fixture in study.fixtures {
            let half = zip(fixture.minMM,fixture.maxMM).map { ($1-$0)/2 },center = zip(fixture.minMM,fixture.maxMM).map { ($0+$1)/2 }
            bodies.append(.init(id:"fixture:"+fixture.id,role:"fixture",groupID:"fixture:"+fixture.id,geometryKey:"fixture:"+fixture.id,
                frame:.init(rotation:CellRigidTransform.identity.rotation,translationMM:center),shape:.init(type:.box,halfExtentsMM:half),geometryClass:.solid))
        }
        let tf = try VirtualMachineSceneBuilder.alignedFrame(tip:tool.tipMM,axis:tool.axis)
        func round(_ id:String,_ role:String,_ radius:Double,_ length:Double,_ origin:Double,_ kind:VirtualSceneBody.GeometryClass = .solid) {
            bodies.append(.init(id:id,role:role,groupID:"tool:study",geometryKey:"\(id):\(radius):\(length)",
                frame:tf.composed(with:.init(rotation:CellRigidTransform.identity.rotation,translationMM:[0,0,origin])),
                shape:.init(type:.cylinder,radiusMM:radius,lengthMM:length),geometryClass:kind))
        }
        if tool.turning {
            let r = max(0.05,study.turning.toolNoseRadiusMM)
            round("tool:study:nose","cutter",r,2*r,0,.outerEnvelope)
        } else {
            let definition = study.cam?.tools.first(where:{ $0.id == path.toolID })
            let radius = definition.map { $0.diameterMM/2 } ?? study.milling.toolRadiusMM,length = definition?.cuttingLengthMM ?? study.milling.toolLengthMM
            round("tool:study:cutter","cutter",radius,length,length/2,definition?.kind == "flatEndMill" ? .solid : .outerEnvelope)
            if let assembly = definition?.assembly ?? study.millingAssembly {
                let lo = assembly.holderProfile.first?.axialMM ?? length,hi = assembly.holderProfile.last?.axialMM ?? length
                if lo>length { round("tool:study:shank","shank",assembly.shankDiameterMM/2,lo-length,(lo+length)/2) }
                if hi>lo,let radius = assembly.holderProfile.map(\.radiusMM).max() { round("tool:study:holder","holder",radius,hi-lo,(hi+lo)/2,.outerEnvelope) }
            } else { warnings.append("The active cutter has no configured shank/holder model.") }
        }
        warnings.append("Standalone stock rotation uses the recorded turning speed law with a visual zero reference; no chuck grip, spindle direction or manufacturer geometry is inferred. This viewing scene is not a machine collision certificate.")
        return .init(seconds:position,bodies:bodies,allowedContactPairs:[],warnings:warnings)
    }
}
