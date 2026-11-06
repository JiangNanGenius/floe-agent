// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Geometry of the research machine, in mm. These are explicit virtual solids,
/// not dimensions inferred from a manufacturer's actual headstock or chuck.
public struct VirtualSpindleHousing:Codable,Equatable,Sendable,Identifiable {
    public var id:String
    public var housingRadiusMM = 30.0
    public var housingLengthMM = 40.0
    public var chuckRadiusMM = 20.0
    public var chuckLengthMM = 14.0
    public var jawCount = 3
    public var jawRadialWidthMM = 6.0
    public var jawTangentialWidthMM = 5.0
    public var jawLengthMM = 6.0
    public init(id:String) { self.id = id }
    public func validate() throws {
        let values = [housingRadiusMM,housingLengthMM,chuckRadiusMM,chuckLengthMM,jawRadialWidthMM,jawTangentialWidthMM,jawLengthMM]
        guard !id.isEmpty,(2...12).contains(jawCount),values.allSatisfy({ $0.isFinite && (0.1...5000).contains($0) }) else {
            throw ManufacturingError.invalid("virtual spindle housing geometry")
        }
    }
}

public struct VirtualMachineSceneConfiguration:Codable,Equatable,Sendable {
    public var spindles:[VirtualSpindleHousing]
    /// Explicit fixed world bodies. Attachments are prohibited here.
    public var fixtures:[MachineBody] = []
    /// Known final catcher placements. Without one an explicitly ejected part
    /// leaves the processing scene; its unprovided eject travel stays uncovered.
    public var ejectedPartPlacements:[String:CellRigidTransform] = [:]
    public var maxStockTriangles = 80_000
    public var clearanceMM = 0.0
    public init(spindles:[VirtualSpindleHousing]) { self.spindles = spindles }
    public static func demonstration(for cell:ManufacturingCell)->Self { .init(spindles:cell.spindles.map { .init(id:$0.id) }) }
    public func validate(for cell:ManufacturingCell) throws {
        guard spindles.count == cell.spindles.count,Set(spindles.map(\.id)) == Set(cell.spindles.map(\.id)),
              Set(spindles.map(\.id)).count == spindles.count,fixtures.count <= 24,
              (100...100_000).contains(maxStockTriangles),clearanceMM.isFinite && (0...100).contains(clearanceMM),
              fixtures.allSatisfy({ $0.attach == nil && !$0.id.isEmpty }),Set(fixtures.map(\.id)).count == fixtures.count else {
            throw ManufacturingError.invalid("virtual scene identities, fixed fixtures or geometry budget")
        }
        for spindle in spindles { try spindle.validate() }
        for fixture in fixtures { try fixture.frame?.validate();try Self.validate(fixture.shape) }
        for (id,frame) in ejectedPartPlacements {
            guard cell.workpieces.contains(where:{ $0.id == id }) else { throw ManufacturingError.invalid("virtual catcher workpiece identity") }
            try frame.validate()
        }
    }
    static func validate(_ shape:MachineBody.Shape) throws {
        func positive(_ value:Double?)->Bool { value.map { $0.isFinite && (0.000001...100_000).contains($0) } ?? false }
        switch shape.type {
        case .box:
            guard let extents = shape.halfExtentsMM,extents.count == 3,extents.allSatisfy({ positive($0) }) else { throw ManufacturingError.invalid("virtual box dimensions") }
        case .cylinder,.capsule:
            guard positive(shape.radiusMM),positive(shape.lengthMM) else { throw ManufacturingError.invalid("virtual round-body dimensions") }
        case .mesh:
            guard let vertices = shape.vertices,let triangles = shape.triangles,(3...100_000).contains(vertices.count),
                  (1...100_000).contains(triangles.count),vertices.allSatisfy({ $0.count == 3 && $0.allSatisfy { $0.isFinite && abs($0) <= 100_000 } }),
                  triangles.allSatisfy({ $0.count == 3 && Set($0).count == 3 && $0.allSatisfy { vertices.indices.contains($0) } }) else {
                throw ManufacturingError.invalid("virtual surface mesh dimensions/indices")
            }
        }
    }
}

