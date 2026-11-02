//
//  TopoNaming.swift
//  openshape3d
//
//  Topological-naming facade (Phase D, task A2). A `TopoNaming` labels the faces
//  of a freshly built body with stable `FaceRole`s + geometric `FaceSignature`s,
//  propagates those labels through booleans/transforms/push-pull, and — the point
//  of the whole exercise — re-resolves a persisted `FaceRef` back to a concrete
//  face after the owning feature is rebuilt with different parameters.
//
//  Author-owned and native-history names follow parameter changes. Unnamed
//  compatibility references need a unique exact fingerprint, not a similarity
//  score. A recorded name that disappears cannot select a nearby surface.
//
//  All types are `nonisolated` (pure geometry, off the main actor) per repo
//  convention. Face signatures are computed in BODY-LOCAL space (`body.render`),
//  consistent between `faceTable` and `resolve`; `body.transform` is intentionally
//  ignored in tranche 1 (transform features are a tranche-2 concern).
//

import Foundation
import simd

// MARK: - Facade types (frozen contract)

/// The per-body label table produced when a feature builds a body: one entry per
/// enumerated face carrying its role, geometric signature, and triangle indices.
nonisolated struct FaceTable: Codable, Sendable {
    var entries: [Entry]
    /// Exact provenance of the adopted native tessellation. A display patch
    /// may contain adjacent coplanar native faces, so its majority name alone
    /// cannot locate each original face. Missing on old/mesh-only tables.
    var nativeFaceNames: [Int: ElementName]? = nil
    var nativeFaceChannel: [UInt32]? = nil
    var nativeBodyID: BodyID? = nil
    var nativeMeshRevision: UInt64? = nil
    /// Derived once for material readers; excluded from cache serialization.
    var nativeFaceSignatures: [Int: FaceSignature]? = nil

    private enum CodingKeys: String, CodingKey {
        case entries, nativeFaceNames, nativeFaceChannel, nativeBodyID, nativeMeshRevision
    }

    struct Entry: Codable, Sendable {
        var role: FaceRole
        var signature: FaceSignature
        var triangles: [Int]
        /// Kernel-history identity, when one could be derived without
        /// guessing (docs/TOPO_NAMING_HISTORY_DESIGN.md step 2). Nil is
        /// normal for legacy geometry; an already-named reference cannot use
        /// this unnamed entry to bypass a missing identity.
        var elementName: ElementName? = nil
    }

    init(entries: [Entry] = []) { self.entries = entries }

    /// Used only after an owned history/memo transfer restores the exact
    /// geometry paired with this table. ReplaceBodyCommand legitimately
    /// re-mints the revision; this is not permission to bless an arbitrary
    /// old table against new geometry.
    func rebindingNativeRevision(afterOwnedRestore body: Body) -> FaceTable {
        guard nativeBodyID == body.id, body.brep != nil,
              nativeFaceNames != nil || nativeFaceSignatures != nil,
              nativeFaceChannel == nil || nativeFaceChannel?.count == body.render.triangleCount else { return self }
        // Imported/primitive faces can have exact signatures without authored
        // names or a native triangle channel. An owned geometry restore keeps
        // those same entries; stamping its new revision creates no face name.
        var result = self
        result.nativeMeshRevision = body.meshRevision
        return result
    }
}

/// How a body was built — drives which `FaceRole`s the faces are labelled with.
nonisolated enum FaceScheme: Sendable {
    case primitive(PrimitiveSpec)
    case extrude(Profile)
    case revolve
    /// Authored end-section planes of a loft, including its mesh-only path.
    case loftCaps(start: SketchPlane, end: SketchPlane)
    case generic
}

/// A topology-mutating operation, so `propagate` can specialise if needed.
nonisolated enum TopoOp: Sendable {
    case boolean(BooleanKind)
    case transform(Transform3D)
    case pushPull
}

/// Issued by the resolver's actual branch, never inferred from confidence or
/// from the name that happens to be on today's matching geometry.
nonisolated enum FaceIdentityProof: Sendable {
    case currentGeometry
    case recordedQualifiedName
    case recordedSemanticRole

    var permitsPersistentReplay: Bool {
        switch self {
        case .currentGeometry: return false
        case .recordedQualifiedName, .recordedSemanticRole: return true
        }
    }
}

