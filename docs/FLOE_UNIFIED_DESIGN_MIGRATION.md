<!-- docs-updated: 2026-10-11 -->
# Unified 3D and shared design workflow — migration and recovery

Status: this page documents the **next** update from its source candidate (2026-10-11). It is not released, not installed and not qualified yet — the build you have may not contain these features. Do not rely on this page alone before migrating the only copy of important work; installation state is tracked in [CURRENT_STATUS.md](CURRENT_STATUS.md).

Related: [User manual](USER_GUIDE.md) · [Floe 1.7 migration and recovery](FLOE_1_7_MIGRATION.md) · [Design workflow](FLOE_DESIGN_WORKFLOW.md) · [Design workflow tool contract](DESIGN_WORKFLOW_TOOLS.md)

## 1. What changes

- 3D creation is unified. The two old top-of-canvas 3D creators are removed; the bottom insertion menu (**+ ▸ 3D Model (unified workbench)**) creates one native `.floecad` model node owned by the canvas and opens the same full-screen workbench used elsewhere. **3D Panorama** stays a separate viewer node.
- Existing legacy 3D scene nodes are **not** deleted or converted by the update. They keep a read-only preview until you explicitly open one for editing (first edit).
- Design workflow entrances (Creative start, current file, original chat attachment, Canvas node) share one workflow and one set of services. No new primary workspace, hidden canvas or parallel copy store is created.
- Native `.floecad` nodes and existing Canvas design subdocuments are unaffected: the new fields are additive, and old data decodes with them absent. The legacy `canvas.design*` Canvas tools remain compatible.

## 2. Before updating

1. Record the installed version and build (Settings → Diagnostics & About).
2. Export important documents and canvases and keep a copy outside the App.
3. Keep the current app data on the device until you have verified the update, especially if you still use legacy 3D scene nodes.

## 3. Converting a legacy 3D scene (first edit)

1. Open the canvas that contains the old 3D scene node. It still shows its read-only preview.
2. Double-click the node (or use its edit action): this explicit action is the first edit. Floe validates the whole scene first.
3. If conversion can proceed, Floe writes a recoverable backup on this device, creates one canvas-owned `.floecad` document and converts the scene, then shows the **3D scene migration** sheet with the known visual differences. Open the workbench from that sheet.
4. If conversion is refused, nothing is written: the sheet lists the exact unusable values and the node keeps its read-only preview.
5. After conversion, review the model, then **Apply to canvas** to update the original node or **Make variant** to branch a new node. Keep the app data until you have verified the result.

## 4. What conversion preserves / does not

Preserved: node id, name, position, size and connections; per-object position, rotation, scale, colour/roughness/metallic and hidden state; camera position/target/FOV; lights and background. The five legacy primitives (rounded box, sphere, cylinder, cone, thin plane slab) become real meshes in the workbench's millimetre units (legacy metres ×1000).

Not invented: no parametric feature tree and no modeling history is fabricated for a converted scene — the result is plain geometry, like the other primitives. Imported DWG/DXF drawings are different: their 2D entities stay editable, while 3D entities, blocks, xrefs, splines and proxy content remain read-only. A drawing is not a native 3D model, and not every 3D file can be edited.

Refused before any write (the original stays intact): non-finite values, zero/negative or out-of-range scale, invalid colour, camera or light values, and duplicate object ids.

## 5. Known visual differences

- Lighting: intensities are normalized to the workbench scale and bounded; the exact originals stay in the retained scene backup.
- Shadows: a planar ground projection approximates the legacy directional shadow map.
- Curved surfaces are tessellated meshes; the legacy rounded corners are real geometry with a bounded chord error.

The lighting and shadow disclosures are shown in the migration sheet and recorded with the converted document, so they can be checked again on reopen.

## 6. If something goes wrong

- Keep the original: do not delete app data, the canvas backup or the migration backup while diagnosing.
- Retry: a failed (retryable) conversion reuses the same reserved document; no partial node commit is made.
- Report with the installed version/build, the canvas and node name, the message shown and, if possible, a redacted screenshot.

## 7. Design workflow data

- Existing Canvas design projects stay Canvas subdocuments of their node — there is no migration step.
- The file, chat-attachment and creative entrances store the design envelope through the existing artifact authority. The original file/attachment is preserved; adoption updates in place only where Floe may write, otherwise the result is returned as new content (a new attachment in the original task for chat).
- Adoption requires your explicit confirmation in the panel, delivered to the originating task only (a target with no originating task offers the direct adopt). The confirmation is single-use: it is not retained across an app restart, and a claimed attempt that fails needs a fresh confirmation. If the source changed after freezing, the candidate is refused with a revision conflict; manual edits and late results are retained, never silently overwritten.
- First-result generation is offered only for capabilities that are actually connected (currently image generation when a model is configured). No promise is made for output kinds Floe cannot generate. An unknown generation outcome is not resubmitted automatically; discard the unknown attempt explicitly to start a new one. A result generated while the design changed is retained and can be bound to the current revision.

## 8. Verify after updating

1. Old 3D scene nodes still open as read-only previews until edited.
2. A test conversion (a copy, or a scene you can afford to convert) shows the migration sheet and opens the workbench.
3. Existing native `.floecad` nodes and canvases open. If you switch canvas documents while a conversion is running, its result surfaces only in the original document; the newly selected document is not changed.
4. File Preview → **Design workflow** opens on a live workspace file; the chat attachment menu appears on a message with a file/image part; confirmation is requested before any adoption.
5. Provider configuration is unchanged and saves; a pending iCloud sync can be retried without re-entering secrets.
