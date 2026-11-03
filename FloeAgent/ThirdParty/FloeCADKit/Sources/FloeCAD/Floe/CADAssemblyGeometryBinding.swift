import Foundation
import simd

/// Persist author-owned names, never the kernel index used for a fresh pick.
/// Numeric legacy references deliberately do not acquire invented provenance.
nonisolated struct CADAssemblyGeometryBinding: Codable, Sendable, Equatable {
    var version: Int = 1
    var bodyID: UUID
    var face: FaceRef?
    var planeID: UUID?
    var axisID: UUID?

    var supported: Bool {
        version == 1 && [face != nil, planeID != nil, axisID != nil].filter { $0 }.count == 1
    }
}

nonisolated enum CADAssemblyGeometryResolver {
    struct Reference: Sendable {
        var point: SIMD3<Double>
        var direction: SIMD3<Double>
        var revision: UInt64
    }

    static func resolve(_ binding: CADAssemblyGeometryBinding, source: Body,
                        document: DesignDocument, names: [Int: ElementName]) -> Reference? {
        guard binding.supported, binding.bodyID == source.id.raw else { return nil }
        if let id = binding.planeID {
            guard let plane = document.planes.first(where: { $0.id.raw == id }) else { return nil }
            return Reference(point: plane.plane.origin, direction: plane.plane.normal,
                             revision: source.meshRevision)
        }
        if let id = binding.axisID {
            guard let axis = document.axes.first(where: { $0.id.raw == id }) else { return nil }
            return Reference(point: axis.origin, direction: axis.direction, revision: source.meshRevision)
        }
        guard let reference = binding.face, reference.body.bodyID == source.id,
              document.features.nodes.contains(where: {
                  $0.id == reference.body.producer && $0.outputBodyIDs.contains(source.id)
              }), let name = reference.elementName, name.isStableFaceIdentity,
              let brep = source.brep else { return nil }
        let hits = names.filter { $0.value == name }
        guard hits.count == 1, let index = hits.first?.key,
              let face = OCCTKernel.faceInfo(brep).first(where: { $0.index == index }),
              let signature = face.signature,
              SignatureNaming.acceptsNamedSignature(name, current: signature, reference: reference.signature)
        else { return nil }
        let point: SIMD3<Double>
        switch signature.kind {
        case .nativeSurface: return nil
        case .planar: point = face.centroid
        case .cylindrical:
            guard let axis = face.axisPoint else { return nil }
            point = axis
        }
        return Reference(point: source.transform.applying(to: point),
                         direction: simd_normalize(source.transform.rotation.act(face.normal)),
                         revision: source.meshRevision)
    }

    /// Refresh all scopes against the same newly rebuilt geometry, then run
    /// their actual constraints. A broken named face stays broken; its old
    /// placement is retained and its row requests a new selection.
    static func refresh(_ original: CADAssembly, document: DesignDocument,
                        kernelNames: [BodyID: [Int: ElementName]]) -> CADAssembly {
        guard original.constraintsWithScope().contains(where: { $0.constraint.bindingA != nil || $0.constraint.bindingB != nil }) else { return original }
        var result = original
        var changed = false
        let sources = Dictionary(document.bodies.map { ($0.id.raw, $0) }, uniquingKeysWith: { first, _ in first })
        func constraints(_ input: [CADAssemblyConstraint], instances: [CADAssemblyInstance]) -> [CADAssemblyConstraint] {
            let byID = Dictionary(instances.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return input.map { old in
                var c = old
                c.referenceFailure = nil
                for sideA in [true, false] {
                    guard let binding = sideA ? c.bindingA : c.bindingB else { continue }
                    let id = sideA ? c.instanceA : c.instanceB
                    guard let id, let instance = byID[id],
                          let source = sources[instance.copiedBodyID ?? instance.bodyID],
                          let reference = resolve(binding, source: source, document: document,
                                                  names: kernelNames[source.id] ?? [:]) else {
                        c.referenceFailure = "Select the missing or ambiguous joint reference again."
                        continue
                    }
                    if sideA {
                        c.pointA = reference.point; c.directionA = reference.direction
                        c.sourceRevisionA = reference.revision
                    } else {
                        c.pointB = reference.point; c.directionB = reference.direction
                        c.sourceRevisionB = reference.revision
                    }
                }
                if var joint = c.joint, let oldB = old.directionB, let newB = c.directionB,
                   old.directionA != c.directionA || oldB != newB {
                    joint.phaseA = CADAssemblyJointMath.alignment(old.directionA, c.directionA).act(joint.phaseA)
                    joint.phaseB = CADAssemblyJointMath.alignment(oldB, newB).act(joint.phaseB)
                    let az = simd_normalize(c.directionA), bz = simd_normalize(newB)
                    let ax = simd_normalize(joint.phaseA), bx = simd_normalize(joint.phaseB)
                    let frameA = simd_quatd(simd_double3x3(columns: (ax, simd_cross(az, ax), az)))
                    let frameB = simd_quatd(simd_double3x3(columns: (bx, simd_cross(bz, bx), bz)))
                    joint.relativeRotation = simd_normalize(frameA * frameB.inverse).vector
                    c.joint = joint
                }
                if c != old { changed = true }
                return c
            }
        }
        func nested(_ input: [CADAssemblyInstance]) -> [CADAssemblyInstance] {
            input.map { original in
                var instance = original
                instance.children = nested(instance.children)
                instance.constraints = constraints(instance.constraints, instances: instance.children)
                if instance.constraints != original.constraints || instance.children != original.children {
                    let local = CADAssembly(instances: instance.children, constraints: instance.constraints)
                    let solved = CADAssemblySolver.solve(local, modelScale: scale(local))
                    if solved.solved { instance.children = solved.updatedInstances }
                }
                return instance
            }
        }
        result.instances = nested(result.instances)
        result.constraints = constraints(result.constraints, instances: result.instances)
        guard changed else { return original }
        let solved = CADAssemblySolver.solve(result, modelScale: scale(result))
        if solved.solved { result.instances = solved.updatedInstances }
        return result
    }

    private static func scale(_ assembly: CADAssembly) -> Double {
        assembly.instances.reduce(1) { max($0, simd_length($1.transform.position)) }
    }
}

/// Runs after the real rebuild's commands, so revision pins refer to the
/// adopted bodies. It is part of that same undo entry, not a later autosave.
final class RefreshCADAssemblyReferencesCommand: DocumentCommand {
    let title = "Update assembly references"
    private let kernelNames: [BodyID: [Int: ElementName]]
    private let requiredRevisions: [BodyID: UInt64]?
    private var captured = false
    private var before: Data?
    private var after: Data?

    init(kernelNames: [BodyID: [Int: ElementName]], requiredRevisions: [BodyID: UInt64]? = nil) {
        self.kernelNames = kernelNames; self.requiredRevisions = requiredRevisions
    }

    func apply(to document: inout DesignDocument) {
        if !captured {
            captured = true
            before = document.assemblyData
            after = before
            if !CADDocumentFormat.assemblyJointIntent(before).opaque,
               let assembly = try? CADAssembly.decode(from: before),
               assembly.constraintsWithScope().contains(where: { $0.constraint.bindingA != nil || $0.constraint.bindingB != nil }) {
                let names = kernelNames.filter { entry in
                    guard let requiredRevisions else { return true } // Owned rebuild's exact new maps.
                    return document.body(with: entry.key)?.meshRevision == requiredRevisions[entry.key]
                }
                let updated = CADAssemblyGeometryResolver.refresh(assembly, document: document, kernelNames: names)
                if let encoded = try? updated.encoded() { after = encoded }
            }
        }
        document.assemblyData = after
    }

    func revert(in document: inout DesignDocument) { document.assemblyData = before }
}