public struct VirtualSceneBody:Codable,Equatable,Sendable,Identifiable {
    public enum GeometryClass:String,Codable,Sendable { case solid,triangleSurface,outerEnvelope }
    public var id:String
    public var role:String
    public var groupID:String
    public var geometryKey:String
    public var frame:CellRigidTransform
    public var shape:MachineBody.Shape
    public var geometryClass:GeometryClass
}

public struct VirtualScene:Codable,Sendable {
    public var seconds:Double
    public var bodies:[VirtualSceneBody]
    public var allowedContactPairs:[[String]]
    public var warnings:[String]
    /// A static pose query, not a swept trajectory. The zero-travel basis axis
    /// only satisfies the existing ABI; every queried body has its world frame.
    public func queryRequest(clearanceMM:Double) throws -> MachineQueryRequest {
        guard bodies.count >= 2,bodies.count <= 128 else { throw ManufacturingError.invalid("virtual snapshot body budget") }
        let converted = bodies.map { body in
            let r = body.frame.rotation
            return MachineBody(id:body.id,resourceID:body.groupID,
                frame:.init(originMM:body.frame.translationMM,xDirection:[r[0],r[3],r[6]],zDirection:[r[2],r[5],r[8]]),shape:body.shape)
        }
        var request = MachineQueryRequest(chain:.init(axes:[.init(id:"snapshot-basis",kind:.linear,axis:[0,0,1],limits:[-1,1])]),
            bodies:converted,motion:.linear("snapshot-basis",from:0,to:0),allowedContactPairs:allowedContactPairs)
        request.budget.clearanceMM = clearanceMM;request.budget.maxSamples = 1;request.budget.maxCollisionQueries = 32_768
        try request.validate();return request
    }
}

