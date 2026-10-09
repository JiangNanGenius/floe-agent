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
//  Tranche 1 ships the geometric `SignatureNaming`: a face is identified by its
//  normal + centroid + area, so a `FaceRef` survives a rebuild that moves/grows
//  the face (a bigger box's +Z face is still the +Z face). `MaterialTagNaming`
//  (O(1) tag lookup) is a tranche-2 swap behind this same facade.
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

    struct Entry: Codable, Sendable {
        var role: FaceRole
        var signature: FaceSignature
        var triangles: [Int]
        /// Kernel-history identity, when one could be derived without
        /// guessing (docs/TOPO_NAMING_HISTORY_DESIGN.md step 2). Nil is
        /// normal — signature matching stays the universal fallback.
        var elementName: ElementName? = nil
    }

    init(entries: [Entry] = []) { self.entries = entries }
}

/// How a body was built — drives which `FaceRole`s the faces are labelled with.
nonisolated enum FaceScheme: Sendable {
    case primitive(PrimitiveSpec)
    case extrude(Profile)
    case revolve
    case generic
}

/// A topology-mutating operation, so `propagate` can specialise if needed.
nonisolated enum TopoOp: Sendable {
    case boolean(BooleanKind)
    case transform(Transform3D)
    case pushPull
}

/// The concrete face a `FaceRef` resolved to, plus the match confidence [0,1].
nonisolated struct ResolvedFace: Sendable {
    var planar: FaceTopology.PlanarFace?
    var cylinder: FaceTopology.CylindricalFace?
    var confidence: Double
    /// The matched table entry's kernel-history name, when the table has one
    /// for the matched face — what the step-5b opportunistic upgrade writes
    /// back onto legacy refs. Nil is normal (no table, unnamed face).
    var elementName: ElementName? = nil
    /// How decisively the signature match beat its runner-up; nil when there
    /// was no other candidate. Upgrades require a clear margin — pinning a
    /// name onto a near-tie would bake in a coin flip.
    var margin: Double? = nil
}

