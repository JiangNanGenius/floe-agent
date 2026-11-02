//
//  ElementNaming.swift
//  openshape3d — kernel-history element names
//  (docs/TOPO_NAMING_HISTORY_DESIGN.md step 2)
//
//  A face's NAME, derived from persisted stable identities the app already
//  owns — the creating feature and the sketch entity a wall came from —
//  bound to actual kernel faces through `ShapeAncestry` (OCCT's own
//  history), never through geometric resemblance. Names layer UNDER
//  `SignatureNaming`: an unnamed face needs a unique exact fingerprint;
//  a WRONG name would be worse than none, so every derivation here
//  refuses to guess.
//

import Foundation

/// The identity of one face, stable across rebuilds because every component
/// is itself persisted and stable. Codable/Hashable value — no string
/// grammar, no hashing; the graphs are small.
nonisolated struct ElementName: Codable, Hashable, Sendable {

    nonisolated enum Source: Codable, Hashable, Sendable {
        /// A primitive's face — for primitives the role IS the identity
        /// (`boxFace(.top)`, `cylinderCap(top:)`, …).
        case primitiveFace(FaceRole)
        /// The author-owned boundary that generates a wall. New physical
        /// faces qualify this root through operationFace; old documents used
        /// it directly, including the unsafe first sibling of a sweep.
        /// `occurrence` separates boundaries owned by the same entity (a rect entity
        /// owns four), counted in wire order from the profile's own
        /// boundary arrays — deterministic per profile shape.
        case profileWall(entity: UUID, occurrence: Int)
        /// An extrude cap; `end` false = the start cap (zMin side).
        case profileCap(end: Bool)
        /// Fallback identity: the k-th face (1-based indexed-map order) of
        /// the creating op's result, when nothing finer exists.
        case kernelFace(index: Int)
        /// An index in a VERIFIED, immutable native-source blob. Unlike a
        /// generic result ordinal it cannot shuffle during a parameter edit:
        /// replacing the source changes its digest and breaks the reference.
        case immutableSourceFace(version: Int, sha256: String, index: Int)
        /// A mechanical hole's semantic wall/shoulder/cone/bottom. The role
        /// comes from the TOOL revolve's own history (the profile segment that
        /// generated the face) and is carried through the exact boolean; a
        /// creator + role is an author-owned feature identity, not a claim
        /// that the synthetic axial profile is a locating sketch entity.
        case holeFace(HoleFaceRole)
        /// A face an OPERATION minted: a section face cut into being, a
        /// face merged from several parents, or one of several fragments a
        /// split parent left behind (plain inheritance would collide there —
        /// the FreeCAD `;:M2` lesson, in value form). `parents` are the
        /// deduped ancestor names in deterministic ancestry order, empty
        /// when no ancestor carried a name; `index` separates siblings that
        /// share the same operation + parents, ordered by result face —
        /// deterministic per build, and the one component that can shuffle
        /// across topology-changing edits, which is why step 4's resolve
        /// must sanity-check name hits against signatures.
        indirect case opFace(operation: FeatureID, parents: [ElementName], index: Int)
        /// Versioned operation output identified by its actual named parents
        /// and, for split regions, a unique set of named neighboring faces.
        /// No result ordinal is part of this identity. Missing/ambiguous
        /// neighborhoods stay on the legacy unqualified path.
        indirect case operationFace(version: Int, operation: FeatureID,
                                    parents: [ElementName], neighbors: [ElementName])
    }

    var creator: FeatureID
    var source: Source

    /// Result ordinals are retained for old documents and current geometric
    /// selection, but they are not identities across a structural edit. An
    /// operation can renumber a surviving fragment after deleting a sibling.
    var requiresExactSignature: Bool {
        switch source {
        case let .immutableSourceFace(version, digest, index):
            return version != 1 || index <= 0 || digest.count != 64
                || digest.unicodeScalars.contains { !(48...57).contains($0.value) && !(97...102).contains($0.value) }
        case .opFace, .kernelFace, .primitiveFace(.derived): return true
        case .primitiveFace, .profileWall, .profileCap, .holeFace: return false
        case let .operationFace(version, operation, parents, neighbors):
            return version != 1 || operation != creator
                || parents.isEmpty
                || parents.contains(where: \.requiresExactSignature)
                || neighbors.contains(where: \.requiresExactSignature)
                || Set(parents).count != parents.count || Set(neighbors).count != neighbors.count
        }
    }

    var containsQualifiedOperationIdentity: Bool {
        switch source {
        case .operationFace, .immutableSourceFace: return true
        case let .opFace(_, parents, _): return parents.contains(where: \.containsQualifiedOperationIdentity)
        default: return false
        }
    }

    var hasSupportedOperationIdentity: Bool {
        switch source {
        case .immutableSourceFace: return !requiresExactSignature
        case let .operationFace(_, _, parents, neighbors):
            return !requiresExactSignature && parents.allSatisfy(\.hasSupportedOperationIdentity)
                && neighbors.allSatisfy(\.hasSupportedOperationIdentity)
        case let .opFace(_, parents, _): return parents.allSatisfy(\.hasSupportedOperationIdentity)
        default: return true
        }
    }
}