public enum VirtualMachineSceneBuilder {
    public static func build(configuration:VirtualMachineSceneConfiguration,project:ManufacturingCellProject,
                             artifact:CellSimulationArtifact,snapshot:VirtualCellSnapshot) throws -> VirtualScene {
        try configuration.validate(for:project.cell)
        var bodies = [VirtualSceneBody](),warnings = snapshot.warnings
        func shifted(_ transform:CellRigidTransform,_ point:[Double])->CellRigidTransform {
            transform.composed(with:.init(rotation:CellRigidTransform.identity.rotation,translationMM:point))
        }
        func append(_ id:String,_ role:String,_ group:String,_ key:String,_ frame:CellRigidTransform,
                    _ shape:MachineBody.Shape,_ kind:VirtualSceneBody.GeometryClass = .solid) {
            bodies.append(.init(id:id,role:role,groupID:group,geometryKey:key,frame:frame,shape:shape,geometryClass:kind))
        }
        for pose in snapshot.spindles {
            guard let configuration = configuration.spindles.first(where:{ $0.id == pose.id }),
                  let spindle = project.cell.spindles.first(where:{ $0.id == pose.id }) else { throw ManufacturingError.invalid("virtual spindle pose identity") }
            let group = "spindle:"+pose.id
            var fixed = spindle.frame.transform;fixed.translationMM = pose.carriageOriginMM
            append(group+":housing","housing",group,"housing:\(configuration.housingRadiusMM):\(configuration.housingLengthMM)",
                shifted(fixed,[0,0,-configuration.chuckLengthMM-configuration.housingLengthMM/2]),
                .init(type:.cylinder,radiusMM:configuration.housingRadiusMM,lengthMM:configuration.housingLengthMM))
            append(group+":chuck","chuck",group,"chuck:\(configuration.chuckRadiusMM):\(configuration.chuckLengthMM)",
                shifted(pose.frame,[0,0,-configuration.chuckLengthMM/2]),
                .init(type:.cylinder,radiusMM:configuration.chuckRadiusMM,lengthMM:configuration.chuckLengthMM))
            // Jaw closure uses the declared held-part envelope. It is geometric
            // placement only; no force, jaw deformation or friction is inferred.
            let heldRadius = pose.clampedWorkpieceID.flatMap { id in project.cell.workpieces.first(where:{ $0.id == id })?.envelopeRadiusMM }
            let openingRadius = heldRadius ?? pose.chuckOpeningDiameterMM/2
            for i in 0..<configuration.jawCount {
                let angle = Double(i)*2*Double.pi/Double(configuration.jawCount),c = cos(angle),s = sin(angle)
                let radius = openingRadius+configuration.jawRadialWidthMM/2
                let local = CellRigidTransform(rotation:[c,-s,0,s,c,0,0,0,1],translationMM:[radius*c,radius*s,configuration.jawLengthMM/2])
                append(group+":jaw:\(i)","jaw",group,"jaw:\(configuration.jawRadialWidthMM):\(configuration.jawTangentialWidthMM):\(configuration.jawLengthMM)",
                    pose.frame.composed(with:local),.init(type:.box,halfExtentsMM:[configuration.jawRadialWidthMM/2,configuration.jawTangentialWidthMM/2,configuration.jawLengthMM/2]))
            }
        }
        for pose in snapshot.workpieces {
            var materialPlacement = pose.worldFromWorkpiece
            if pose.ownerSpindleID == nil && artifact.schedule.ejectedWorkpieceIDs.contains(pose.id) {
                guard let catcher = configuration.ejectedPartPlacements[pose.id] else {
                    warnings.append("Ejected workpiece \(pose.id) has no configured catcher placement; it is omitted after release and its eject travel remains uncovered.")
                    continue
                }
                materialPlacement = catcher
                warnings.append("Ejected workpiece \(pose.id) uses the configured final catcher placement; no intermediate eject trajectory is provided.")
            }
            guard let first = artifact.jobs.first(where:{ $0.workpieceID == pose.id }) else {
                warnings.append("Workpiece \(pose.id) has no computed material geometry.");continue
            }
            let selected = pose.activeJobID.flatMap { id in artifact.jobs.first(where:{ $0.stepID == id }) }
                ?? pose.lastCompletedJobID.flatMap { id in artifact.jobs.first(where:{ $0.stepID == id }) } ?? first
            guard let step = artifact.executedCell.steps.first(where:{ $0.id == selected.stepID }),case .operate(let operation) = step.action else {
                throw ManufacturingError.invalid("virtual material job/study identity")
            }
            let result = selected.artifact.result,frames = selected.artifact.result.frames ?? []
            var vertices = result.vertices,triangles = result.triangles,key = selected.stepID+":final"
            if pose.activeJobID != nil {
                let start = artifact.schedule.steps.first(where:{ $0.stepID == selected.stepID })?.startSeconds ?? 0
                if let timeline = result.cuttingTimeline,let sample = try? timeline.sample(atSeconds:max(0,min(timeline.totalSeconds,snapshot.seconds-start))),
                   result.paths.indices.contains(sample.pathIndex) {
                    let path = result.paths[sample.pathIndex],name = path.operationID.map { "cam-"+$0 } ?? path.kind
                    if let current = result.stages.firstIndex(where:{ $0.name == name }) {
                        let finished = Set(["initial","continued"]+result.stages.prefix(current).map(\.name))
                        if let index = frames.lastIndex(where:{ finished.contains($0.name) }) {
                            vertices = frames[index].vertices;triangles = frames[index].triangles;key = selected.stepID+":frame:\(index)"
                        } else if let frame = frames.first { vertices = frame.vertices;triangles = frame.triangles;key = selected.stepID+":initial" }
                        else { vertices = [];triangles = [] }
                    } else if let frame = frames.first { vertices = frame.vertices;triangles = frame.triangles;key = selected.stepID+":initial" }
                    else { vertices = [];triangles = [] }
                } else if let frame = frames.first { vertices = frame.vertices;triangles = frame.triangles;key = selected.stepID+":initial" }
                else { vertices = [];triangles = [] }
            } else if pose.lastCompletedJobID == nil {
                if let frame = frames.first { vertices = frame.vertices;triangles = frame.triangles;key = first.stepID+":initial" }
                else { vertices = [];triangles = [] }
            }
            let group = "workpiece:"+pose.id
            if !triangles.isEmpty && triangles.count <= configuration.maxStockTriangles {
                append(group,"stock",group,key,materialPlacement,.init(type:.mesh,vertices:vertices,triangles:triangles),.triangleSurface)
            } else if result.stockState?.occupiedIndices.isEmpty == true && pose.lastCompletedJobID != nil && pose.activeJobID == nil {
                // Successfully empty material remains empty, never a fresh blank.
            } else {
                let stock = operation.study.stock,bounds = stock.bounds
                let center = zip(bounds.min,bounds.max).map { ($0+$1)/2 }
                let shape:MachineBody.Shape = stock.isBox
                    ? .init(type:.box,halfExtentsMM:zip(bounds.min,bounds.max).map { ($1-$0)/2 })
                    : .init(type:.cylinder,radiusMM:stock.radiusMM,lengthMM:stock.zMaxMM-stock.zMinMM)
                append(group,"stock",group,"stock-envelope:"+selected.stepID,shifted(materialPlacement,center),shape,.outerEnvelope)
                warnings.append("Workpiece \(pose.id) uses an initial-stock outer envelope because an exact retained stage mesh is unavailable or exceeds the scene budget.")
            }
        }
        for tool in snapshot.tools {
            guard let job = artifact.jobs.first(where:{ $0.stepID == tool.stepID }),
                  let step = artifact.executedCell.steps.first(where:{ $0.id == tool.stepID }),case .operate(let operation) = step.action else {
                throw ManufacturingError.invalid("virtual tool job identity")
            }
            let group = "tool:"+tool.stepID
            let frame = try alignedFrame(tip:tool.worldTipMM,axis:tool.worldAxis)
            if let definition = operation.study.cam?.tools.first(where:{ $0.id == tool.toolID }) {
                let radius = definition.diameterMM/2,length = definition.cuttingLengthMM
                append(group+":cutter","cutter",group,"cutter:\(definition.kind):\(radius):\(length)",shifted(frame,[0,0,length/2]),
                    .init(type:.cylinder,radiusMM:radius,lengthMM:length),definition.kind == "flatEndMill" ? .solid : .outerEnvelope)
                if let assembly = definition.assembly {
                    let shankRadius = assembly.shankDiameterMM/2,shankLength = max(0,(assembly.holderProfile.first?.axialMM ?? length)-length)
                    if shankLength > 0 {
                        append(group+":shank","shank",group,"shank:\(shankRadius):\(shankLength)",
                            shifted(frame,[0,0,length+shankLength/2]),.init(type:.cylinder,radiusMM:shankRadius,lengthMM:shankLength))
                    }
                    if let lo = assembly.holderProfile.first?.axialMM,let hi = assembly.holderProfile.last?.axialMM,hi > lo,
                       let radius = assembly.holderProfile.map(\.radiusMM).max() {
                        append(group+":holder","holder",group,"holder:\(lo):\(hi):\(radius)",shifted(frame,[0,0,(lo+hi)/2]),
                            .init(type:.cylinder,radiusMM:radius,lengthMM:hi-lo),.outerEnvelope)
                    }
                } else { warnings.append("Tool \(definition.id) has no configured shank/holder; those bodies remain uncovered.") }
            } else if job.artifact.result.paths.indices.contains(tool.pathIndex),job.artifact.result.paths[tool.pathIndex].kind.hasPrefix("turning-") {
                let radius = operation.study.turning.toolNoseRadiusMM
                append(group+":nose","cutter",group,"turning-nose:\(radius)",frame,sphereSurface(radius:radius),.triangleSurface)
                warnings.append("Turning tool \(tool.toolID ?? tool.stepID) includes only its nose sphere; an entire turning holder/body is not configured.")
            } else { warnings.append("Tool geometry for \(tool.stepID) is uncovered.") }
        }
        for fixture in configuration.fixtures {
            let transform = fixture.frame.map { frame in
                CellFrame(originMM:frame.originMM,axis:frame.zDirection,xDirection:frame.xDirection).transform
            } ?? .identity
            append("fixture:"+fixture.id,"fixture","fixture:"+fixture.id,"fixture:"+fixture.id,transform,fixture.shape,
                fixture.shape.type == .mesh ? .triangleSurface : .solid)
        }
        guard bodies.count <= 128,Set(bodies.map(\.id)).count == bodies.count else { throw ManufacturingError.invalid("virtual scene body/identity budget") }
        for body in bodies { try body.frame.validate() }
        var allowed = [[String]]()
        for i in bodies.indices { for j in bodies.indices where j > i {
            let a = bodies[i],b = bodies[j]
            var intentional = a.groupID == b.groupID
            for pose in snapshot.spindles {
                guard let held = pose.clampedWorkpieceID else { continue }
                let stock = "workpiece:"+held,spindle = "spindle:"+pose.id
                intentional = intentional || (a.id == stock && b.groupID == spindle && ["chuck","jaw"].contains(b.role))
                    || (b.id == stock && a.groupID == spindle && ["chuck","jaw"].contains(a.role))
            }
            for tool in snapshot.tools {
                guard let job = artifact.jobs.first(where:{ $0.stepID == tool.stepID }),job.artifact.result.paths.indices.contains(tool.pathIndex) else { continue }
                let path = job.artifact.result.paths[tool.pathIndex]
                guard path.moveType == "cut" || (path.moveType == nil && path.kind.hasPrefix("turning-")) else { continue }
                let cutter = "tool:"+tool.stepID+":cutter",nose = "tool:"+tool.stepID+":nose",stock = "workpiece:"+job.workpieceID
                intentional = intentional || (a.id == stock && [cutter,nose].contains(b.id)) || (b.id == stock && [cutter,nose].contains(a.id))
            }
            if intentional { allowed.append([a.id,b.id]) }
        } }
        warnings += ["Virtual solids are configured research geometry, not a manufacturer's certified machine model.",
                     "Collision results cover this static pose only. No continuous swept motion or complete inactive turret/tool geometry is implied.",
                     "Material meshes change only at retained operation stages; rotation is continuous commanded pose replay, not continuously recomputed removal."]
        return .init(seconds:snapshot.seconds,bodies:bodies,allowedContactPairs:allowed,warnings:Array(Set(warnings)).sorted())
    }

