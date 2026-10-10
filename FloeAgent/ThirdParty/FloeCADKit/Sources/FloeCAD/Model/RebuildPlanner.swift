//
//  RebuildPlanner.swift
//  openshape3d
//
//  The pure core of a feature-graph rebuild: replay the graph, diff the result
//  against the live document, and produce the commands that bring the document
//  up to date — docs/OFF_MAIN_EVAL_DESIGN.md, slice 0.
//
//  Extracted from `DocumentSession.performRebuild` unchanged in behaviour so
//  that (1) the diff semantics — skip-unchanged replace, add, delete-consumed,
//  metadata preservation, upgrade edits — are pure-value unit-testable
//  (`DocumentSession` never is: it needs SwiftData), and (2) the detached
//  evaluate of off-main eval has a seam: everything here is a function of
//  values; only `perform` and the revision counter belong to the session.
//
//  Isolation: the module's default isolation is MainActor and the command
//  structs (`AddBodyCommand`, …) are un-annotated, so today this planner runs
//  on the main actor too — slice 0 changes no behaviour. Slice 1 marks those
//  pure value-op commands `nonisolated` so the planner can run detached.
//

import Foundation

/// What a rebuild decided: the commands to perform (leading commands first),
/// plus the replay's diagnostics the session retains.
struct RebuildPlan {
    var commands: [DocumentCommand]
    var errors: [FeatureID: FeatureError]
    var faceTables: [BodyID: FaceTable]
    var kernelNames: [BodyID: [Int: ElementName]]
    /// Every body the replay produced — what the naming-revision capture
    /// stamps after apply.
    var resultBodyIDs: [BodyID]
}

enum RebuildPlanner {

    /// Replay `editedGraph` and diff against `document`'s bodies.
    ///
    /// - `previousGraph`: the document's graph BEFORE the pending edit, so a
    ///   node removed in `editedGraph` still has its orphaned body diffed
    ///   (and deleted).
    /// - `sketches`: normally `document.sketches`; `performWithSketchRebuild`
    ///   passes a preview that already contains its not-yet-performed edit.
    /// - `nextRevision`: mints each emitted body's `meshRevision`. The session
    ///   passes its document counter so revisions stay globally unique.
    /// - `cache`: the replay memo (docs/INCREMENTAL_EVAL_DESIGN.md), rewritten
    ///   to describe this replay.
    static func plan(
        editedGraph: FeatureGraph,
        previousGraph: FeatureGraph,
        document: DesignDocument,
        sketches: [Sketch],
        planes: [ConstructionPlane],
        naming: TopoNaming,
        cache: inout EvalCache,
        nextRevision: () -> UInt64,
        leadingCommands: [DocumentCommand],
        title: String
    ) -> RebuildPlan {
        // Memoised replay: nodes whose inputs are unchanged are spliced from
        // `cache` instead of re-run.
        let result = editedGraph.evaluate(
            sketches: sketches,
            planes: planes,
            naming: naming,
            nextRevision: nextRevision,
            cache: &cache
        )

        // Every BodyID any node owns — the pre-edit graph too, so a node removed
        // in `editedGraph` still has its now-orphaned body diffed (and deleted).
        let ownedIDs = Set(previousGraph.nodes.flatMap(\.outputBodyIDs))
            .union(editedGraph.nodes.flatMap(\.outputBodyIDs))

        var resultByID: [BodyID: Body] = [:]
        for body in result.bodies { resultByID[body.id] = body }

        var currentOwned: [BodyID: Body] = [:]
        for body in document.bodies where ownedIDs.contains(body.id) {
            currentOwned[body.id] = body
        }

        var commands: [DocumentCommand] = leadingCommands

        // Replace bodies that still exist; add ones the graph newly produced.
        // Preserve user-owned metadata the replay doesn't carry.
        //
        // NOTE: the transform is intentionally NOT preserved. `evaluate()` emits
        // world-space meshes with an identity transform; carrying the live body's
        // pivot transform (extrude/boolean/push-pull store a localized mesh +
        // pivot translation) would double-offset the body by its pivot on every
        // rebuild. So a rebuilt feature body adopts the replay's placement —
        // which, since 2026-09-02, INCLUDES every gizmo move: the transform
        // tools commit a feature-owned body's move as a `.transform` node
        // (`EditorViewModel.commitTransforms` → `recordAndRebuild`), so the
        // graph replays the placement and a later parameter edit keeps it.
        // Only bodies with no producing feature (imports) still carry a
        // document-level transform, and those are never replaced here.
        for body in result.bodies where ownedIDs.contains(body.id) {
            if let existing = currentOwned[body.id] {
                // Unchanged since the last apply: a spliced node's body carries
                // the document's own revision (adopted after apply), so there is
                // no replace — no re-mint, no GPU rebuild, no undo noise. A node
                // that actually ran minted a fresh revision and still replaces.
                if existing.meshRevision == body.meshRevision { continue }
                var after = body
                after.name = existing.name
                after.isHidden = existing.isHidden
                after.material = existing.material
                commands.append(ReplaceBodyCommand(title: title, before: existing, after: after))
            } else {
                commands.append(AddBodyCommand(body: body, title: title))
            }
        }

        // Feature-owned bodies the replay no longer produces were consumed
        // (e.g. a boolean tool) or belonged to a deleted node — remove them.
        let toDelete = Set(currentOwned.keys.filter { resultByID[$0] == nil })
        if !toDelete.isEmpty {
            commands.append(DeleteBodiesCommand(ids: toDelete, document: document))
        }

        // Step 5b: legacy refs that EARNED names during this replay are
        // upgraded HERE, inside the same undo step as the rebuild that
        // justified them — one undo reverts geometry and upgrades together,
        // and the load/undo error replay (refreshEvalErrors) never sees this
        // path, so it can never mutate. `before` is the edited graph's kind:
        // the leading edit command has already applied by the time these run.
        for (featureID, kind) in result.proposedUpgrades
            .sorted(by: { $0.key.raw.uuidString < $1.key.raw.uuidString }) {
            guard let node = editedGraph.node(featureID) else { continue }
            commands.append(EditFeatureCommand(
                featureID: featureID, before: node.kind, after: kind))
        }

        return RebuildPlan(
            commands: commands,
            errors: result.errors,
            faceTables: result.faceTables,
            kernelNames: result.kernelNames,
            resultBodyIDs: result.bodies.map(\.id))
    }
}