/// The concrete face a `FaceRef` resolved to, plus the match confidence [0,1].
nonisolated struct ResolvedFace: Sendable {
    var planar: FaceTopology.PlanarFace?
    var cylinder: FaceTopology.CylindricalFace?
    var confidence: Double
    var triangles: [Int] { planar?.triangles ?? cylinder?.triangles ?? [] }
    /// The matched table entry's kernel-history name, when the table has one
    /// for the matched face — what the step-5b opportunistic upgrade writes
    /// back onto legacy refs. Nil is normal (no table, unnamed face).
    var elementName: ElementName? = nil
    /// How decisively the signature match beat its runner-up; nil when there
    /// was no other candidate. Upgrades require a clear margin — pinning a
    /// name onto a near-tie would bake in a coin flip.
    var margin: Double? = nil
    var identityProof: FaceIdentityProof = .currentGeometry
}

/// Swappable topological-naming strategy. Tranche 1 = `SignatureNaming`.
nonisolated protocol TopoNaming: Sendable {
    /// Label every face of a just-built `body` (created by `createdBy`) per `scheme`.
    func faceTable(for body: Body, createdBy: FeatureID, scheme: FaceScheme) -> FaceTable
    /// Re-label the faces of `output` (result of `op`) by best-matching the
    /// `inputs`' entries; unmatched faces fall back to `derived(index:)`.
    func propagate(inputs: [FaceTable], output: Body, op: TopoOp) -> FaceTable
    /// Re-resolve a persisted `ref` against `body`'s current faces (optionally
    /// boosted by a `table`'s roles). Named refs require their recorded identity;
    /// unnamed legacy refs return a matching face above threshold, else nil.
    func resolve(_ ref: FaceRef, in body: Body, table: FaceTable?) -> ResolvedFace?
}

nonisolated extension TopoNaming {
    /// History replay must prove the recorded intent. Fresh picking keeps
    /// using resolve so an unqualified current face remains selectable.
    func resolvePersisted(_ ref: FaceRef, in body: Body, table: FaceTable?) -> ResolvedFace? {
        guard let face = resolve(ref, in: body, table: table),
              face.identityProof.permitsPersistentReplay else { return nil }
        return face
    }
}

// MARK: - SignatureNaming (tranche 1)