    public static func alignedFrame(tip:[Double],axis:[Double]) throws -> CellRigidTransform {
        guard tip.count == 3,axis.count == 3,(tip+axis).allSatisfy(\.isFinite) else { throw ManufacturingError.invalid("virtual tool frame") }
        let length = CellFrame.norm(axis)
        guard abs(length-1) < 1e-6 else { throw ManufacturingError.invalid("virtual tool axis must be unit length") }
        let z = axis.map { $0/length },seed = abs(axis[0]) < 0.8 ? [1.0,0,0] : [0.0,1,0]
        let projection = zip(seed,z).reduce(0.0) { $0+$1.0*$1.1 }
        let projected = zip(seed,z).map { $0-projection*$1 },scale = CellFrame.norm(projected)
        let x = projected.map { $0/scale }
        return CellFrame(originMM:tip,axis:z,xDirection:x).transform
    }
    private static func sphereSurface(radius:Double)->MachineBody.Shape {
        let rows = 12,columns = 24
        var vertices = [[Double]](),triangles = [[Int]]()
        vertices.append([0,0,radius])
        for i in 1..<rows { let phi = Double(i)*Double.pi/Double(rows)
            for j in 0..<columns { let theta = Double(j)*2*Double.pi/Double(columns)
                vertices.append([radius*sin(phi)*cos(theta),radius*sin(phi)*sin(theta),radius*cos(phi)]) }
        }
        let bottom = vertices.count;vertices.append([0,0,-radius])
        for j in 0..<columns { triangles.append([0,1+j,1+(j+1)%columns]) }
        for i in 0..<(rows-2) { for j in 0..<columns {
            let a = 1+i*columns+j,b = 1+i*columns+(j+1)%columns,c = a+columns,d = b+columns
            triangles += [[a,c,b],[b,c,d]]
        } }
        for j in 0..<columns { triangles.append([bottom,1+(rows-2)*columns+(j+1)%columns,1+(rows-2)*columns+j]) }
        return .init(type:.mesh,vertices:vertices,triangles:triangles)
    }
}
