//
//  ElementNaming.swift
//  openshape3d — kernel-history element names
//  (docs/TOPO_NAMING_HISTORY_DESIGN.md step 2)
//
//  A face's NAME, derived from persisted stable identities the app already
//  owns — the creating feature and the sketch entity a wall came from —
//  bound to actual kernel faces through `ShapeAncestry` (OCCT's own
//  history), never through geometric resemblance. Names layer UNDER
//  `SignatureNaming`: an unnamed face is normal and falls back to signature
//  scoring; a WRONG name would be worse than none, so every derivation here
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
        /// An extrude wall generated from one sketch entity. `occurrence`
        /// separates multiple walls owned by the same entity (a rect entity
        /// owns four), counted in wire order from the profile's own
        /// boundary arrays — deterministic per profile shape.
        case profileWall(entity: UUID, occurrence: Int)
        /// An extrude cap; `end` false = the start cap (zMin side).
        case profileCap(end: Bool)
        /// Fallback identity: the k-th face (1-based indexed-map order) of
        /// the creating op's result, when nothing finer exists.
        case kernelFace(index: Int)
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
    }

    var creator: FeatureID
    var source: Source
}

/// The identity of one EDGE: the unordered pair of its adjacent faces'
/// names plus an occurrence ordinal separating multiple edges that share
/// the same pair (a cap and a wall can meet more than once). "The crease
/// between the top cap and wall X" survives rebuilds exactly as long as
/// its two faces do — which is the whole idea (step 4b).
nonisolated struct EdgeName: Codable, Hashable, Sendable {
    var faceA: ElementName
    var faceB: ElementName
    var occurrence: Int

    /// Order-insensitive over the pair: (A,B) names the same edge as (B,A).
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.occurrence == rhs.occurrence else { return false }
        return (lhs.faceA == rhs.faceA && lhs.faceB == rhs.faceB)
            || (lhs.faceA == rhs.faceB && lhs.faceB == rhs.faceA)
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(occurrence)
        // Commutative combine, so hashing agrees with the unordered ==.
        hasher.combine(faceA.hashValue ^ faceB.hashValue)
    }
}

/// Derivation + attachment. Pure functions over values — the FeatureGraph
/// wiring comes separately, so these are unit-testable without a document.
nonisolated enum ElementNaming {

    /// Edge identities for a shape: for every adjacency triple whose BOTH
    /// faces carry names, the unordered pair plus its occurrence ordinal —
    /// the position among same-pair edges in ascending edge order, derived
    /// identically at mint and at resolve so the two always agree. Edges
    /// flanked by any unnamed face stay unaddressable, honestly.
    static func edgeNames(adjacency: [(edge: Int, faceA: Int, faceB: Int)],
                          names: [Int: ElementName]) -> [Int: EdgeName] {
        var seen: [EdgeName: Int] = [:]
        var out: [Int: EdgeName] = [:]
        for triple in adjacency.sorted(by: { $0.edge < $1.edge }) {
            guard let a = names[triple.faceA],
                  let b = names[triple.faceB] else { continue }
            let pair = EdgeName(faceA: a, faceB: b, occurrence: 0)
            let occurrence = seen[pair, default: 0]
            seen[pair] = occurrence + 1
            out[triple.edge] = EdgeName(faceA: a, faceB: b,
                                        occurrence: occurrence)
        }
        return out
    }

    /// The edge index carrying `name` on a shape — the resolve-side
    /// inverse of `edgeNames`. Nil when the named crease no longer exists.
    static func edgeIndex(named name: EdgeName,
                          adjacency: [(edge: Int, faceA: Int, faceB: Int)],
                          names: [Int: ElementName]) -> Int? {
        edgeNames(adjacency: adjacency, names: names)
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

        // One wire edge can generate SEVERAL result faces — a sweep makes
        // one wall per spine segment from the same profile edge. Stamping
        // them all with the wall name would duplicate it, so the FIRST face
        // (lowest result index — deterministic) inherits the wall identity
        // and its siblings mint as opFace children of it.
        var wallSiblings: [ElementName: Int] = [:]

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
                if let sibling = wallSiblings[wall] {
                    claim(row.resultFace, ElementName(
                        creator: creator,
                        source: .opFace(operation: creator, parents: [wall],
                                        index: sibling)))
                    wallSiblings[wall] = sibling + 1
                } else {
                    claim(row.resultFace, wall)
                    wallSiblings[wall] = 0
                }
            }
        }
        for face in ambiguous { names.removeValue(forKey: face) }
        return names
    }

    /// Attach per-OCCT-face names to a face table by majority vote over the
    /// per-triangle face channel. Only meaningful when the table was built
    /// over the ADOPTED OCCT tessellation — the channel then aligns
    /// triangle-for-triangle with `body.render`. An entry needs a strict
    /// majority of its triangles on one kernel face to claim its name;
    /// anything less stays unnamed.
    static func attach(_ names: [Int: ElementName], to table: FaceTable,
                       channel: [UInt32]) -> FaceTable {
        guard !names.isEmpty, !channel.isEmpty else { return table }
        var out = table
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
                             edgeParents: [Int: [ElementName]] = [:]) -> [Int: ElementName] {
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
        var mintIndex: [ElementName: Int] = [:]
        func mint(_ face: Int, parents: [ElementName]) {
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
        return names
    }

    /// Per-kernel-face names recovered from a NAMED table via the channel —
    /// the inverse of `attach`, for bodies whose names were minted
    /// table-side (primitives). Same strict-majority rule; a kernel face
    /// claimed by two entries with different names is dropped.
    static func kernelNames(from table: FaceTable,
                            channel: [UInt32]) -> [Int: ElementName] {
        guard !channel.isEmpty else { return [:] }
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
              resolved.confidence >= SignatureNaming.upgradeConfidence,
              (resolved.margin ?? .infinity) >= SignatureNaming.nameMissMargin
        else { return nil }
        var out = ref
        out.elementName = name
        return out
    }

    /// Step 5b for EDGES: a legacy `EdgeRef` (no `faceNames`) that resolved by
    /// signature earns the crease's adjacent-face name PAIR, so the next blend
    /// rebuild binds by identity and is immune to signature drift. `faceNames`
    /// comes from the kernel edge at the SAME midpoint the signature resolved,
    /// so this only PINS what already resolved — it can never re-bind. Nil when
    /// the ref already has a name (upgraded once, never again).
    static func upgraded(_ ref: EdgeRef, faceNames: EdgeName) -> EdgeRef? {
        guard ref.faceNames == nil else { return nil }
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