/// One crease between two uniquely named faces. A pair that meets at several
/// edges does NOT identify any one of them: an ordinal compacts when an
/// upstream operation removes a sibling. Keep the old ordinal readable, but
/// never mint it as a new identity or resolve it without geometric proof.
nonisolated struct EdgeName: Codable, Hashable, Sendable {
    var faceA: ElementName
    var faceB: ElementName
    var occurrence: Int
    /// Nil on pre-contract documents (synthesized decodeIfPresent). Version 1
    /// is minted only for a unique edge between two unique face identities.
    /// Unknown versions refuse resolution rather than being reinterpreted.
    var schemeVersion: Int? = 1

    func hasSameFaces(as other: Self) -> Bool {
        (faceA == other.faceA && faceB == other.faceB)
            || (faceA == other.faceB && faceB == other.faceA)
    }

    /// Order-insensitive over the pair: (A,B) names the same edge as (B,A).
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.schemeVersion == rhs.schemeVersion && lhs.occurrence == rhs.occurrence
            && lhs.hasSameFaces(as: rhs)
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(occurrence)
        hasher.combine(schemeVersion)
        // Commutative combine, so hashing agrees with the unordered ==.
        hasher.combine(faceA.hashValue ^ faceB.hashValue)
    }
}

/// Derivation + attachment. Pure functions over values — the FeatureGraph
/// wiring comes separately, so these are unit-testable without a document.
nonisolated enum ElementNaming {

    /// Current adjacency pairs whose two faces have unique identities. This
    /// does not yet claim that the PAIR identifies a unique edge.
    static func edgeFacePairs(adjacency: [(edge: Int, faceA: Int, faceB: Int)],
                              names: [Int: ElementName]) -> [Int: EdgeName] {
        let faceCounts = Dictionary(grouping: names.values, by: { $0 }).mapValues(\.count)
        var pairs: [Int: EdgeName] = [:]
        for triple in adjacency {
            guard let a = names[triple.faceA], let b = names[triple.faceB],
                  a != b, faceCounts[a] == 1, faceCounts[b] == 1 else { continue }
            pairs[triple.edge] = EdgeName(faceA: a, faceB: b, occurrence: 0)
        }
        return pairs
    }

    /// Mint only unique face-pair identities. Multiple creases between the
    /// same faces remain unnamed and require exact fingerprints on replay.
    static func edgeNames(adjacency: [(edge: Int, faceA: Int, faceB: Int)],
                          names: [Int: ElementName]) -> [Int: EdgeName] {
        let pairs = edgeFacePairs(adjacency: adjacency, names: names)
        let counts = Dictionary(grouping: pairs.values, by: { $0 }).mapValues(\.count)
        return pairs.filter {
            counts[$0.value] == 1
                && !$0.value.faceA.requiresExactSignature
                && !$0.value.faceB.requiresExactSignature
        }
    }

    /// The edge index carrying `name` on a shape — the resolve-side
    /// inverse of `edgeNames`. Nil when the named crease no longer exists.
    static func edgeIndex(named name: EdgeName,
                          adjacency: [(edge: Int, faceA: Int, faceB: Int)],
                          names: [Int: ElementName]) -> Int? {
        guard name.schemeVersion == 1, name.occurrence == 0 else { return nil }
        return edgeNames(adjacency: adjacency, names: names)
            .first { $0.value == name }?.key
    }

    /// Per-OCCT-face names for an extrude result: caps from the profile-face
    /// rows, walls from the generated-edge rows resolved through the
    /// profile's boundary identity. Keys are 1-based result face indices
    /// (the numbering `ShapeAncestry`, the face channel and the health
    /// report share). A face claimed by two DIFFERENT names is dropped —
    /// ambiguity never ships.
    static func extrudeNames(creator: FeatureID, ancestry: ShapeAncestry,
                             outer: Profile, holes: [Profile]) -> [Int: ElementName] {
        // Wall-edge counts per loop pick which boundary description built
        // the wire (conic / exact segments / polyline) — see
        // `Profile.boundaryIdentity`. DISTINCT edges, not rows: a sweep
        // generates one face per spine segment from the same edge. A
        // phantom-dropped edge makes the count match nothing and the loop's
        // walls stay honestly unnamed.
        var wallEdges: [Int: Set<Int>] = [:]
        for row in ancestry.rows where row.inputKind == .edge
            && row.relation == .generated {
            wallEdges[row.inputOrdinal, default: []].insert(row.inputSubshape)
        }
        let wallCount = wallEdges.mapValues(\.count)

        var names: [Int: ElementName] = [:]
        var ambiguous: Set<Int> = []
        func claim(_ face: Int, _ name: ElementName) {
            if let existing = names[face], existing != name {
                ambiguous.insert(face)
                return
            }
            names[face] = name
        }

        // A boundary may generate several physical walls. No sibling owns
        // the boundary root merely because it has the lowest native index.
        // Deduplicate history rows first; repeated ancestry is not a split.
        var wallFaces: [ElementName: Set<Int>] = [:]

        for row in ancestry.rows.sorted(by: {
            ($0.inputOrdinal, $0.inputSubshape, $0.resultFace)
                < ($1.inputOrdinal, $1.inputSubshape, $1.resultFace)
        }) {
            if row.inputKind == .face, row.inputOrdinal == 0 {
                claim(row.resultFace, ElementName(
                    creator: creator,
                    source: .profileCap(end: row.inputSubshape == 2)))
            } else if row.inputKind == .edge, row.relation == .generated {
                let profile: Profile? = row.inputOrdinal == 0
                    ? outer
                    : (row.inputOrdinal - 1 < holes.count
                        ? holes[row.inputOrdinal - 1] : nil)
                guard let profile,
                      let count = wallCount[row.inputOrdinal],
                      let identity = profile.boundaryIdentity(
                          wireEdge: row.inputSubshape, wireEdgeCount: count)
                else { continue }
                let wall = ElementName(
                    creator: creator,
                    source: .profileWall(entity: identity.entity,
                                         occurrence: identity.occurrence))
                wallFaces[wall, default: []].insert(row.resultFace)
            }
        }
        for (wall, faces) in wallFaces {
            for (index, face) in faces.sorted().enumerated() {
                let source: ElementName.Source = faces.count == 1
                    ? .operationFace(version: 1, operation: creator, parents: [wall], neighbors: [])
                    : .opFace(operation: creator, parents: [wall], index: index)
                claim(face, ElementName(creator: creator, source: source))
            }
        }
        for face in ambiguous { names.removeValue(forKey: face) }
        return names
    }

    /// Tool-side identities for a mechanical hole. The revolved axial profile
    /// is synthetic, so it has no sketch entity ids; its authority instead
    /// comes from OCCT's OWN generated-edge history — profile segment `i`
    /// generated the face, and `roles[i-1]` names that segment's semantic
    /// role. A face claimed by two different roles is dropped, never guessed.
    static func holeToolNames(creator: FeatureID, ancestry: ShapeAncestry,
                              roles: [HoleFaceRole?]) -> [Int: ElementName] {
        var names: [Int: ElementName] = [:]
        var ambiguous: Set<Int> = []
        for row in ancestry.rows
        where row.inputKind == .edge && row.inputOrdinal == 0 && row.relation == .generated {
            guard row.inputSubshape >= 1, row.inputSubshape <= roles.count,
                  let role = roles[row.inputSubshape - 1] else { continue }
            let name = ElementName(creator: creator, source: .holeFace(role))
            if let existing = names[row.resultFace], existing != name {
                ambiguous.insert(row.resultFace)
                continue
            }
            names[row.resultFace] = name
        }
        for face in ambiguous { names.removeValue(forKey: face) }
        return names
    }

    /// Result-side names for a hole boolean. Target survivors/splits keep the
    /// composed target identity; a cavity face becomes
    /// `creator=hole, source=holeFace(role)` ONLY when the boolean's actual
    /// history attributes it to exactly one named tool face and no named
    /// target parent. Seam-split duplicates of one role are left unnamed —
    /// a name resolving to two faces would be worse than none.
    static func holeNames(operation: FeatureID, ancestry: ShapeAncestry,
                          targetNames: [Int: ElementName],
                          toolNames: [Int: ElementName]) -> [Int: ElementName] {
        var names = composeNames(operation: operation, ancestry: ancestry,
                                  inputNames: [targetNames])
        var byRole: [HoleFaceRole: [Int]] = [:]
        for face in Set(ancestry.rows.map(\.resultFace)) {
            var roles: [HoleFaceRole] = []
            var hasNamedTargetParent = false
            for row in ancestry.ancestors(ofResultFace: face) {
                if row.inputOrdinal == 1, row.inputKind == .face,
                   let name = toolNames[row.inputSubshape],
                   case let .holeFace(role) = name.source,
                   !roles.contains(role) {
                    roles.append(role)
                }
                if row.inputOrdinal == 0, row.inputKind == .face,
                   targetNames[row.inputSubshape] != nil {
                    hasNamedTargetParent = true
                }
            }
            if roles.count == 1, !hasNamedTargetParent {
                byRole[roles[0], default: []].append(face)
            }
        }
        for (role, faces) in byRole where faces.count == 1 {
            names[faces[0]] = ElementName(creator: operation, source: .holeFace(role))
        }
        return names
    }

    /// Attach per-OCCT-face names to a face table by majority vote over the
    /// per-triangle face channel. Only meaningful when the table was built
    /// over the ADOPTED OCCT tessellation — the channel then aligns
    /// triangle-for-triangle with `body.render`. An entry needs a strict
    /// majority of its triangles on one kernel face to claim its name;
    /// anything less stays unnamed.
    static func attach(_ names: [Int: ElementName], to table: FaceTable,
                       channel: [UInt32], body: Body? = nil) -> FaceTable {
        guard !names.isEmpty, !channel.isEmpty else { return table }
        var out = table
        out.nativeFaceNames = nil
        out.nativeFaceChannel = nil
        out.nativeBodyID = nil
        out.nativeMeshRevision = nil
        if let body, body.brep != nil, channel.count == body.render.triangleCount {
            out.nativeFaceNames = names
            out.nativeFaceChannel = channel
            out.nativeBodyID = body.id
            out.nativeMeshRevision = body.meshRevision
        }
        for i in out.entries.indices {
            var votes: [UInt32: Int] = [:]
            for triangle in out.entries[i].triangles where triangle < channel.count {
                votes[channel[triangle], default: 0] += 1
            }
            guard let winner = votes.max(by: { $0.value < $1.value }),
                  winner.key != 0,
                  winner.value * 2 > out.entries[i].triangles.count
            else { continue }
            out.entries[i].elementName = names[Int(winner.key)]
        }
        return out
    }

    /// Compose names THROUGH a boolean: each result face's name derived
    /// from its ancestors' names (docs/TOPO_NAMING_HISTORY_DESIGN.md
    /// step 3). `inputNames` is indexed by ancestry input ordinal (0 =
    /// target, 1 = tool), each a per-kernel-face name map of that operand.
    ///
    /// Rules, in order:
    /// - exactly one named parent, nothing generated, and NO OTHER result
    ///   face inherits the same name → the identity CONTINUES: inherit the
    ///   parent's name unchanged. This is the common case — an untouched or
    ///   trimmed face is still "the top cap of extrude N".
    /// - a split parent (two result faces from one name) → each fragment
    ///   gets `opFace(operation, parents: [name], index: k)` — inheritance
    ///   would collide, and a duplicated name is worse than a new one.
    /// - generated rows or several named parents (section faces, merged
    ///   walls) → `opFace` with all parents.
    /// - no named parents and nothing generated → unnamed; signatures
    ///   remain the fallback, per the design's migration story.
    /// `edgeParents` extends the composition to single-input MODIFIER ops
    /// (step 5): a face GENERATED from input edge `i` (a fillet face from
    /// its crease) claims `edgeParents[i]` — the crease's two adjacent-face
    /// names — as its parents, so "the fillet of the cap/wall crease" is an
    /// identity, not an accident of geometry. Booleans pass nothing here.
    static func composeNames(operation: FeatureID, ancestry: ShapeAncestry,
                             inputNames: [[Int: ElementName]],
                             edgeParents: [Int: [ElementName]] = [:],
                             adjacency: [(edge: Int, faceA: Int, faceB: Int)] = []) -> [Int: ElementName] {
        struct Claim {
            var parents: [ElementName] = []
            var hasGenerated = false
        }
        var claims: [Int: Claim] = [:]
        for row in ancestry.rows {
            if row.inputKind == .face {
                var claim = claims[row.resultFace] ?? Claim()
                if row.relation == .generated { claim.hasGenerated = true }
                if row.inputOrdinal < inputNames.count,
                   let parent = inputNames[row.inputOrdinal][row.inputSubshape],
                   !claim.parents.contains(parent) {
                    claim.parents.append(parent)
                }
                claims[row.resultFace] = claim
            } else if row.inputKind == .edge, row.relation == .generated,
                      let parents = edgeParents[row.inputSubshape] {
                var claim = claims[row.resultFace] ?? Claim()
                claim.hasGenerated = true
                for parent in parents where !claim.parents.contains(parent) {
                    claim.parents.append(parent)
                }
                claims[row.resultFace] = claim
            }
        }

        // Who would inherit what, before knowing about collisions.
        var heirs: [ElementName: [Int]] = [:]
        for (face, claim) in claims
        where !claim.hasGenerated && claim.parents.count == 1 {
            heirs[claim.parents[0], default: []].append(face)
        }

        var names: [Int: ElementName] = [:]
        var mintedFaces: Set<Int> = []
        var mintIndex: [ElementName: Int] = [:]
        func mint(_ face: Int, parents: [ElementName]) {
            mintedFaces.insert(face)
            // Sibling index per (operation, parents) key, in result-face
            // order — callers iterate faces ascending below.
            let key = ElementName(creator: operation,
                                  source: .opFace(operation: operation,
                                                  parents: parents, index: -1))
            let index = mintIndex[key, default: 0]
            mintIndex[key] = index + 1
            names[face] = ElementName(
                creator: operation,
                source: .opFace(operation: operation, parents: parents,
                                index: index))
        }
        for face in claims.keys.sorted() {
            guard let claim = claims[face] else { continue }
            if !claim.hasGenerated, claim.parents.count == 1,
               let siblings = heirs[claim.parents[0]] {
                if siblings.count == 1 {
                    names[face] = claim.parents[0]
                } else {
                    mint(face, parents: claim.parents)
                }
            } else if claim.hasGenerated || claim.parents.count >= 2 {
                mint(face, parents: claim.parents)
            }
            // else: modified with no named parent — honestly unnamed.
        }

        // Qualify operation outputs separately from old ordinals. First the
        // single-output families, then synchronous rounds using only already
        // qualified neighbors. A round never reads its own new names, so face
        // iteration order cannot change the persisted identity or form cycles.
        func ordered(_ values: [ElementName]) -> [ElementName]? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let keyed = try? Array(Set(values)).map({ ($0, try encoder.encode($0)) }) else { return nil }
            return keyed.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map(\.0)
        }
        var families: [ElementName: [Int]] = [:]
        for face in mintedFaces {
            guard let name = names[face], case let .opFace(_, parents, _) = name.source,
                  !parents.isEmpty,
                  !parents.contains(where: \.requiresExactSignature),
                  let canonical = ordered(parents) else { continue }
            let key = ElementName(creator: operation,
                source: .operationFace(version: 1, operation: operation, parents: canonical, neighbors: []))
            families[key, default: []].append(face)
        }
        let inherited = Set(names.values.filter { !$0.requiresExactSignature })
        for (key, faces) in families where faces.count == 1 && !inherited.contains(key) {
            names[faces[0]] = key
        }
        var neighboringFaces: [Int: Set<Int>] = [:]
        for edge in adjacency where edge.faceA != edge.faceB {
            neighboringFaces[edge.faceA, default: []].insert(edge.faceB)
            neighboringFaces[edge.faceB, default: []].insert(edge.faceA)
        }
        while true {
            let prior = names
            let occupied = Set(prior.values.filter { !$0.requiresExactSignature })
            var proposals: [Int: ElementName] = [:]
            for (family, faces) in families where faces.count > 1 {
                guard case let .operationFace(_, _, parents, _) = family.source else { continue }
                var keys: [ElementName: [Int]] = [:]
                for face in faces {
                    guard let name = prior[face], name.requiresExactSignature else { continue }
                    let known = (neighboringFaces[face] ?? []).compactMap { prior[$0] }
                        .filter { !$0.requiresExactSignature }
                    guard !known.isEmpty, let context = ordered(known) else { continue }
                    let key = ElementName(creator: operation, source: .operationFace(
                        version: 1, operation: operation, parents: parents, neighbors: context))
                    keys[key, default: []].append(face)
                }
                for (key, candidates) in keys where candidates.count == 1 && !occupied.contains(key) {
                    proposals[candidates[0]] = key
                }
            }
            guard !proposals.isEmpty else { break }
            for (face, name) in proposals { names[face] = name }
        }
        return names
    }

    /// Per-kernel-face names recovered from a NAMED table via the channel —
    /// the inverse of `attach`, for bodies whose names were minted
    /// table-side (primitives). Same strict-majority rule; a kernel face
    /// claimed by two entries with different names is dropped.
    static func kernelNames(from table: FaceTable,
                            channel: [UInt32]) -> [Int: ElementName] {
        guard !channel.isEmpty else { return [:] }
        if table.nativeFaceChannel == channel, let names = table.nativeFaceNames { return names }
        var out: [Int: ElementName] = [:]
        var conflicted: Set<Int> = []
        for entry in table.entries {
            guard let name = entry.elementName,
                  let face = kernelFace(of: entry, channel: channel) else { continue }
            if let existing = out[face], existing != name {
                conflicted.insert(face)
                continue
            }
            out[face] = name
        }
        for face in conflicted { out.removeValue(forKey: face) }
        return out
    }

    /// The kernel face a table entry describes, by strict majority over its
    /// triangles' channel labels — nil when the entry straddles faces or the
    /// channel doesn't cover it (a stale or non-adopted render).
    static func kernelFace(of entry: FaceTable.Entry,
                           channel: [UInt32]) -> Int? {
        var votes: [UInt32: Int] = [:]
        for triangle in entry.triangles where triangle < channel.count {
            votes[channel[triangle], default: 0] += 1
        }
        guard let winner = votes.max(by: { $0.value < $1.value }),
              winner.key != 0,
              winner.value * 2 > entry.triangles.count else { return nil }
        return Int(winner.key)
    }

    /// Step 5b: the upgraded copy of a legacy ref, when this resolution
    /// EARNED it — the ref had no name, the matched face carries one, and
    /// the signature match was both confident and decisively unambiguous.
    /// The name comes from the exact entry the signature chose, so an
    /// upgrade can never re-bind; it only pins what already resolved.
    static func upgraded(_ ref: FaceRef, from resolved: ResolvedFace) -> FaceRef? {
        guard ref.elementName == nil,
              let name = resolved.elementName,
              !name.requiresExactSignature,
              resolved.confidence >= SignatureNaming.upgradeConfidence,
              (resolved.margin ?? .infinity) >= SignatureNaming.nameMissMargin
        else { return nil }
        var out = ref
        out.elementName = name
        return out
    }

    /// After successful evaluation, an unnamed or pre-contract reference may
    /// earn the current unique-pair name. The shared resolver first proves
    /// that its exact fingerprint and, when present, old face pair agree.
    static func upgraded(_ ref: EdgeRef, faceNames: EdgeName) -> EdgeRef? {
        guard ref.faceNames?.schemeVersion == nil,
              faceNames.schemeVersion == 1 else { return nil }
        var out = ref
        out.faceNames = faceNames
        return out
    }

    /// Names for a primitive's table entries: the role is the identity, so
    /// no kernel channel is needed — which also covers the box, whose render
    /// deliberately stays Euclid. `.derived` roles carry no identity and
    /// stay unnamed.
    static func namePrimitiveEntries(_ table: FaceTable,
                                     creator: FeatureID) -> FaceTable {
        var out = table
        for i in out.entries.indices {
            if case .derived = out.entries[i].role { continue }
            out.entries[i].elementName = ElementName(
                creator: creator,
                source: .primitiveFace(out.entries[i].role))
        }
        return out
    }
}