/// Geometric topological naming: faces are matched by normal alignment, centroid
/// proximity (scaled by the body's bbox diagonal), and area ratio. Zero mesh /
/// persistence format change — the ground-truth resolver.
nonisolated struct SignatureNaming: TopoNaming {

    // MARK: Scoring weights (reported in A2 deliverable)

    /// Weight on normal alignment  = max(0, n·refN).           Dominant term.
    static let wNormal: Double = 0.5
    /// Weight on centroid proximity = 1 - min(1, dist/bboxDiag).
    static let wCentroid: Double = 0.3
    /// Weight on area similarity    = 1 - min(1, |1 - area/refArea|).
    static let wArea: Double = 0.2
    /// Additive boost when a candidate's table role equals `ref.role`.
    static let roleBoost: Double = 0.2
    /// A face must score at least this to `resolve`.
    static let resolveThreshold: Double = 0.6

    /// Ambiguity margin for upgrading an unnamed legacy signature reference
    /// to a kernel-history identity. A named reference never falls back to
    /// geometric resemblance when its actual identity is missing.
    static let nameMissMargin: Double = 0.05

    /// Bar for the 5b opportunistic upgrade: a legacy ref only gains a name
    /// when its signature resolution was this confident (well above the 0.6
    /// acceptance bar) AND cleared `nameMissMargin`. Upgrading a marginal
    /// match would bake today's coin flip into tomorrow's identity.
    static let upgradeConfidence: Double = 0.85
    /// An output face must score at least this to inherit an input entry's role.
    static let propagateThreshold: Double = 0.55

    /// Max `faces × inputEntries` score evaluations one propagate may spend
    /// before degrading wholesale to area-rank roles. ~250k scores is tens
    /// of milliseconds; a degenerate tessellation blows far past it.
    static let propagateBudget = 250_000

    // Base weights sum to 1.0, so a candidate whose normal is orthogonal to the
    // target (n·refN = 0) caps at wCentroid + wArea = 0.5 < resolveThreshold —
    // i.e. a face pointing the wrong way can never resolve. An aligned face
    // (n·refN = 1) ranges [0.5, 1.0]. This is what makes a removed/rotated-away
    // face resolve to nil while a moved/grown same-orientation face still hits.

    init() {}

    // MARK: TopoNaming

    func faceTable(for body: Body, createdBy: FeatureID, scheme: FaceScheme) -> FaceTable {
        let faces = Self.enumerate(body.render)
        let roles = assignRoles(faces: faces, scheme: scheme)
        var entries = zip(faces, roles).map { face, role in
            FaceTable.Entry(role: role, signature: face.signature, triangles: face.triangles)
        }
        if case .loftCaps = scheme {
            for index in entries.indices {
                let role = entries[index].role
                let end: Bool
                switch role {
                case .extrudeStartCap: end = false
                case .extrudeEndCap: end = true
                default: continue
                }
                guard entries.filter({ $0.role == role }).count == 1 else { continue }
                entries[index].elementName = ElementName(creator: createdBy, source: .profileCap(end: end))
            }
        }
        return FaceTable(entries: entries)
    }

    /// A table describing the body's CURRENT render exactly, with no feature
    /// graph replay and no revision counter. A reopened document has no applied
    /// rebuild to retain a table from, so per-face material ranges are derived
    /// from the restored mesh with the same enumeration and signature formulas
    /// the naming table uses. Roles are area-rank `derived` roles; material
    /// resolution matches signatures and triangles, never roles or indices.
    static func currentFaceTable(for body: Body) -> FaceTable {
        let faces = Self.enumerate(body.render)
        let roles = Self.derivedRoles(faces)
        let entries = zip(faces, roles).map { face, role in
            FaceTable.Entry(role: role, signature: face.signature, triangles: face.triangles)
        }
        return FaceTable(entries: entries)
    }

    func propagate(inputs: [FaceTable], output: Body, op: TopoOp) -> FaceTable {
        let faces = Self.enumerate(output.render)
        let diag = Self.bboxDiagonal(output.render)
        let inputEntries = inputs.flatMap { $0.entries }

        // Area-rank fallback for faces that match nothing well.
        let areaOrder = faces.indices.sorted { faces[$0].signature.area > faces[$1].signature.area }
        var rankOf = [Int: Int]()
        for (rank, idx) in areaOrder.enumerated() { rankOf[idx] = rank }

        // PATHOLOGY BUDGET. This pass is O(faces × inputs), which is fine
        // for the tens-of-faces bodies it was built for — and wedged the
        // MainActor for MINUTES when a tangent-contact fuse tessellated
        // into tens of thousands of sliver faces (Motorcycle-cover nub,
        // 2026-09-01, found by sampling the spin). Past the budget every
        // face takes the area-rank fallback role: roles are a resolve
        // TIEBREAK, honest degradation is bounded time, and element names
        // (attached separately) are unaffected.
        if faces.count * max(inputEntries.count, 1) > Self.propagateBudget {
            return FaceTable(entries: faces.enumerated().map { i, face in
                .init(role: .derived(index: rankOf[i] ?? i),
                      signature: face.signature, triangles: face.triangles)
            })
        }

        var entries: [FaceTable.Entry] = []
        entries.reserveCapacity(faces.count)
        for (i, face) in faces.enumerated() {
            var bestScore = -Double.infinity
            var bestRole: FaceRole?
            for entry in inputEntries {
                let s = score(face.signature, against: entry.signature, bboxDiag: diag)
                if s > bestScore { bestScore = s; bestRole = entry.role }
            }
            let role: FaceRole
            if let bestRole, bestScore >= Self.propagateThreshold {
                role = bestRole
            } else {
                role = .derived(index: rankOf[i] ?? i)
            }
            entries.append(.init(role: role, signature: face.signature, triangles: face.triangles))
        }
        return FaceTable(entries: entries)
    }

    func resolve(_ ref: FaceRef, in body: Body, table: FaceTable?) -> ResolvedFace? {
        guard ref.body.bodyID == body.id else { return nil }
        let faces = Self.enumerate(body.render)
        guard !faces.isEmpty else { return nil }

        // NAME FIRST (docs/TOPO_NAMING_HISTORY_DESIGN.md step 4): an exact
        // kernel-history identity hit outranks any geometric score, because
        // identity is what the score was always trying to approximate. Table
        // entries and enumerated faces align row-for-row (both come from the
        // same `enumerate` partition) — verified by triangle set before
        // trusting, and the hit is sanity-checked against the signature's
        // KIND. Losing a recorded identity is a broken reference, even if a
        // newly created face happens to have identical geometry.
        if let name = ref.elementName {
            guard let table else { return nil }
            if let names = table.nativeFaceNames, let channel = table.nativeFaceChannel {
                guard table.nativeBodyID == body.id, table.nativeMeshRevision == body.meshRevision else { return nil }
                let indices = names.compactMap { $0.value == name ? $0.key : nil }
                guard indices.count == 1, let index = indices.first else { return nil }
                return Self.resolveNativeFace(ref, index: index, channel: channel,
                                              body: body, fullFaces: faces)
            }
            let matches = table.entries.enumerated().filter { $0.element.elementName == name }
            guard matches.count == 1, let match = matches.first, match.offset < faces.count else { return nil }
            let entry = match.element, face = faces[match.offset]
            guard face.triangles == entry.triangles,
                  Self.kindCompatible(face.signature.kind, ref.signature.kind) else { return nil }
            if name.requiresExactSignature,
               !Self.exactSignature(face.signature, ref.signature) {
                // Commands mint analytic signatures; UI picks mint render
                // signatures. An unchanged legacy face may prove either, but
                // only at the SAME uniquely named/channel-mapped candidate.
                guard let brep = body.brep,
                      table.nativeBodyID == body.id, table.nativeMeshRevision == body.meshRevision,
                      let channel = table.nativeFaceChannel, channel.count == body.render.triangleCount,
                      let index = ElementNaming.kernelFace(of: entry, channel: channel),
                      let signature = OCCTKernel.faceInfo(brep).first(where: { $0.index == index })?.signature,
                      Self.exactSignature(signature, ref.signature) else { return nil }
            }
            return ResolvedFace(planar: face.planar, cylinder: face.cylinder,
                                confidence: 1, elementName: name,
                                identityProof: name.isStableFaceIdentity ? .recordedQualifiedName : .currentGeometry)
        }

        // Some old refs already contain an author-owned primitive/cap role.
        // Reconstruct only that exact creator+role identity, never an edge or
        // face ordinal. This preserves ordinary legacy box/cap parameter edits.
        let semantic: ElementName.Source?
        switch ref.role {
        case .boxFace, .cylinderSide, .cylinderCap, .sphereSurface:
            semantic = .primitiveFace(ref.role)
        case .extrudeStartCap: semantic = .profileCap(end: false)
        case .extrudeEndCap: semantic = .profileCap(end: true)
        default: semantic = nil
        }
        if let semantic, let table {
            let name = ElementName(creator: ref.creator, source: semantic)
            let matches = table.entries.enumerated().filter { $0.element.elementName == name }
            if matches.count == 1, let match = matches.first, match.offset < faces.count {
                let face = faces[match.offset]
                if face.triangles == match.element.triangles,
                   Self.kindCompatible(face.signature.kind, ref.signature.kind) {
                    return ResolvedFace(planar: face.planar, cylinder: face.cylinder,
                        confidence: 1, elementName: name, margin: .infinity,
                        identityProof: .recordedSemanticRole)
                }
            }
        }
        // An unqualified fingerprint needs exactly one full current match.
        // A body-scaled score would bind a deleted cap to a nearby survivor.
        var nativeSignatures: [Int: FaceSignature]?
        let matches = faces.indices.filter { index in
            let face = faces[index]
            if Self.exactSignature(face.signature, ref.signature) { return true }
            guard let table, index < table.entries.count,
                  table.entries[index].triangles == face.triangles,
                  table.nativeBodyID == body.id, table.nativeMeshRevision == body.meshRevision,
                  let channel = table.nativeFaceChannel, channel.count == body.render.triangleCount,
                  let brep = body.brep else { return false }
            if nativeSignatures == nil {
                nativeSignatures = Dictionary(uniqueKeysWithValues: OCCTKernel.faceInfo(brep).compactMap {
                    info in info.signature.map { (info.index, $0) }
                })
            }
            guard let native = ElementNaming.kernelFace(of: table.entries[index], channel: channel),
                  let signature = nativeSignatures?[native] else { return false }
            return Self.exactSignature(signature, ref.signature)
        }
        guard matches.count == 1, let index = matches.first else { return nil }
        let face = faces[index]
        var matchedName: ElementName?
        if let table, index < table.entries.count, table.entries[index].triangles == face.triangles {
            matchedName = table.entries[index].elementName
        }
        return ResolvedFace(planar: face.planar, cylinder: face.cylinder,
                            confidence: 1, elementName: matchedName, margin: .infinity)
    }

    /// Slice the current native face's OWN triangles before recovering its
    /// editing geometry. Display grouping may have merged it with a coplanar
    /// neighbor; neither a majority vote nor the neighbor's outline is its
    /// geometry. The channel comes only from the adopted native mesh.
    private static func resolveNativeFace(_ ref: FaceRef, index: Int, channel: [UInt32],
                                          body: Body, fullFaces: [EnumeratedFace]) -> ResolvedFace? {
        guard let native = UInt32(exactly: index), native > 0,
              ref.elementName?.hasSupportedOperationIdentity != false,
              body.render.indices.count % 3 == 0,
              channel.count == body.render.triangleCount,
              let brep = body.brep,
              let signature = OCCTKernel.faceInfo(brep).first(where: { $0.index == index })?.signature,
              kindCompatible(signature.kind, ref.signature.kind) else { return nil }
        let selected = channel.indices.filter { channel[$0] == native }
        guard !selected.isEmpty else { return nil }
        var mesh = body.render
        mesh.indices = selected.flatMap { triangle in
            Array(body.render.indices[(triangle * 3)..<(triangle * 3 + 3)])
        }
        let patches = enumerate(mesh).filter { kindCompatible($0.signature.kind, signature.kind) }
        guard patches.count == 1, var face = patches.first else { return nil }
        if ref.elementName?.requiresExactSignature == true,
           !exactSignature(signature, ref.signature), !exactSignature(face.signature, ref.signature) { return nil }
        if var plane = face.planar {
            guard plane.triangles.allSatisfy({ selected.indices.contains($0) }) else { return nil }
            plane.triangles = plane.triangles.map { selected[$0] }
            face.planar = plane
        }
        if var cylinder = face.cylinder {
            guard cylinder.triangles.allSatisfy({ selected.indices.contains($0) }) else { return nil }
            cylinder.triangles = cylinder.triangles.map { selected[$0] }
            // A sliced side mesh has no caps. Preserve the existing whole-
            // body flag only when the original fit covered these SAME facets.
            let triangles = Set(cylinder.triangles)
            cylinder.matchesWholeBody = fullFaces.contains {
                $0.cylinder?.matchesWholeBody == true && Set($0.triangles) == triangles
            }
            face.cylinder = cylinder
        }
        return ResolvedFace(planar: face.planar, cylinder: face.cylinder,
                            confidence: 1, elementName: ref.elementName,
                            identityProof: ref.elementName?.isStableFaceIdentity == true
                                ? .recordedQualifiedName : .currentGeometry)
    }

    // MARK: Scoring

    /// Geometric similarity of a candidate signature to a reference, in [0,1]
    /// (before any role boost). See the class comment for the weight rationale.
    private func score(
        _ candidate: FaceSignature, against ref: FaceSignature, bboxDiag diag: Double
    ) -> Double {
        let nAlign = Self.normalAlignment(candidate, ref)
        let dist = simd_length(candidate.centroid - ref.centroid)
        let cProx = 1 - min(1, dist / max(diag, 1e-9))
        let aSim: Double
        if ref.area > 1e-12 {
            aSim = 1 - min(1, abs(1 - candidate.area / ref.area))
        } else {
            aSim = candidate.area < 1e-12 ? 1 : 0
        }
        return Self.wNormal * nAlign + Self.wCentroid * cProx + Self.wArea * aSim
    }

    /// How well a candidate's normal agrees with the reference's, clamped to
    /// [0, 1]. Zero means orthogonal or pointing away — the case the weights
    /// are designed to make unresolvable.
    static func normalAlignment(_ candidate: FaceSignature, _ ref: FaceSignature) -> Double {
        max(0, simd_dot(unit(candidate.normal), unit(ref.normal)))
    }

    /// Whether two signature kinds can name the same face. Same surface
    /// class only; a cylindrical ref's radius is free to differ (edits
    /// change it), so the associated value is deliberately ignored.
    static func kindCompatible(_ a: FaceSignature.Kind, _ b: FaceSignature.Kind) -> Bool {
        switch (a, b) {
        case (.planar, .planar): return true
        case (.cylindrical, .cylindrical): return true
        default: return false
        }
    }

    /// Necessary fingerprint check for an ordinal reference, not a similarity
    /// score or a new stable identity. The body size never widens the position
    /// tolerance. Semantic primitive/profile names may follow parameter edits.
    static func exactSignature(_ a: FaceSignature, _ b: FaceSignature) -> Bool {
        func finite(_ p: SIMD3<Double>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }
        func near(_ x: Double, _ y: Double) -> Bool {
            x.isFinite && y.isFinite && abs(x - y) <= max(1e-6, max(abs(x), abs(y)) * 1e-6)
        }
        guard finite(a.centroid), finite(b.centroid), finite(a.normal), finite(b.normal),
              a.area.isFinite, b.area.isFinite, a.area > 0, b.area > 0,
              simd_length(a.normal) > 1e-8, simd_length(b.normal) > 1e-8,
              near(a.area, b.area), simd_distance(a.centroid, b.centroid) <= 1e-5 else { return false }
        let alignment = simd_dot(simd_normalize(a.normal), simd_normalize(b.normal))
        switch (a.kind, b.kind) {
        case (.planar, .planar):
            return alignment >= 1 - 1e-8 && near(a.planeOffset, b.planeOffset)
        case let (.cylindrical(radiusA), .cylindrical(radiusB)):
            return radiusA > 0 && radiusB > 0 && near(radiusA, radiusB)
                && abs(alignment) >= 1 - 1e-8
        default: return false
        }
    }

    /// Native frozen-writer consumers use the same policy as History. An
    /// ordinal match needs the full current signature; a semantic name needs
    /// the same surface kind and its unique native identity.
    static func acceptsNamedSignature(_ name: ElementName, current: FaceSignature,
                                      reference: FaceSignature) -> Bool {
        kindCompatible(current.kind, reference.kind)
            && (!name.requiresExactSignature || exactSignature(current, reference))
    }

    /// The role the `table` assigns to `face`: its own row when the table
    /// aligns with the enumeration (verified by triangle set — O(1)), else
    /// the closest entry by signature, and only while that scan is affordable.
    private func roleFromTable(
        for face: EnumeratedFace, at index: Int, table: FaceTable,
        bboxDiag diag: Double, scanAllowed: Bool
    ) -> FaceRole? {
        if index < table.entries.count, table.entries[index].triangles == face.triangles {
            return table.entries[index].role
        }
        guard scanAllowed else { return nil }
        var best: (score: Double, role: FaceRole)?
        for entry in table.entries {
            let s = score(face.signature, against: entry.signature, bboxDiag: diag)
            if best == nil || s > best!.score { best = (s, entry.role) }
        }
        return best?.role
    }

    // MARK: Role assignment by scheme

    private func assignRoles(faces: [EnumeratedFace], scheme: FaceScheme) -> [FaceRole] {
        switch scheme {
        case let .primitive(spec):
            switch spec {
            case .box:      return rolesForBox(faces)
            case .cylinder: return rolesForCylinder(faces)
            case .sphere:   return faces.map { _ in .sphereSurface }
            }
        case let .extrude(profile):
            return rolesForExtrude(profile, faces: faces)
        case let .loftCaps(start, end):
            var roles = Self.derivedRoles(faces)
            var claims: [Int: [FaceRole]] = [:]
            for (plane, role) in [(start, FaceRole.extrudeStartCap), (end, FaceRole.extrudeEndCap)] {
                guard simd_length_squared(plane.normal) > 1e-18 else { continue }
                let normal = simd_normalize(plane.normal)
                for (index, face) in faces.enumerated() where face.planar != nil {
                    let point = face.signature.centroid
                    let tolerance = max(1e-5, simd_length(point) * Double(Float.ulpOfOne) * 2)
                    guard abs(simd_dot(normal, face.signature.normal)) >= 1 - 1e-6,
                          abs(simd_dot(point - plane.origin, normal)) <= tolerance else { continue }
                    claims[index, default: []].append(role)
                }
            }
            // Only an unambiguous authored end plane can name a cap. Neither
            // area order nor a face ordinal supplies the construction role.
            for (index, candidates) in claims where candidates.count == 1 { roles[index] = candidates[0] }
            return roles
        case .revolve, .generic:
            return Self.derivedRoles(faces)
        }
    }

    private func rolesForBox(_ faces: [EnumeratedFace]) -> [FaceRole] {
        faces.enumerated().map { idx, face in
            face.planar != nil
                ? .boxFace(Self.boxFace(for: face.signature.normal))
                : .derived(index: idx)
        }
    }

    private func rolesForCylinder(_ faces: [EnumeratedFace]) -> [FaceRole] {
        // Axis from the fitted side surface, else the primitive's +Y build axis.
        var axis = SIMD3<Double>(0, 1, 0)
        for face in faces {
            if let cyl = face.cylinder { axis = Self.unit(cyl.axisDir); break }
        }
        let caps = faces.indices.filter { faces[$0].planar != nil }
        let axialPos = caps.map { simd_dot(faces[$0].signature.centroid, axis) }
        let maxPos = axialPos.max() ?? 0

        var roles = [FaceRole](repeating: .cylinderSide, count: faces.count)
        for (k, capIdx) in caps.enumerated() {
            roles[capIdx] = .cylinderCap(top: axialPos[k] >= maxPos - 1e-6)
        }
        // Non-cap, non-cylinder faces (shouldn't happen for a clean cylinder).
        for i in faces.indices where faces[i].planar == nil && faces[i].cylinder == nil {
            roles[i] = .derived(index: i)
        }
        return roles
    }

    private func rolesForExtrude(_ profile: Profile, faces: [EnumeratedFace]) -> [FaceRole] {
        var roles = [FaceRole?](repeating: nil, count: faces.count)
        let profileArea = abs(profile.area)
        let planar = faces.indices.filter { faces[$0].planar != nil }

        // Caps: the anti-parallel planar pair whose areas best match the profile.
        var bestPair: (Int, Int)?
        var bestScore = -Double.infinity
        for a in 0..<planar.count {
            for b in (a + 1)..<planar.count {
                let sa = faces[planar[a]].signature
                let sb = faces[planar[b]].signature
                let anti = -simd_dot(Self.unit(sa.normal), Self.unit(sb.normal))
                guard anti > 0.9 else { continue }
                let areaMatch = 1 - min(1,
                    (abs(sa.area - profileArea) + abs(sb.area - profileArea)) / max(profileArea, 1e-9))
                let s = anti + areaMatch
                if s > bestScore { bestScore = s; bestPair = (planar[a], planar[b]) }
            }
        }

        var axis = SIMD3<Double>(0, 1, 0)
        var capCenter = SIMD3<Double>.zero
        if let (i, j) = bestPair {
            let ti = simd_dot(faces[i].signature.centroid, Self.unit(faces[i].signature.normal))
            // Start cap = lower along the extrude axis (deterministic tie-break).
            let axisI = Self.unit(faces[i].signature.normal)
            let tj = simd_dot(faces[j].signature.centroid, axisI)
            if ti <= tj {
                roles[i] = .extrudeStartCap; roles[j] = .extrudeEndCap
            } else {
                roles[i] = .extrudeEndCap;   roles[j] = .extrudeStartCap
            }
            axis = axisI
            capCenter = (faces[i].signature.centroid + faces[j].signature.centroid) / 2
        }

        // Walls: match each to a profile edge by angular order around the axis.
        let (bx, by) = Self.perpendicularBasis(axis)
        let loop = profile.loop
        let profCentroid = profile.centroid
        var profileEdges: [(index: Int, angle: Double)] = []
        for e in loop.indices {
            let mid = (loop[e] + loop[(e + 1) % loop.count]) / 2 - profCentroid
            profileEdges.append((e, atan2(mid.y, mid.x)))
        }
        profileEdges.sort { $0.angle < $1.angle }

        var walls: [(faceIndex: Int, angle: Double)] = []
        for k in faces.indices where roles[k] == nil {
            let d = faces[k].signature.centroid - capCenter
            walls.append((k, atan2(simd_dot(d, by), simd_dot(d, bx))))
        }
        walls.sort { $0.angle < $1.angle }
        for (rank, wall) in walls.enumerated() {
            let edgeIndex = profileEdges.isEmpty ? rank : profileEdges[rank % profileEdges.count].index
            roles[wall.faceIndex] = .extrudeWall(loopIndex: 0, edgeIndex: edgeIndex)
        }

        // Anything still unlabelled → area-rank derived.
        let fallback = Self.derivedRoles(faces)
        return roles.indices.map { roles[$0] ?? fallback[$0] }
    }

    private static func derivedRoles(_ faces: [EnumeratedFace]) -> [FaceRole] {
        let order = faces.indices.sorted { faces[$0].signature.area > faces[$1].signature.area }
        var roles = [FaceRole](repeating: .derived(index: 0), count: faces.count)
        for (rank, idx) in order.enumerated() { roles[idx] = .derived(index: rank) }
        return roles
    }

    // MARK: Face enumeration + signatures

    /// A face of a body, with its geometry and precomputed signature.
    private struct EnumeratedFace {
        var planar: FaceTopology.PlanarFace?
        var cylinder: FaceTopology.CylindricalFace?
        var signature: FaceSignature
        var triangles: [Int]
    }

    /// Group a body's triangles into faces (planar patches + cylindrical side
    /// surfaces), each with its `FaceSignature`. Delegates to A1's whole-mesh
    /// `FaceTopology.enumerateFaces`, the single source of truth for the partition.
    private static func enumerate(_ mesh: RenderMesh) -> [EnumeratedFace] {
        let result = FaceTopology.enumerateFaces(in: mesh)
        var faces: [EnumeratedFace] = []
        faces.reserveCapacity(result.planar.count + result.cylindrical.count)
        for planar in result.planar {
            faces.append(EnumeratedFace(
                planar: planar, cylinder: nil,
                signature: signature(planar: planar), triangles: planar.triangles))
        }
        for cyl in result.cylindrical {
            faces.append(EnumeratedFace(
                planar: nil, cylinder: cyl,
                signature: signature(cylinder: cyl), triangles: cyl.triangles))
        }
        return faces
    }

    /// Internal, not private: `DeleteFaceKit` mints refs for LIVE picks and
    /// must produce byte-identical signatures to the ones `enumerate` records,
    /// or the ref it stores will not resolve on replay. Two copies of these
    /// formulas would drift silently — the failure would look like "delete
    /// face forgets its face after a rebuild".
    static func signature(planar face: FaceTopology.PlanarFace) -> FaceSignature {
        let n = SIMD3<Double>(Double(face.normal.x), Double(face.normal.y), Double(face.normal.z))
        let centroid = face.origin // loop centroid, in body-local space
        var area = abs(Profile.signedArea(face.outline))
        for hole in face.holes { area -= abs(Profile.signedArea(hole)) }
        return FaceSignature(
            kind: .planar, normal: n, centroid: centroid,
            area: max(area, 0), planeOffset: simd_dot(n, centroid))
    }

    static func signature(cylinder cyl: FaceTopology.CylindricalFace) -> FaceSignature {
        let axis = unit(cyl.axisDir)
        let centroid = cyl.baseCenter + axis * (cyl.height / 2)
        let area = 2 * Double.pi * cyl.radius * cyl.height
        return FaceSignature(
            kind: .cylindrical(radius: cyl.radius), normal: axis, centroid: centroid,
            area: area, planeOffset: simd_dot(axis, centroid))
    }

    // MARK: Small helpers

    private static func unit(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = simd_length(v)
        return l > 1e-12 ? v / l : v
    }

    private static func bboxDiagonal(_ mesh: RenderMesh) -> Double {
        let (lo, hi) = mesh.localAABB
        let d = SIMD3<Double>(Double(hi.x - lo.x), Double(hi.y - lo.y), Double(hi.z - lo.z))
        let len = simd_length(d)
        return len > 1e-9 ? len : 1
    }

    /// The signed ±X/±Y/±Z box face whose axis a normal points most strongly along.
    private static func boxFace(for normal: SIMD3<Double>) -> BoxFace {
        let ax = abs(normal.x), ay = abs(normal.y), az = abs(normal.z)
        if ax >= ay && ax >= az { return normal.x >= 0 ? .px : .nx }
        if ay >= az            { return normal.y >= 0 ? .py : .ny }
        return normal.z >= 0 ? .pz : .nz
    }

    /// Two unit vectors spanning the plane perpendicular to `axis`.
    private static func perpendicularBasis(_ axis: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let a = unit(axis)
        let ref = abs(a.y) < 0.9 ? SIMD3<Double>(0, 1, 0) : SIMD3<Double>(1, 0, 0)
        let bx = unit(simd_cross(ref, a))
        let by = simd_cross(a, bx)
        return (bx, by)
    }
}