/// Swappable topological-naming strategy. Tranche 1 = `SignatureNaming`.
nonisolated protocol TopoNaming: Sendable {
    /// Label every face of a just-built `body` (created by `createdBy`) per `scheme`.
    func faceTable(for body: Body, createdBy: FeatureID, scheme: FaceScheme) -> FaceTable
    /// Re-label the faces of `output` (result of `op`) by best-matching the
    /// `inputs`' entries; unmatched faces fall back to `derived(index:)`.
    func propagate(inputs: [FaceTable], output: Body, op: TopoOp) -> FaceTable
    /// Re-resolve a persisted `ref` against `body`'s current faces (optionally
    /// boosted by a `table`'s roles). Returns the best face above threshold, else nil.
    func resolve(_ ref: FaceRef, in body: Body, table: FaceTable?) -> ResolvedFace?
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

    /// Ambiguity gate for a ref whose kernel-history NAME missed (step 4):
    /// the signature fallback must beat its runner-up by at least this much,
    /// or the resolve reports broken instead of guessing between near-ties.
    /// Applies only to name-bearing refs — legacy refs resolve as they
    /// always did.
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
        let faces = Self.enumerate(body.render)
        guard !faces.isEmpty else { return nil }
        let diag = Self.bboxDiagonal(body.render)

        // NAME FIRST (docs/TOPO_NAMING_HISTORY_DESIGN.md step 4): an exact
        // kernel-history identity hit outranks any geometric score, because
        // identity is what the score was always trying to approximate. Table
        // entries and enumerated faces align row-for-row (both come from the
        // same `enumerate` partition) — verified by triangle set before
        // trusting, and the hit is sanity-checked against the signature's
        // KIND: a name pointing at an incompatible face is a miss to fall
        // through from, never an instruction to obey.
        if let name = ref.elementName, let table {
            for (index, entry) in table.entries.enumerated()
            where entry.elementName == name {
                guard index < faces.count else { break }
                let face = faces[index]
                guard face.triangles == entry.triangles,
                      Self.kindCompatible(face.signature.kind, ref.signature.kind)
                else { break }
                return ResolvedFace(planar: face.planar,
                                    cylinder: face.cylinder,
                                    confidence: 1,
                                    elementName: name)
            }
        }

        var best: (score: Double, index: Int, face: EnumeratedFace)?
        var runnerUpScore: Double?
        // The role boost's table lookup is O(1) when the table's rows align
        // with `enumerate` (they do, for a table of this render); a
        // misaligned table falls back to a scan, but only within the same
        // budget `propagate` keeps. Without the cap this loop was
        // O(faces × entries): a revolved spline bottle (tens of thousands of
        // facet faces) sat in here for minutes resolving a shell's one open
        // face (2026-09-02).
        let scanAllowed = faces.count * (table?.entries.count ?? 0) <= Self.propagateBudget
        for (index, face) in faces.enumerated() {
            // The ref knows what KIND of surface it referenced, and until now
            // nothing read it (review R4-N4): a cylindrical ref could bind a
            // planar cap whenever centroid and area happened to line up, and
            // the downstream op then deformed the wrong face. The kind is a
            // hard veto; its radius is NOT compared — edits legitimately
            // change it, and the area term already reflects size.
            guard Self.kindCompatible(face.signature.kind, ref.signature.kind)
            else { continue }
            var s = score(face.signature, against: ref.signature, bboxDiag: diag)
            // Boost candidates whose recorded role (from the table) matches the ref.
            //
            // ONLY when the candidate actually points the right way. The base
            // weights are chosen so an orthogonal-or-worse face caps at 0.5 <
            // resolveThreshold (see the comment above), but adding the boost
            // AFTER that cap defeated it: a face pointing the opposite way
            // reached 0.5 + 0.2 = 0.7 and resolved. On a plate whose +Y face
            // an upstream edit removed, the ref then silently bound to the −Y
            // face and the push/pull deformed the wrong side, with no broken-
            // ref badge (2026-08-25 review round 4). Gating on the alignment
            // term itself — not on the composite score — keeps the legitimate
            // "moved and resized but same orientation" case resolving.
            if Self.normalAlignment(face.signature, ref.signature) > 0,
               let table,
               let role = roleFromTable(for: face, at: index, table: table,
                                        bboxDiag: diag, scanAllowed: scanAllowed),
               role == ref.role {
                s += Self.roleBoost
            }
            if best == nil || s > best!.score {
                runnerUpScore = best?.score
                best = (s, index, face)
            } else if runnerUpScore == nil || s > runnerUpScore! {
                runnerUpScore = s
            }
        }
        guard let best, best.score >= Self.resolveThreshold else { return nil }
        let margin = runnerUpScore.map { best.score - $0 }
        // A ref that CARRIED a name and missed it is on notice: something
        // structural changed. It may still resolve by signature, but only
        // when the answer is unambiguous — two near-tied candidates after a
        // name miss is exactly the silent mis-bind this whole design exists
        // to prevent. Legacy refs (no name) keep today's behavior untouched.
        if ref.elementName != nil, let margin, margin < Self.nameMissMargin {
            return nil
        }
        // Surface the matched entry's name (rows align with enumerate,
        // verified by triangles) — the raw material of the 5b upgrade.
        var matchedName: ElementName?
        if let table, best.index < table.entries.count,
           table.entries[best.index].triangles == best.face.triangles {
            matchedName = table.entries[best.index].elementName
        }
        return ResolvedFace(
            planar: best.face.planar,
            cylinder: best.face.cylinder,
            confidence: min(1, best.score),
            elementName: matchedName,
            margin: margin
        )
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
        case .revolve, .generic:
            return derivedRoles(faces)
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
        let fallback = derivedRoles(faces)
        return roles.indices.map { roles[$0] ?? fallback[$0] }
    }

    private func derivedRoles(_ faces: [EnumeratedFace]) -> [FaceRole] {
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
