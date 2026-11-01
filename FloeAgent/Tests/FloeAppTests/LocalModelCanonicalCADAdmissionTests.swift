// X34-R2 — one canonical CAD definition for every local provider.
//
// This file is a private integration test source. It is written against the
// production local prompt/admission planner and the real `cad.document`
// descriptor. It does not call a real model, download weights, mint approval
// authority or fake a tool result:
//
//   * the canonical definition is compared structurally, with descriptions
//     excluded, to the full pre-change reference schema;
//   * the built-in on-demand guide is paged through the real tool execute
//     path and must retain every old description and content identity;
//   * the production prompt admission must carry the SAME canonical bytes
//     whole at 8,192 / 12,288 / 16,384 representative local windows;
//   * an input that genuinely cannot fit must defer the whole definition and
//     keep the `tools.search` retrieval path;
//   * Foundation Models must receive the caller/task-authorized set and bridge
//     a non-Apple descriptor through the generic DynamicToolSchema/deferred
//     call path. Actual Foundation inference remains a separate gate.
//
// Root owns Swift 6 compilation, the App/test host, real MLX/Foundation runs
// and all native qualification. A source pass here is not an inference pass.

import Foundation
import XCTest
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeWorkbench
import FloeAgentRuntime
import FloeLocalModelCatalog
@testable import FloeLocalModels

#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class X34R2CanonicalCADAdmissionTests: XCTestCase {

    // The full authored pre-change schema and description. Descriptions are
    // intentionally free to move to the on-demand guide; every structural key
    // and constraint must survive.
    private static let referenceSchemaJSON = #"""
{
  "type": "object",
  "additionalProperties": false,
  "required": ["action"],
  "properties": {
    "action": { "type": "string", "enum": ["capabilities", "create", "read", "query", "locate", "measure", "check", "propose", "import", "reference", "preview", "apply", "save", "export", "status", "cancel", "material", "parameters", "capture", "observe", "animation", "scene", "versions", "three_d_snapshot", "three_d_measure", "three_d_propose", "three_d_apply", "three_d_assembly", "three_d_drawing"] },
    "path": { "type": "string", "description": "Document path relative to the task workspace (an allowed absolute workspace path is accepted too). Required for every action except capabilities without a path. observe reads an original mesh or CAD-surface file without converting it into a Floe document (GLB/glTF use the three.js scene path; STL/OBJ/PLY/OFF/3DS/DAE/FBX/3MF/AMF/WRL/BIM use the static viewer; STEP/IGES/BREP use the local display-triangulation conversion) and also observes an AUTHORISED native .floecad document through the same public bridge without importing or copying the native model; .dwg/.dxf route to the 2D engine. For 'create' it is the new package location inside the task workspace (a missing parent directory is created inside the guarded workspace; a path outside it is refused; the file need not exist); for 'import' it is the EXISTING .floecad package that receives the geometry. Never write a .floecad directory, manifest.json or zip yourself: use create." },
    "name": { "type": "string", "maxLength": 120, "description": "create: human-readable display name stored in the new native document. Letters and digits of ANY language (Chinese, Japanese, Cyrillic, ...), spaces and -_(). are accepted; it must not contain '/', '\\\\', control/invisible characters or a '..' path segment and must be at most 120 characters, otherwise the call is refused with a bilingual explanation. When omitted the display name defaults to the file stem. The FILE keeps the stem of 'path' and is uniquified, so the display name and the file name stay separate. import: optional name for the imported body(ies)." },
    "source_path": { "type": "string", "description": "import/reference: workspace-relative path resolved by the host through the task workspace guard. import supports .step/.stp, .iges/.igs, .stl/.obj/.glb/.gltf. reference requires an existing native .floecad package; the source is opened only by the App-owned bridge and is never granted by this string alone. DWG/DXF go through the 2D engine instead." },
    "reference_action": { "type": "string", "enum": ["attach", "check", "update", "inspect"], "description": "reference only: attach stages a new external native part and creates its first shared occurrence; check diagnoses source/version/hash state without mutation; update explicitly re-stages the SAME source body with source/staged hash CAS; inspect lists the source document's bodies so a multi-body source can be chosen with source_body_id." },
    "reference_id": { "type": "string", "format": "uuid", "description": "reference check/update: durable reference id from an attach reply or assembly references query." },
    "expected_source_sha256": { "type": "string", "description": "reference update CAS: the currently pinned source content SHA-256 (from references query)." },
    "expected_staged_sha256": { "type": "string", "description": "reference update CAS: the currently pinned staged geometry SHA-256." },
    "source_body_id": { "type": "string", "format": "uuid", "description": "reference attach: stable source body UUID for a multi-body source; inspect returns the body ids. Omitted only when the source has exactly one body." },
    "format": { "type": "string", "enum": ["step", "stp", "iges", "igs", "stl", "obj", "obj_bundle", "3mf", "glb", "gltf", "usdz", "pdf", "svg", "dxf", "csv"], "description": "import or native export: explicit format. Import (step/stp, iges/igs, stl, obj, glb, gltf) defaults to the source_path extension; a JSON .gltf imports only when its buffers/images are embedded data URIs, external .bin/texture references are reported unsupported, and a self-contained .glb always works. Native export accepts step/stp, iges/igs, stl, obj, obj_bundle, 3mf, glb, usdz, pdf, svg, dxf and csv; gltf is import-only (export writes glb), and 3mf/usdz plus pdf/svg/dxf/csv are export-only in this adapter. STEP writes closed exact solids; IGES writes exact closed solids AND open surfaces (surface bodies are never flattened to a mesh). obj_bundle writes one .zip containing model.obj, model.mtl and relative texture resources; plain obj remains a single .obj with UVs and no materials. pdf/svg/dxf/csv are drawing-page exports and require page_id; usdz is available where the platform USDZ writer is supported (otherwise usdz_unavailable). The output suffix must match the selected format: step/stp -> .step/.stp, iges/igs -> .iges/.igs, obj_bundle -> .zip, every other export -> .<format> (for example .3mf, .glb, .usdz, .pdf, .svg, .dxf, .csv); a mismatched suffix is refused rather than silently renamed." },
    "unit_scale": { "type": "number", "exclusiveMinimum": 0, "description": "import only: optional millimetres-per-file-unit scale for unitless meshes (STL/OBJ). Ignored for STEP/IGES and declared-unit glTF." },
    "summary": { "type": "string", "maxLength": 2000, "description": "Concise summary of the proposed document change (propose/import)." },
    "operations": {
      "type": "array", "maxItems": 64,
      "description": "Typed 2D engine edits (propose on a DWG/DXF drawing). Each object needs operation. Exact shapes: addLine{start:[x,y,z],end:[x,y,z],layer}; addCircle{center:[x,y,z],radius,layer}; addArc{center:[x,y,z],radius,startAngle,endAngle,layer}; addLwPolyline{points:[[x,y],...],closed?,layer} (2 numbers per point; rectangle = closed 4-point); addText{position:[x,y,z],text,height,layer}; addLeader{points:[[x,y,z],...],layer}; addDimension{kind:linear|aligned|angular|radius|diameter,points:[[x,y,z],...],layer,offset?,rotation?}; move|copy{handle,delta:[dx,dy,dz]}; rotate{handle,center:[x,y,z],angle}; scale{handle,center:[x,y,z],factor}; mirror{handle,axis:[[x,y,z],[x,y,z]]}; setText{handle,text}; setRadius{handle,radius}; setLayer{handle,layer}; setColor{handle,color}; setLineWeight{handle,lineWeight}; delete{handle}; trim|extend{handle,boundary,pick:[x,y,z]}; offset{handle,distance,side:[x,y,z]}; addLayer{name,color?,lineType?,lineWeight?}; updateLayer{name,locked?,visible?,color?,lineType?,lineWeight?}; renameLayer{from,to}; deleteLayer{name}; batch{operations:[...]} nests the same canonical shapes. Canonical vectors are arrays [x,y] (omitted z = the 2D drawing plane) or [x,y,0]; a nonzero z is rejected, never projected. The validated aliases {x,y[,z]} and {dx,dy[,dz]} are accepted and normalized to those arrays; addLwPolyline vertices are [x,y] or [x,y,0].",
      "items": { "type": "object", "required": ["operation"], "properties": { "operation": { "type": "string" } } }
    },
    "proposal_id": { "type": "string", "format": "uuid", "description": "Proposal id from propose (preview/apply). Send it exactly as the propose reply printed it." },
    "grant_id": { "type": "string", "description": "apply: OPTIONAL. When present, selects the human-reviewed CAD UI confirmation path (opaque single-use token the user's acceptance issued; the model cannot mint it). Omit it to let the runtime-approved call authority for this exact apply authorize the change automatically; a made-up or model-supplied value never authorizes anything." },
    "revision": { "type": "integer", "minimum": 0, "description": "apply/capture/observe/material/parameters/animation: optional base revision pin. For apply it is bound into the approved call; for capture/observe/material/parameters/animation the host refuses with revision_mismatch before any mutation/capture when the live document is at a different revision. For observe it is the same native generation pin as payload.expectedRevision (disagreeing values are refused) and it is refused for an original model." },
    "request_id": { "type": "string", "description": "Optional caller idempotency key; defaults to the tool call id." },
    "task_id": { "type": "string", "description": "Durable native task id (status reports one task; cancel requires it)." },
    "kind": { "type": "string", "description": "query/measure scope. 2D query: entities|text|layers|drawing|snap; 2D measure: distance|angle|radius|perimeter|area. Native .floecad query: bodies|sketches|constraints|features|edges|faces|planes|variables|materials|assembly|drawings|scene|detail|snapshot|selection|animation. selection returns the current live workbench bodies/faces/edges/sketch/instances with document revision and change_count; query it for deictic edits such as this face, then resolve exact face/edge query tokens before modifying. Features carry typed parameters/units/dependencies/actions; sketches carry entityRows with stable entity ids and each circle's current radius/diameter (the addressable source of an existing hole); faces/edges carry stable-matching indices, signatures and query_token/generation (revision, change_count, mesh_revision) required for index-based edits, and face rows identify planar/cylindrical kind with the actual radiusMM for a cylinder. Native measure: body|distance|bounds|dof|interference|mesh|rebuild (op may name the same kind). capabilities: pass drawing|assembly|script|mesh to get that service's exact operations with arguments and examples." },
    "scope": { "type": "string", "enum": ["part", "assembly"], "description": "export: part = selected/all document bodies (historical default); assembly = saved placed occurrences, including nested subassemblies and visible instances of hidden definitions. Hidden instances are excluded. Assembly export supports step, glb and usdz; IGES is part-scope only." },
    "points": { "type": "array", "items": { "type": "array", "items": { "type": "number" } }, "description": "measure points: 2D distance exactly 2, angle exactly 3, area 3+; snap point (first row). Native distance exactly 2 [x,y,z] rows." },
    "handles": { "type": "array", "items": { "type": "string" }, "description": "2D entity handles: distance exactly 2, angle 2 lines, radius 1 circle/arc, perimeter 1+. Native: one handle per action, body:<uuid> / face:<uuid>:<index> / edge:<uuid>:<index>; body, mesh and bounds accept body:<uuid> (a bare body UUID is also accepted); bounds takes one or more body handles." },
    "tolerance": { "type": "number", "description": "snap/check tolerance in drawing units; native interference tolerance in mm." },
    "layer": { "type": "string", "description": "2D query filter." },
    "entity_type": { "type": "string", "description": "2D query filter: Line|Circle|Arc|LwPolyline|Text." },
    "text": { "type": "string", "description": "2D query filter: text content contains." },
    "offset": { "type": "integer", "minimum": 0, "description": "query pagination offset." },
    "limit": { "type": "integer", "minimum": 1, "maximum": 500, "description": "query pagination size." },
    "output": { "type": "string", "description": "export relative path. 2D defaults to <name>.export.dxf. Native defaults to <name>.export.step; accepted native formats: step/stp, iges/igs, stl, obj, obj_bundle, 3mf, glb, usdz, pdf, svg, dxf, csv; the path must stay inside the workspace and its suffix must match the format. obj_bundle writes a .zip (model.obj + model.mtl + relative textures) and requires a .zip output path; plain obj writes a single .obj with UVs and no materials. A pdf/svg/dxf export is a DRAWING-page export and also needs page_id (from query kind=drawings). A csv export writes the COMPLETE BOM table for that drawing page (all rows and columns, UTF-8 RFC 4180) and also needs page_id and a .csv output path. usdz export is platform-guarded and reports usdz_unavailable where the writer is unavailable. With scope=assembly use .step, .glb or .usdz (part-scope iges and obj_bundle are also available): placed occurrences are resolved from the saved assembly, not flattened document bodies." },
    "page_id": { "type": "string", "format": "uuid", "description": "export: the native drawing page id for pdf/svg/dxf drawing exports and the complete BOM CSV table export, exactly as query with kind=drawings returned it." },
    "body_ids": { "type": "array", "maxItems": 512, "items": { "type": "string", "format": "uuid" }, "description": "export scope=part: exact document body ids. Omit/empty to export every body (historical default)." },
    "instance_ids": { "type": "array", "maxItems": 512, "items": { "type": "string", "format": "uuid" }, "description": "export scope=assembly: exact placed occurrence ids from query kind=assembly/report. Omit/empty for every visible placed part. A subassembly id includes its visible descendant parts." },
    "accept_partial": { "type": "boolean", "description": "export: explicit acknowledgement that the coverage receipt is incomplete (for example STEP with mesh-only objects or open surfaces, or IGES with mesh-only objects). Without it an incomplete plan returns coverage_incomplete and writes nothing." },
    "dry_run": { "type": "boolean", "description": "export: return the coverage receipt only (counts, included/excluded occurrence ids and reasons); no file is written. Requires an explicit scope." },
    "op": { "type": "string", "description": "Native typed operation name at the TOP LEVEL beside action and path, never inside args. Native propose requires it; native measure may use it to name the measurement kind. Exact executable vocabulary (also reported by capabilities as operation_names): sketch.create, sketch.addEntities, sketch.addText, feature.extrude, feature.revolve, feature.hole, feature.pattern, feature.mirror, feature.transform, feature.boolean, feature.fillet, feature.chamfer, feature.shell, feature.sweep, feature.loft, feature.pushPull, feature.moveFace, feature.deleteFace, feature.replaceFace, feature.draftFace, body.setMaterial, item.setHidden. feature.scaleFace, feature.rotateFace are NOT executable in this build: the kernel returns exact_edit_unsupported without mutation and reports them under capabilities.unavailable_operations; use feature.transform for a whole-body transform instead. feature.pushPull supports mode=planarAxial only (mode=cylinderRadial refuses with exact_edit_unsupported); feature.moveFace supports normal-axis (dn) movement only (tangential du/dv refuses)." },
    "args": { "type": "string", "description": "JSON object STRING containing ONLY the typed operation's arguments, not an {op,args} envelope. Send op separately at the top level. Required for native propose (and the three_d_measure/three_d_propose aliases). Units are mm and degrees. RUNNABLE CONTRACT (exact argument names): sketch.create {name?, origin?[x,y,z], xAxis?[x,y,z], yAxis?[x,y,z]} defaults to the ground plane and returns sketchID; sketch.addEntities {sketchID, entities:[{kind:\"line\",a:[x,y],b:[x,y]} | {kind:\"circle\",center:[x,y],radius} | {kind:\"arc\",center:[x,y],radius,startAngle,endAngle} | {kind:\"spline\",points:[[x,y],...],closed?} | {kind:\"rect\",min:[x,y],max:[x,y]} | {kind:\"polygon\",center:[x,y],radius,sides,rotation?} | {kind:\"ellipse\",center:[x,y],radiusX,radiusY,rotation?}], construction?:[indexes]}; sketch.addText {sketchID, text, height (cap height, mm), fontName? (installed family or PostScript name; default Helvetica), origin?[x,y] (baseline start in sketch-plane mm; default [0,0])} creates closed line loops for the glyphs as ordinary sketch entities (counter loops are holes) in ONE undo step; the reply reports entityCount, glyphCount, outlineLoopCount, boundsMM, advanceWidthMM, heightMM, resolvedFontNames, fallbackFontNames, units:\"mm\" and undoSteps. This is the native text-sketch route; this service has no standalone mesh.text operation. A missing font or a visible character without a real vector outline refuses with unsupported_font / unsupported_glyphs and adds nothing; entity ids stay available through query kind=sketches. Example: {\"sketchID\":\"<uuid from sketch.create>\",\"text\":\"O\",\"height\":20,\"origin\":[10,5]}. feature.extrude {sketchID, seedPoint:[x,y] (a point INSIDE the closed profile), distance (mm, non-zero; optional only with end), symmetric?, taperDegrees? (|t|<89, 0 = straight), end?:\"throughAll\"|\"upToNext\"|\"blind\", boolean?:\"newBody\"|\"union\"|\"subtract\"|\"intersect\", booleanTargets?:[bodyID]}. Example: {\"sketchID\":\"<uuid from sketch.create>\",\"seedPoint\":[40,20],\"distance\":10}. feature.hole {sketchID, seedPoint:[x,y] inside the SINGLE locating circle, targetBodyID, type:\"throughAll\"|\"blind\"|\"counterbore\"|\"countersink\", depth? (blind, mm, flat bottom), counterboreDiameter?/counterboreDepth? (counterbore, mm; diameter > pilot), countersinkDiameter?/countersinkAngle? (countersink, mm; included angle 30…170 degrees; diameter > pilot), reversed? (drills along -plane.normal; a face sketch plane normal is the source face outward normal)}; the placement circle owns position and pilot diameter (bind its diameter formula with setSketchDimension or edit it with updateSketchEntity, never the hole), through/counterbore/countersink pilots are through-all, and the target must be an analytic B-rep body. Ops that act on an existing body take {bodyID} plus their own fields (feature.boolean {kind,targetBodyID,toolBodyIDs}, feature.fillet {bodyID,radius,edges,query_token?} / feature.chamfer {bodyID,setback,edges,query_token?}, feature.shell {bodyID,thickness,openFaces,query_token?}, feature.pattern {bodyID,kind,count,...}); Face/edge index operations require query_token from query kind=faces/edges (or the row's stable face signature/edge midpoint); index existence alone is rejected with requery_required because a rebuild can reuse an index for a different face/edge. measure accepts op to name the kind (body|distance|bounds|dof|interference|mesh|rebuild)." },
    "payload": { "type": "string", "description": "JSON object string for native workbench services (three_d_assembly/three_d_drawing), material/parameters/capture/animation/scene, and the versions action. scene payload: {action:get|setSection|setSectionEnabled|flipSection|removeSection|setMeasurementsVisible|addMeasurement|removeMeasurement|clearMeasurements|undo|redo, origin?/normal? or x_axis?/y_axis? (mm), enabled?, flip?, size_mm?, start?/end? (mm), id?}. versions: {action:list|create|compare|restore|delete|recoveries|recover|discard_recovery|record, name? (create), version_id? (compare/restore/delete/recover/discard_recovery/record), against_version_id? (compare/record; omit = current committed document), expected_revision? (restore CAS), expected_content_sha256? (restore CAS), create_branch? (restore; default true), branch_name? (restore), offset?/limit? (compare page; limit 1...240), identity? (compare/record continuation: copy the exact from/to objects returned by the first page), section?/identifier? (record: the difference section and record id), chunk_offset?/chunk_limit? (record page over the exact stored JSON; byte-bounded chunks; limit 1...256)}. list/compare/compare pages/recoveries/record are read-only; create/restore/delete/recover/discard_recovery are ordinary task-authorized CAD edits with the document's own ownership/revision CAS. list also returns retained unpublished checkpoints under recoveries; recover publishes one only after it verifies, while discard_recovery deletes only that unpublished checkpoint. compare returns totalDifferences/nextOffset; a later page requires identity pins and a changed current revision is refused. record returns the exact stored record JSON (or the whole stored section for section-level records), its whole-value SHA-256, and byte-bounded chunk pages, so omitted summary fields can be fetched without inventing data. A named version is an explicit whole-document checkpoint, not automatic per-edit history; restore starts a new undo boundary and keeps the pre-restore state as a recovery version. Animation actions: list|query|evaluate (real timeline data), createClip|updateClip|deleteClip|setActiveClip, addTrack|deleteTrack, setKeyframe|setCameraKeyframe|setPartKeyframe|deleteKeyframe, preset {kind:turntable|explodeReturn}, undo|redo, capture {clip_id?,time?|frame?,fps?,width?,height?,format?}, export {output? (workspace .mp4 for mp4, .zip for png_zip),format?:mp4|png_zip,width?,height?,fps?,codec?,bitrate?,overwrite?,poster?,alpha?:opaque|transparent}. Animation edits are ordinary undoable document commands; capture returns a real animated native frame. export returns a verified MP4 (format mp4; codec/bitrate apply) or one ZIP of ordered lossless PNG frames plus manifest.json (format png_zip; codec must be png, no bitrate), with task_id and publishes it through RunOutput. alpha:transparent is refused before rendering: exports keep the scene's opaque background and MP4 H.264/HEVC has no alpha channel. Material actions: list|read|create|update|remove|apply|applyFaces|reassignFaces|mapping|textures|unresolved|libraryExport|libraryImport|libraryList|undo|redo; create/update/apply accept color [r,g,b(,a)] 0…1 (or #RRGGBB[AA]), metallic/roughness/opacity, emissive + emissive_strength, uv_mapping {source:mesh|planarProjection|boxProjection, axis:x|y|z, scale_mm:[u,v], rotation_degrees, offset:[u,v], flip_u, flip_v}, textures [{slot:baseColor|metallic|roughness|normal|emissive|opacity, asset_path? or asset_base64?, color_space?, orientation?}]. Parameter actions: list|update|updateSketchEntity|deleteSketchEntity|setSketchDimension|removeSketchDimension|variable.create|variable.update|variable.delete|feature.setExpression|datum.offsetPlane.create|datum.offsetPlane.update|datum.offsetPlane.delete|sketch.setSupport|sketch.clearSupport|feature.suppress|feature.delete|feature.move|undo|redo; update {feature_id, changes:{distance|angle|taper_angle|radius|setback|thickness|factor|count|spacing|total_angle|symmetric|rotate_instances|hole_type|depth|counterbore_diameter|counterbore_depth|countersink_diameter|countersink_angle|reversed:...}} uses the units query kind=features reports; updateSketchEntity {sketch_id, entity_id, a?, b? | min?, max?, center?, width?, height? | center?, radius?, diameter? | center?, radius?, diameter?, start_angle_deg?, end_angle_deg?, sweep_angle_deg? | center?, radius_x?, radius_y?, rotation_deg? | points? or point_index? + point?, expected_*} edits one existing line/rect/circle/arc/ellipse/spline by stable id and updates matching circle/arc radius or arc sweep dimensions in the same undo step (angles are degrees; an arc stores a CCW sweep under 360 degrees; spline point_index is the zero-based fit-point identity; refused as locked_entity for a Lock, dependent_reference for unsupported referenced geometry, or constraint_conflict if the saved sketch would become unsatisfied; polygon remains query-only); deleteSketchEntity {sketch_id, entity_id, remove_shared_references?, remove_pattern_link?} deletes exactly one entity by stable id in one undo step: references that only name it are removed and reported, a reference that also anchors another entity refuses with shared_references unless the explicit flag is true, and a pattern link refuses unless remove_pattern_link:true while every instance keeps its id; setSketchDimension {sketch_id, entity_id|entity_ids|refs, kind:length|distance|angle|diameter|radius|width|height, value|expression, expected_value?, expected_expression?, dimension_id?} creates or updates one driving value from exactly one of a positive finite number or a formula expression in the SAME public unit, solves with the existing solver and commits one undo step; sending both refuses ambiguous_value and a formula that references an unknown variable/function refuses before mutation. The expression text is stored on the dimension's formula (query kind=constraints exposes formula/formula_unit/formula_reference_names); an angle's formula stays in public degrees while its stored value is radians. expected_value fences the current public numeric value; expected_expression fences the exact stored formula (empty string means none). Variable fan-out re-evaluates the formula and commits every dependent sketch/feature rebuild with the variable edit as ONE undo step (angle is degrees; length is a line's distance; width/height store as horizontal/vertical); removeSketchDimension {sketch_id, dimension_id}; variable.create {name, expression} creates a named unitless scalar; variable.update {variable_id, name?, expression?, expected_expression?} edits/renames one variable and rewrites every variable/feature/sketch formula reference by identifier token (never substring); variable.delete {variable_id} refuses with exact dependent variable/feature/dimension ids while the name is still referenced; both create and update validate names, functions, references and cycles BEFORE commit, and one variable edit plus every dependent feature/sketch rebuild is ONE undo/redo transaction. feature.setExpression {feature_id, parameter, expression, expected_expression?} binds a formula to a parameter query kind=features reports with expression_action=feature.setExpression; expression is written in the PUBLIC unit (deg/mm/unitless) and a radian-persisted public-degree parameter stores an explicit radians(...) conversion rather than an unconverted degree value; expected_expression fences the exact stored `formula` row (radian-valued for a radian-persisted angle), not public_expression; parameters without a formula-capable Expr refuse unsupported_parameter instead of a value-only edit. feature.suppress {feature_id, suppressed}; feature.delete {feature_id, force?} refuses when later features consume its bodies unless forced and always rolls back a broken rebuild; feature.move {feature_id, to_index} verifies body dependency order before moving. datum.offsetPlane.create {body_id, face_index, query_token, expression, size?} creates an associative offset plane in mm from one exact named planar OCCT face; face_index is the kernel index from query kind=faces, never a render triangle. datum.offsetPlane.update {plane_id, expression?, expected_expression?, body_id?, face_index?, query_token?, size?} edits the same plane; source re-selection requires the complete fresh face triple. datum.offsetPlane.delete {plane_id} refuses while referenced. sketch.setSupport {sketch_id, plane_id} rehosts local sketch geometry on that construction plane; sketch.clearSupport {sketch_id} detaches at its current frame. All five operations are ordinary atomic undoable edits; invalid references/formulas refuse before commit. Discover exact ids/formulas/units/dependencies with query kind=planes/sketches/variables/constraints/features. Observe works for an ORIGINAL mesh/CAD-surface file and for an authorised native .floecad document. Original (GLB/glTF keep the three.js scene path): {views?:[{azimuthDegrees,elevationDegrees,distanceScale?}],width?,height?,projection?:perspective|orthographic,sceneIndex?,cameraIndex?,clipIndex?,timeSeconds?,expectedSourceSHA256?,maximumSourceBytes?,maximumResources?,includeImages?,nodeOffset?,nodeLimit?}; defaults to four real camera views and the viewer's actual camera projection. sceneIndex/cameraIndex/clipIndex/timeSeconds are actual GLB/glTF scene selections; static originals allow only sceneIndex 0 (or omitted) and refuse any camera, clip or nonzero time instead of returning a static first frame. Native .floecad uses the SAME request plus two optional live-generation pins: expectedRevision (last committed revision) and expectedChangeCount (the live in-memory generation, which also advances for an unsaved draft). expectedSourceSHA256 on a native document pins the last committed package content SHA-256, never a digest of unsaved mesh bytes. Omit pins for the first observation and reuse the revision/change_count/content_sha256 it returns; disagreeing payload/top-level revision pins and old pins are refused. Frames are real ephemeral offscreen engineering renders of the live scene with a locally fitted camera: the user's camera, selection, preferences, saved appearance, animation playback and undo history are not modified, and the image is not an active RealityKit Present capture (renderer=engineering, present_pixels=false). Native views support exact top/bottom pole frames; cameraIndex, clipIndex and timeSeconds>0 are refused instead of rendering an unrelated static frame — use action=animation with capture {clip_id,time} for actual animated frames. Both routes keep includeImages:false query-only, and the hierarchy is paged with nodeOffset/nodeLimit plus nextOffset; native object rows come from the deterministic body query at the same revision/change_count with stable ids and query_token/generation values. A native .floecad written by a newer app version opens read-only and is refused here. STEP/IGES/BREP pixels come from a lossy display triangulation, not native editable B-Rep; native frames show the actual kernel-built display scene, not CAD topology derived from pixels. This does not create CAD topology or authorize file writes. Capture: {width?,height?} returns a real viewport PNG artifact with renderer=presentation only while Present is active, otherwise renderer=engineering; it is bound to revision/change_count and image_sha256 is separate from content_sha256. applyFaces/reassignFaces require query_token from query kind=faces or face_signatures; index-only edits are refused with requery_required (query tokens are generation proof, not permission). Workbench service payloads MUST name one operation via payload.action or legacy payload.op; mutating workbench services still use propose→apply, while material/parameter edits are ordinary authorized undoable document commands. A global libraryExport/libraryImport uses the single app-owned personal library (libraryList reads it with global:true); global export writes a file so it is refused in temporary/read-only contexts. Never contains file paths other than the guarded asset_path/output/import fields above." }
  }
}
"""#

    private static let referenceToolDescription = #"""
Export native CAD with action "export": scope=part keeps the historical selected/all document-body behaviour; scope=assembly writes the saved placed occurrences (nested subassemblies, exact occurrence ids/paths and world transforms), never a flattened document.bodies copy. Add dry_run=true for the coverage receipt only; an incomplete receipt (for example STEP with mesh-only objects) writes nothing unless accept_partial=true is explicit. Observe an original mesh or CAD-surface file, or an authorised native `.floecad` document, with action "observe" without importing, copying or modifying it: choose 1...4 finite views and an optional projection (includeImages=false permits no views for hierarchy-only queries); for GLB/glTF only, a real scene/camera/clip/time; for native documents, optional expectedRevision/expectedChangeCount/expectedSourceSHA256 generation pins. Native frames are real ephemeral offscreen engineering renders of the live scene (renderer=engineering, never an active Present claim) with no change to the user's camera, selection, preferences, saved appearance, playback or undo history; camera/clip/time selections are refused and animated frames use action="animation". Consume actual image artifacts plus source/image hashes and the paged native object rows (stable ids + query_token/generation) bound to the same revision/change_count. GLB/glTF keep the three.js scene path; other originals use the bundled Online3DViewer and STEP/IGES/BREP keep their local display-triangulation conversion. A screenshot does not establish CAD face IDs, B-Rep topology or manufacturing dimensions. Create, import into, read, query, measure, propose changes to, apply confirmed proposals to, save and export a CAD document. The document representation decides the engine: a DWG/DXF drawing runs in the local 2D engine, a native `.floecad` package runs in the parametric 3D kernel. Use action "create" (path/name) to make a new EMPTY native `.floecad` package through the built-in factory — never create the folder, manifest or zip by hand and never guess the internal package layout. Use action "import" on an EXISTING `.floecad` to add the geometry of a workspace STEP/STP, IGES/IGS, STL, OBJ, GLB or glTF file: it drafts a proposal on a throwaway copy and returns a preview. STEP gives exact editable solids; IGES solids are exact and open shells/faces become exact surface bodies that can be moved/rotated/scaled, painted and re-exported to IGES, but cannot take solid boolean/fillet/shell; STL/OBJ/GLB are render meshes with no parametric history. Use action "reference" to attach/check/update/inspect an external native `.floecad` part from the authorized task workspace: source_path is a path request resolved by the host guard (never a model grant); attach/update are ordinary committed CAD edits with source/staged hash CAS, while inspect/check are read-only. Propose binds an exact document revision and SHA-256 and returns a preview without writing. Apply commits ONE atomic undoable transaction for the exact proposal the approved call names: a `grant_id` selects the human-reviewed CAD UI path, and WITHOUT one the runtime-approved call authority for that exact apply authorizes it automatically (the model cannot mint or replay either; the proposal's revision/SHA is re-verified against the live document at commit). 2D edits are lines, circles, arcs, LWPolylines, text, dimensions and leaders plus move/copy/rotate/scale/mirror/trim/extend/offset and layer management. 3D, blocks, xrefs, splines and proxy graphics are retained read-only in the 2D engine; they are never flattened. Units stay drawing units when undefined. Native documents add parametric features, assembly constraints, drawings, ShapeScript and mesh operations through the typed operation vocabulary (`op` + `args`; feature.extrude, feature.hole, feature.boolean, ...) and the three_d_* aliases; status/cancel report durable native jobs. Workflow: create → propose sketch.create → apply → propose sketch.addEntities → apply → propose feature.extrude → apply → measure → export. For text use the native text-sketch route instead of the unavailable mesh.text: propose sketch.addText {sketchID,text,height,fontName?,origin?} → apply → propose feature.extrude on the resulting closed profiles (holes are real counter loops) → apply → measure. Every native propose sends op at the TOP LEVEL beside action and path. Its args is a serialized JSON object containing ONLY the operation parameters, never another {op,args} envelope. For extrusion, serialize {sketchID,seedPoint:[x,y],distance:mm} into args. Native `.floecad` documents additionally accept action "material" (custom PBR material library: list/read/create/update/remove/ apply/applyFaces/reassignFaces/mapping/textures/unresolved/libraryExport/ libraryImport/libraryList/undo/redo; applied appearances are snapshots and survive library deletion), action "parameters" (typed feature parameter list/update/undo/redo; updateSketchEntity for an existing line's endpoints, a rectangle's position/size or a circle's center/radius; setSketchDimension/removeSketchDimension for driving length/distance/ angle/radius/diameter/width/height values (setSketchDimension accepts a positive number or a PUBLIC-unit expression such as width / 8; the exact expression is stored on the dimension formula while an angle's formula text stays in degrees and its solved value is stored in radians); variable.create/update/delete for named scalar formulas (one atomic undo including every dependent feature/sketch rebuild; delete refuses while referenced and rename rewrites identifier tokens); feature.setExpression to bind a formula to an existing formula-capable feature scalar in its PUBLIC unit; feature.suppress/delete/move with dependency checks and checkpoint rollback — units and actions come from query kind=features/sketches/variables/constraints), action "animation" (native camera/assembly keyframe clips: list/query/evaluate, createClip/updateClip/deleteClip/setActiveClip, addTrack/deleteTrack, setKeyframe/setCameraKeyframe/setPartKeyframe/deleteKeyframe, turntable/explodeReturn presets and undo/redo; capture returns an actual animated native frame; export renders a verified MP4, default 1920x1080 at 30 fps H.264 with no audio, and reports a durable task_id for status/ cancel; authored edits are ordinary undoable document commands and playback/scrub never changes the geometry or assembly baseline), and action "capture" (actual viewport PNG artifact bound to the document revision/change_count; only a vision-capable model may inspect it — otherwise measure, never claim to have seen the image). Native `.floecad` also accepts action "scene" (the SAME persisted sceneSettings overlay the editor uses: get/setSection/setSectionEnabled/flipSection/removeSection/ setMeasurementsVisible/addMeasurement/removeMeasurement/clearMeasurements/ undo/redo; setSection takes origin [x,y,z] mm plus normal or x_axis/y_axis; addMeasurement takes start/end world mm and returns its id/length; every mutation is one ordinary undoable document command committed with CAS, and no geometry is edited). Section cut and guide lines appear in screenshots/video, but numeric values are not baked into pixels; model exchange (STEP/IGES/GLB/USDZ/OBJ/STL/3MF) carries geometry only. Action "versions" creates, lists, compares, restores and deletes user-named whole-document checkpoints through payload.action; it also lists retained unpublished checkpoints and can recover or discard one. Compare pages through every difference with identity pins, and record returns the exact stored record JSON (byte-bounded chunk pages) when a summary detail omits fields. Restore is revision/CAS-checked, the pre-restore state is kept as a recovery version, and in-memory undo does not cross a restore. Restore creates a named branch checkpoint of the restored state by default while keeping the same document identity; create_branch=false restricts it to the in-place restore. Nothing is written by propose/preview/import; material/parameter/animation edits are undoable document commands committed with compare-and-swap, and temporary chat remains read-only.
"""#

    private static let canonicalSchema = CadDocumentTool.parametersJSON
    private static let canonicalDescription = CadDocumentTool.toolDescription

    private func cadDescriptor() -> ToolSchemaDescriptor {
        ToolSchemaDescriptor(
            name: CadDocumentTool.name,
            description: CadDocumentTool.toolDescription,
            parametersJSON: CadDocumentTool.parametersJSON
        )
    }

    private func searchDescriptor() -> ToolSchemaDescriptor {
        ToolSchemaDescriptor(
            name: "tools.search",
            description: "Load one exact tool definition",
            parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}}}"#
        )
    }

    private func readDescriptor() -> ToolSchemaDescriptor {
        ToolSchemaDescriptor(
            name: "workspace.readFile",
            description: "Read a workspace file"
        )
    }

    private func localModel(
        _ remoteModelID: String,
        contextTokens: Int,
        maxOutputTokens: Int
    ) -> ModelProfile {
        ModelProfile(
            providerID: LocalProviderAdapter.providerProfile.id,
            remoteModelID: remoteModelID,
            displayName: "X34-R2 local admission",
            limits: .init(
                contextTokens: contextTokens,
                maxOutputTokens: maxOutputTokens
            ),
            capabilities: [.text, .tools, .approval]
        )
    }

    private func object(_ any: Any?) throws -> [String: Any] {
        try XCTUnwrap(any as? [String: Any])
    }

    /// The real resource-policy windows rather than invented numbers.
    private static func policyWindows() -> [(context: Int, output: Int)] {
        let profiles = [
            LocalInferenceResourcePolicy.profile(
                mappedBytes: 10, physicalMemoryBytes: 10, reservedBytes: 0
            ),
            LocalInferenceResourcePolicy.profile(
                mappedBytes: 5, physicalMemoryBytes: 10, reservedBytes: 0
            ),
            LocalInferenceResourcePolicy.profile(
                mappedBytes: 1, physicalMemoryBytes: 10, reservedBytes: 0
            ),
        ]
        return profiles.map { (context: Int($0.contextSize), output: $0.maximumOutputTokens) }
    }

    /// JSON with every `description` key removed. This is the semantic
    /// structure that must not change when authored prose moves to help.
    private func structural(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in dictionary where key != "description" {
                result[key] = structural(child)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map(structural)
        }
        return value
    }

    private func canonicalJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: structural(value),
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private func allHelpText() -> String {
        CadDocumentHelp.topics.map(\.text).joined(separator: "\n\n")
    }

    // MARK: - One canonical structure, full old documentation on demand

    func testCanonicalDefinitionKeepsEveryStructuralConstraintAndMovesProseToHelp() throws {
        let referenceData = try XCTUnwrap(Self.referenceSchemaJSON.data(using: .utf8))
        let currentData = try XCTUnwrap(Self.canonicalSchema.data(using: .utf8))
        let reference = try object(try JSONSerialization.jsonObject(with: referenceData))
        let current = try object(try JSONSerialization.jsonObject(with: currentData))

        XCTAssertEqual(
            try canonicalJSON(current),
            try canonicalJSON(reference),
            "The canonical definition must keep every field, type, required list, enum, item schema, bound and additionalProperties."
        )

        let referenceProperties = try object(reference["properties"])
        let currentProperties = try object(current["properties"])
        XCTAssertEqual(Set(currentProperties.keys), Set(referenceProperties.keys))
        XCTAssertEqual(current["required"] as? [String], reference["required"] as? [String])
        XCTAssertEqual(
            current["additionalProperties"] as? Bool,
            reference["additionalProperties"] as? Bool
        )

        // The action surface is not reduced by the prose move.
        let referenceAction = try object(referenceProperties["action"])
        let currentAction = try object(currentProperties["action"])
        XCTAssertEqual(currentAction["enum"] as? [String], referenceAction["enum"] as? [String])
        let referenceActions = Set(try XCTUnwrap(referenceAction["enum"] as? [String]))
        let actionHelp = try XCTUnwrap(CadDocumentHelp.fullText(for: "actions"))
        for action in referenceActions {
            XCTAssertTrue(actionHelp.contains(action), "actions help lost \(action)")
        }

        // The authored definition is smaller; the full schema is not.
        XCTAssertGreaterThan(Self.referenceSchemaJSON.utf8.count, 30_000)
        XCTAssertLessThan(Self.canonicalSchema.utf8.count, 12_000)
        XCTAssertLessThan(Self.canonicalDescription.utf8.count, 2_000)

        // Every old field description and the old overview survive verbatim
        // in the public static guide. This is the no-loss help contract.
        let help = allHelpText()
        for (key, value) in referenceProperties {
            guard let property = value as? [String: Any],
                  let description = property["description"] as? String,
                  !description.isEmpty else { continue }
            XCTAssertTrue(
                help.contains(description),
                "built-in help lost the complete old description for \(key)"
            )
        }
        XCTAssertTrue(
            help.contains(Self.referenceToolDescription),
            "built-in help lost the authored pre-change tool overview"
        )
        XCTAssertTrue(help.contains("This guide is description, not authority"))
    }

    func testBuiltInHelpIsFullyReadablePagedAndContentAddressed() async throws {
        let tool = CadDocumentTool(host: HelpOnlyHost())
        let context = ToolContext(
            runID: UUID(),
            scope: .local,
            cancellation: CancellationToken()
        )

        // Catalog: every topic with exact bytes and SHA-256.
        let catalog = try await executeHelp(tool, context: context, [
            "documentation": "topics",
        ])
        let catalogDoc = try object(catalog["documentation"])
        XCTAssertEqual(catalogDoc["guide_version"] as? Int, CadDocumentHelp.guideVersion)
        XCTAssertEqual(catalogDoc["guide_sha256"] as? String, CadDocumentHelp.guideSHA256)
        let rows = try XCTUnwrap(catalogDoc["topics"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["name"] as? String }, CadDocumentHelp.topicNames)
        for row in rows {
            let name = try XCTUnwrap(row["name"] as? String)
            let topic = try XCTUnwrap(CadDocumentHelp.topics.first { $0.name == name })
            XCTAssertEqual(row["bytes"] as? Int, topic.byteCount)
            XCTAssertEqual(row["sha256"] as? String, topic.sha256)
            let pageCount = try XCTUnwrap(row["page_count"] as? Int)
            XCTAssertGreaterThan(pageCount, 0)
        }

        // Every page of every topic, joined in order, equals the full topic.
        for topic in CadDocumentHelp.topics {
            var pageIndex = 0
            var joined = ""
            var pageCount: Int?
            while true {
                let reply = try await executeHelp(tool, context: context, [
                    "documentation": topic.name,
                    "page": pageIndex,
                    "page_size": CadDocumentHelp.defaultPageSize,
                ])
                let doc = try object(reply["documentation"])
                XCTAssertEqual(doc["topic"] as? String, topic.name)
                XCTAssertEqual(doc["page"] as? Int, pageIndex)
                XCTAssertEqual(doc["topic_sha256"] as? String, topic.sha256)
                XCTAssertEqual(doc["guide_sha256"] as? String, CadDocumentHelp.guideSHA256)
                let pageText = try XCTUnwrap(doc["text"] as? String)
                XCTAssertLessThanOrEqual(
                    pageText.utf8.count,
                    CadDocumentHelp.defaultPageSize,
                    "a help page must stay inside the requested byte page size"
                )
                XCTAssertEqual(
                    doc["content_sha256"] as? String,
                    FloeDigest.sha256Hex(Data(pageText.utf8))
                )
                joined += pageText
                let currentCount = try XCTUnwrap(doc["page_count"] as? Int)
                if let pageCount {
                    XCTAssertEqual(currentCount, pageCount)
                } else {
                    pageCount = currentCount
                }
                if let next = doc["next_page"] as? Int {
                    XCTAssertEqual(next, pageIndex + 1)
                    pageIndex = next
                } else {
                    XCTAssertNil(doc["next_page"] as? Int)
                    break
                }
            }
            XCTAssertEqual(joined, topic.text)
            let totalPages = try XCTUnwrap(pageCount)
            XCTAssertEqual(totalPages, pageIndex + 1)
        }

        // Rich old vocabulary is actually reachable through the guide.
        let payloads = try XCTUnwrap(CadDocumentHelp.fullText(for: "payloads"))
        for token in [
            "scene payload", "alpha:transparent", "libraryExport",
            "createClip", "setCameraKeyframe", "expectedRevision",
            "present_pixels=false", "renderer=engineering",
            "create_branch", "chunk_offset",
        ] {
            XCTAssertTrue(payloads.contains(token), "payloads help lost \(token)")
        }
        let native = try XCTUnwrap(CadDocumentHelp.fullText(for: "native-operations"))
        for token in [
            "sketch.addText", "feature.extrude", "feature.hole",
            "unsupported_font", "unsupported_glyphs",
            "no standalone mesh.text operation",
            CadNativeOperationVocabulary.executable.joined(separator: ", "),
        ] {
            XCTAssertTrue(native.contains(token), "native-operations help lost \(token)")
        }

        // Unknown selectors and out-of-range pages fail closed, never truncate.
        let args = try decodeArgs([
            "action": "capabilities",
            "payload": #"{"documentation":"payloads","page":9999}"#,
        ])
        do {
            try tool.validate(args)
            _ = try await tool.execute(args, context: context)
            XCTFail("an out-of-range documentation page must be refused")
        } catch let error as FloeError {
            guard case .validationFailed(let message) = error else {
                return XCTFail("unexpected help page error: \(error)")
            }
            XCTAssertTrue(message.contains("page must be 0..."))
        }
    }

    func testHelpPageSelectorsDistinguishNumbersFromBooleansAndRefuseOverflow() async throws {
        let tool = CadDocumentTool(host: HelpOnlyHost())
        let context = ToolContext(
            runID: UUID(),
            scope: .local,
            cancellation: CancellationToken()
        )

        // `documentation: true` is still a real CFBoolean selector.
        let topics = try await executeHelp(tool, context: context, [
            "documentation": true,
        ])
        XCTAssertEqual(
            (try object(topics["documentation"]))["guide_version"] as? Int,
            CadDocumentHelp.guideVersion
        )

        // Real JSON numbers 0/1/2 are page indexes, not booleans. Numeric
        // NSNumber 0/1 satisfies `is Bool` on Apple platforms, which used to
        // reject page 0 before any page could be read.
        for page in [0, 1, 2] {
            let reply = try await executeHelp(tool, context: context, [
                "documentation": "actions",
                "page": page,
                "page_size": 256,
            ])
            let doc = try object(reply["documentation"])
            XCTAssertEqual(doc["page"] as? Int, page)
            XCTAssertEqual(doc["page_size"] as? Int, 256)
            XCTAssertNotNil(doc["text"] as? String)
            XCTAssertNotNil(doc["content_sha256"] as? String)
        }

        // Numeric page_size 0/1 are parsed as numbers and then refused by the
        // documented 256...3500 range, never as booleans or a valid page.
        for pageSize in [0, 1] {
            let args = try helpArguments([
                "documentation": "actions",
                "page_size": pageSize,
            ])
            do {
                try tool.validate(args)
                _ = try await tool.execute(args, context: context)
                XCTFail("page_size \(pageSize) must be outside the documented range")
            } catch let error as FloeError {
                guard case .validationFailed(let message) = error else {
                    return XCTFail("unexpected page_size error: \(error)")
                }
                XCTAssertTrue(
                    message.contains(
                        "page_size must be 256...\(CadDocumentHelp.maximumPageSize)"
                    ),
                    message
                )
            }
        }

        // Negative whole numbers are parsed as integers and then refused by
        // the documented ranges; they are not confused with fractions or
        // booleans, and the message identifies the range rather than the type.
        let negativeCases: [(field: String, selector: [String: Any], expected: String)] = [
            ("page", ["documentation": "actions", "page": -1],
             "documentation page must be zero or greater"),
            ("page_size", ["documentation": "actions", "page_size": -1],
             "documentation page_size must be 256...\(CadDocumentHelp.maximumPageSize)"),
        ]
        for item in negativeCases {
            let args = try helpArguments(item.selector)
            do {
                try tool.validate(args)
                _ = try await tool.execute(args, context: context)
                XCTFail("negative \(item.field) must be outside the documented range")
            } catch let error as FloeError {
                guard case .validationFailed(let message) = error else {
                    return XCTFail("unexpected negative \(item.field) error: \(error)")
                }
                XCTAssertTrue(message.contains(item.expected), message)
            }
        }

        // The nested selector object shares the same typed parser.
        let nested = try await executeHelp(tool, context: context, [
            "documentation": [
                "topic": "actions",
                "page": 0,
                "page_size": 3000,
            ],
        ])
        XCTAssertEqual((try object(nested["documentation"]))["page"] as? Int, 0)

        // Missing and explicit-null pages preserve the default semantics.
        for selector in [
            ["documentation": "actions"] as [String: Any],
            ["documentation": "actions", "page": NSNull(), "page_size": NSNull()] as [String: Any],
        ] {
            let reply = try await executeHelp(tool, context: context, selector)
            let doc = try object(reply["documentation"])
            XCTAssertEqual(doc["page"] as? Int, 0)
            XCTAssertEqual(doc["page_size"] as? Int, CadDocumentHelp.defaultPageSize)
        }

        // Booleans, fractions and overflowing numbers refuse as that field,
        // never as a valid page 0/1 and never by trapping the conversion.
        let refused: [(field: String, selector: [String: Any])] = [
            ("page", ["documentation": "actions", "page": true]),
            ("page", ["documentation": "actions", "page": false]),
            ("page", ["documentation": "actions", "page": 1.5]),
            ("page", ["documentation": "actions", "page": 1e20]),
            ("page", ["documentation": "actions", "page": UInt64(Int.max) + 1]),
            ("page", ["documentation": "actions", "page": 9.223372036854776e18]),
            ("page_size", ["documentation": "actions", "page_size": true]),
            ("page_size", ["documentation": "actions", "page_size": false]),
            ("page_size", ["documentation": "actions", "page_size": 1.5]),
            ("page_size", ["documentation": "actions", "page_size": 1e20]),
            ("page_size", ["documentation": "actions", "page_size": UInt64(Int.max) + 1]),
            ("page_size", ["documentation": "actions", "page_size": 9.223372036854776e18]),
        ]
        for item in refused {
            try await assertHelpRefused(
                tool,
                context: context,
                item.selector,
                field: item.field
            )
        }

        // A numeric documentation selector is not a boolean `true` alias.
        for numericSelector in [1, 0] {
            let args = try helpArguments(["documentation": numericSelector])
            do {
                try tool.validate(args)
                _ = try await tool.execute(args, context: context)
                XCTFail("documentation: \(numericSelector) must not become a boolean selector")
            } catch let error as FloeError {
                guard case .validationFailed(let message) = error else {
                    return XCTFail("unexpected documentation selector error: \(error)")
                }
                XCTAssertTrue(message.contains("must be a topic name"))
            }
        }
    }

    // MARK: - Production prompt admission at every supported local window

    func testRepresentativeWindowsAreTheRealLocalResourcePolicy() {
        let windows = Self.policyWindows()
        XCTAssertEqual(windows.map(\.context), [8_192, 12_288, 16_384])
        XCTAssertEqual(windows.map(\.output), [1_024, 1_536, 1_536])
    }

    func testCanonicalDefinitionIsAdmittedWholeAtRepresentativeLocalWindows() throws {
        let windows = Self.policyWindows()
        let tools = [searchDescriptor(), cadDescriptor(), readDescriptor()]
        let prompt = "用 cad.document 创建 40×30×5 毫米支架并读取孔径。"

        for window in windows {
            for remoteModelID in [
                "qwen3.8-4b-heretic-mlx4",
                "gemma4-e4b-mlx4",
            ] {
                let build = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
                    provider: LocalProviderAdapter.providerProfile,
                    model: localModel(
                        remoteModelID,
                        contextTokens: window.context,
                        maxOutputTokens: window.output
                    ),
                    messages: [("user", prompt)],
                    toolSchemas: tools,
                    allToolNames: tools.map(\.name)
                ))
                let selectedCAD = try XCTUnwrap(
                    build.selectedTools.first { $0.name == CadDocumentTool.name },
                    "\(remoteModelID) at \(window.context) did not admit the canonical CAD definition"
                )
                XCTAssertEqual(selectedCAD.parametersJSON, Self.canonicalSchema)
                XCTAssertEqual(selectedCAD.description, Self.canonicalDescription)
                XCTAssertEqual(selectedCAD.parametersJSON, CadDocumentTool.parametersJSON)
                XCTAssertTrue(
                    build.fallbackTools.contains { $0.name == CadDocumentTool.name }
                )
                XCTAssertLessThanOrEqual(
                    build.estimatedPromptTokens,
                    build.windowPromptTokenBudget
                )
                XCTAssertFalse(build.exceedsContextWindow)

                if remoteModelID.hasPrefix("qwen") {
                    XCTAssertTrue(build.nativeToolSchemas.isEmpty)
                    XCTAssertTrue(build.systemInstructions.contains(Self.canonicalSchema))
                    XCTAssertTrue(build.systemInstructions.contains("COMPLETE TOOL DEFINITIONS"))
                    XCTAssertTrue(build.systemInstructions.contains("the chat template receives no native tool schemas"))
                } else {
                    let nativeCAD = try XCTUnwrap(
                        build.nativeToolSchemas.first { $0.name == CadDocumentTool.name }
                    )
                    XCTAssertEqual(nativeCAD.parametersJSON, Self.canonicalSchema)
                    XCTAssertEqual(nativeCAD.description, Self.canonicalDescription)
                }

                let attachment = XCTAttachment(string: """
                model=\(remoteModelID) context=\(window.context) output=\(window.output) \
                cadSchemaBytes=\(Self.canonicalSchema.utf8.count) \
                cadDescriptionBytes=\(Self.canonicalDescription.utf8.count) \
                selectedTools=\(build.selectedTools.map(\.name).joined(separator: ",")) \
                fallbackTools=\(build.fallbackTools.map(\.name).joined(separator: ",")) \
                estimatedPromptTokens=\(build.estimatedPromptTokens) \
                windowPromptTokenBudget=\(build.windowPromptTokenBudget)
                """)
                attachment.name = "x34r2-admission-\(remoteModelID)-\(window.context).txt"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testRealOfferPlannerAdmitsCanonicalCADInTheActualLocalReserve() {
        let cad = ToolCatalog.Descriptor(
            name: CadDocumentTool.name,
            toolDescription: CadDocumentTool.toolDescription,
            parametersJSON: CadDocumentTool.parametersJSON,
            riskLabels: [],
            isSideEffecting: true
        )
        let search = ToolCatalog.Descriptor(
            name: "tools.search",
            toolDescription: "Load one exact tool definition",
            parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}}}"#,
            riskLabels: [],
            isSideEffecting: false
        )
        // The real runtime reserve for an 8,192-token local profile: output
        // 1,024, 800 tokens of messages, no images/replay, and the production
        // one-quarter tool-result reserve.
        let budget = ToolSchemaOfferPlanner.availableTokenBudget(
            contextWindowTokens: 8_192,
            reservedOutputTokens: 1_024,
            messageTokens: 800,
            imageTokens: 0,
            replayTokens: 0,
            toolResultReserveTokens: 2_048
        )
        let plan = ToolSchemaOfferPlanner.plan(
            descriptors: [search, cad],
            tokenBudget: budget,
            alwaysKeep: ["tools.search"]
        )
        XCTAssertTrue(plan.offered.contains { $0.name == CadDocumentTool.name })
        XCTAssertFalse(plan.deferred.contains(CadDocumentTool.name))
        XCTAssertFalse(plan.oversized.contains(CadDocumentTool.name))
        XCTAssertLessThanOrEqual(plan.estimatedTokens, budget)
        XCTAssertGreaterThan(budget, ToolSchemaOfferPlanner.tokenCost(cad))
    }

    func testGenuinelyOversizedInputDefersCanonicalDefinitionWholeWithRetrieval() {
        let tools = [searchDescriptor(), cadDescriptor(), readDescriptor()]
        // A real CAD request with a genuinely oversized body. The earlier
        // all-"A" fixture had no CAD/action intent, so the planner correctly
        // never considered the CAD schema and could not truthfully claim it
        // "did not fit this model window"; the three system-instruction
        // assertions below were therefore testing an impossible state. Keep
        // the same oversized budget pressure, but make the turn actually ask
        // for the canonical CAD definition.
        let huge = "用 cad.document 创建 40×30×5 毫米支架并读取孔径。"
            + String(repeating: "A", count: 35_000)
        let build = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: localModel(
                "gemma4-e4b-mlx4",
                contextTokens: 16_384,
                maxOutputTokens: 1_536
            ),
            messages: [("user", huge)],
            toolSchemas: tools,
            allToolNames: tools.map(\.name)
        ))
        XCTAssertFalse(build.selectedTools.contains { $0.name == CadDocumentTool.name })
        XCTAssertTrue(build.fallbackTools.contains { $0.name == CadDocumentTool.name })
        XCTAssertTrue(build.selectedTools.contains { $0.name == "tools.search" })
        // The deferred fallback carries the complete canonical definition
        // byte-for-byte; only presentation moved to the tools.search path.
        XCTAssertEqual(
            build.fallbackTools.first { $0.name == CadDocumentTool.name }?.parametersJSON,
            Self.canonicalSchema
        )
        XCTAssertEqual(
            build.fallbackTools.first { $0.name == CadDocumentTool.name }?.description,
            Self.canonicalDescription
        )
        XCTAssertTrue(build.systemInstructions.contains("deferred rather than sliced"))
        XCTAssertTrue(build.systemInstructions.contains("did not fit this model window"))
        XCTAssertTrue(build.systemInstructions.contains("Load one exact name with tools.search"))
        XCTAssertFalse(build.systemInstructions.contains(Self.canonicalSchema))
        XCTAssertFalse(build.systemInstructions.contains(Self.canonicalDescription))
        XCTAssertFalse(build.nativeToolSchemas.contains { $0.name == CadDocumentTool.name })
        XCTAssertLessThanOrEqual(build.estimatedPromptTokens, build.windowPromptTokenBudget)
        XCTAssertFalse(build.exceedsContextWindow)
    }

    func testLongToolResultKeepsCompleteEvidenceOrAPagingPointer() {
        let tools = [searchDescriptor(), cadDescriptor(), readDescriptor()]
        // Long enough to exercise the real result channel, still leaving the
        // canonical CAD definition admitted at 16K. If the estimator clips,
        // the retained-output pointer must be present; if it fits, the tail
        // must survive. Either outcome keeps the evidence contract truthful.
        let longOutput = "ref=tr_x34replay " + String(repeating: "R", count: 20_000) + "\nTAIL_SENTINEL"
        let build = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: localModel(
                "gemma4-e4b-mlx4",
                contextTokens: 16_384,
                maxOutputTokens: 1_536
            ),
            messages: [("user", "修改支架孔径并把测量结果附上。")],
            toolResults: [("cad-call", longOutput)],
            toolSchemas: tools,
            allToolNames: tools.map(\.name)
        ))
        XCTAssertTrue(build.selectedTools.contains { $0.name == CadDocumentTool.name })
        XCTAssertTrue(build.text.contains("TOOL RESULT cad-call"))
        XCTAssertTrue(
            build.text.contains("TAIL_SENTINEL") || build.text.contains("tools.readResult"),
            "the long result was neither complete nor given a paging pointer"
        )
        if !build.text.contains("TAIL_SENTINEL") {
            XCTAssertTrue(build.text.contains("ref=tr_x34replay"))
            XCTAssertTrue(build.text.contains("tools.readResult"))
        }
        XCTAssertLessThanOrEqual(build.estimatedPromptTokens, build.windowPromptTokenBudget)
        XCTAssertFalse(build.exceedsContextWindow)
    }

    func testTextOnlyLocalModelStillRejectsAnImageBeforeLoad() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("x34r2-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelStore(root: root)
        let runtime = LocalModelRuntime(store: store)
        let adapter = LocalProviderAdapter(runtime: runtime, store: store)
        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: localModel(
                "qwen3.8-4b-heretic-mlx4",
                contextTokens: 8_192,
                maxOutputTokens: 1_024
            ),
            contentMessages: [
                ProviderMessage(role: "user", content: [
                    .text("描述这张图并创建 CAD 模型。"),
                    .imageData(
                        mimeType: "image/png",
                        base64: Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
                    ),
                ]),
            ],
            toolSchemas: [cadDescriptor()],
            allToolNames: [CadDocumentTool.name]
        )
        var caught: Error?
        do {
            for try await _ in adapter.stream(
                request: request,
                credentials: ProviderCredentials()
            ) {}
        } catch {
            caught = error
        }
        let error = try XCTUnwrap(caught, "a text-only local model must reject image input")
        guard case FloeError.validationFailed = error else {
            return XCTFail("unexpected image refusal: \(error)")
        }
        let state = await runtime.currentLoadState()
        guard case .unloaded = state else {
            return XCTFail("the image was rejected only after model load began: \(state)")
        }
    }

    func testM07DatumPlaneDocumentationIsOnDemandNotInTheSchema() throws {
        let payloads = try XCTUnwrap(CadDocumentHelp.fullText(for: "payloads"))
        for action in [
            "datum.anglePlane.create", "datum.anglePlane.update", "datum.anglePlane.delete",
            "datum.threePointPlane.create", "datum.threePointPlane.update",
            "datum.threePointPlane.delete",
        ] {
            XCTAssertTrue(payloads.contains(action), "M07 help lost \(action)")
        }
        XCTAssertTrue(payloads.contains("expression (degrees)"))
        XCTAssertTrue(payloads.contains("exactly three distinct"))
        XCTAssertTrue(payloads.contains("no world coordinate is stored"))
        XCTAssertTrue(payloads.contains("endpointA|endpointB|center"))
        // The large canonical declaration is not restored: the concise schema
        // points at the on-demand guide and names no M07 action.
        XCTAssertFalse(CadDocumentTool.parametersJSON.contains("datum.anglePlane.create"))
        XCTAssertFalse(CadDocumentTool.parametersJSON.contains("datum.threePointPlane.create"))
        XCTAssertTrue(CadDocumentTool.parametersJSON.contains("documentation topic payloads"))
    }

    func testCanonicalSchemaFlowsThroughTheLocalReplyParserAndReplayedHistory() throws {
        let call = try XCTUnwrap(LocalProviderAdapter.toolCall(
            from: #"{"tool_call":{"name":"cad.document","arguments":{"action":"read","path":"part.floecad"}}}"#,
            offeredToolNames: [CadDocumentTool.name]
        ))
        XCTAssertEqual(call.toolName, CadDocumentTool.name)
        let arguments = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any]
        )
        XCTAssertEqual(arguments["action"] as? String, "read")
        XCTAssertEqual(arguments["path"] as? String, "part.floecad")

        let settledCall = try ToolCall(
            id: "cad-settled",
            toolName: CadDocumentTool.name,
            argumentsJSON: Data(#"{"action":"read","path":"part.floecad"}"#.utf8),
            scope: .local
        )
        let settledResult = ToolResult(
            callID: settledCall.id,
            status: .ok,
            outputSummary: #"{"ok":true,"revision":4}"#,
            outputDigest: FloeDigest.sha256Hex(Data(#"{"ok":true,"revision":4}"#.utf8))
        )
        let tools = [searchDescriptor(), cadDescriptor(), readDescriptor()]
        let build = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: localModel(
                "qwen3.8-4b-heretic-mlx4",
                contextTokens: 12_288,
                maxOutputTokens: 1_536
            ),
            messages: [("user", "接着读取支架的孔径。")],
            replayedToolPairs: [ReplayedToolPair(call: settledCall, result: settledResult)],
            toolSchemas: tools,
            allToolNames: tools.map(\.name)
        ))
        XCTAssertTrue(build.selectedTools.contains { $0.name == CadDocumentTool.name })
        XCTAssertTrue(build.text.contains("EARLIER TOOL CALL cad.document id=cad-settled"))
        XCTAssertTrue(build.text.contains("EARLIER TOOL RESULT id=cad-settled"))
    }

    // MARK: - Foundation receives the authorized set through the generic bridge

    func testFoundationReceivesTaskAuthorizedToolsAndBridgesCanonicalSchema() async throws {
        let names: Set<String> = [
            "cad.document", "apple.location.current", "workspace.readFile",
            "ssh.execute", "notes.edit",
        ]
        XCTAssertEqual(
            LocalProviderAdapter.admissibleToolNames(
                from: names,
                modelRemoteID: AppleFoundationModelIdentity.remoteModelID
            ),
            names
        )
        let appleTool = ToolSchemaDescriptor(
            name: "apple.location.current",
            description: "Read the current location."
        )
        let offer = [
            cadDescriptor(), appleTool, readDescriptor(),
            ToolSchemaDescriptor(name: "ssh.execute", description: "Run a remote command"),
        ]
        XCTAssertEqual(
            LocalProviderAdapter.admissibleTools(
                offer,
                modelRemoteID: AppleFoundationModelIdentity.remoteModelID
            ).map(\.name),
            offer.map(\.name)
        )

        let build = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: localModel(
                AppleFoundationModelIdentity.remoteModelID,
                contextTokens: 16_384,
                maxOutputTokens: 1_536
            ),
            messages: [("user", "用 cad.document 读取支架的孔径，再调用 ssh.execute 查看主机。")],
            toolSchemas: offer,
            allToolNames: offer.map(\.name)
        ))
        XCTAssertTrue(build.selectedTools.contains { $0.name == CadDocumentTool.name })
        XCTAssertTrue(build.selectedTools.contains { $0.name == "ssh.execute" })
        XCTAssertEqual(
            Set(build.fallbackTools.map(\.name)),
            Set(offer.map(\.name))
        )
        XCTAssertTrue(build.nativeToolSchemas.isEmpty)
        XCTAssertTrue(build.systemInstructions.contains("native Foundation Models"))
        XCTAssertTrue(build.systemInstructions.contains("cad.document"))

        #if compiler(>=6.4) && canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, *) {
            // Pure SDK bridge coverage: no model session, no inference and no
            // fabricated answer. The same descriptor a provider would carry is
            // converted into a generic Foundation Models tool; calling that
            // tool only records the deferred call for the ordinary runtime.
            let recorder = DeferredToolCallRecorder()
            let bridged = try XCTUnwrap(
                AppleFoundationModelRuntime.deferredTool(
                    from: cadDescriptor(),
                    recorder: recorder
                )
            )
            let deferred = try XCTUnwrap(bridged as? DeferredFloeTool)
            XCTAssertEqual(deferred.name, CadDocumentTool.name)
            XCTAssertEqual(deferred.description, CadDocumentTool.toolDescription)
            let generated = try GeneratedContent(
                json: #"{"action":"read","path":"part.floecad"}"#
            )
            let sentinel = try await deferred.call(arguments: generated)
            XCTAssertEqual(sentinel, "PENDING_EXTERNAL_EXECUTION")
            let recordedCall = try await recorder.toolCall()
            let call = try XCTUnwrap(recordedCall)
            XCTAssertEqual(call.toolName, CadDocumentTool.name)
            let arguments = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any]
            )
            XCTAssertEqual(arguments["action"] as? String, "read")
            XCTAssertEqual(arguments["path"] as? String, "part.floecad")
        } else {
            throw XCTSkip("Foundation Models 27 SDK is not available on this host; actual inference is a separate gate.")
        }
        #else
        throw XCTSkip("The current toolchain does not compile the Foundation Models bridge; actual inference is a separate gate.")
        #endif
    }

    func testAppleProfileNeverAdvertisesVisionAndTemporaryScopeStaysReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("x34r2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelStore(root: root)
        let runtime = LocalModelRuntime(store: store)
        let adapter = LocalProviderAdapter(runtime: runtime, store: store)
        let models = try await adapter.listModels(
            provider: LocalProviderAdapter.providerProfile,
            credentials: ProviderCredentials()
        )
        let apple = try XCTUnwrap(
            models.first { $0.remoteModelID == AppleFoundationModelIdentity.remoteModelID }
        )
        XCTAssertTrue(apple.capabilities.contains(.text))
        XCTAssertFalse(
            apple.capabilities.contains(.vision),
            "Floe never sends user images to the system model; no vision capability may appear."
        )

        // Static help is readable under the temporary outer scope, but the
        // existing mutation refusal is untouched.
        let tool = CadDocumentTool(host: HelpOnlyHost(authorize: true))
        let context = ToolContext(
            runID: UUID(),
            scope: .local,
            cancellation: CancellationToken(),
            temporaryReadOnly: true
        )
        let help = try await executeHelp(tool, context: context, [
            "documentation": "limitations",
        ])
        XCTAssertNotNil(help["documentation"])
        let mutation = try decodeArgs([
            "action": "material",
            "path": "part.floecad",
            "payload": #"{"action":"remove"}"#,
        ])
        try tool.validate(mutation)
        do {
            _ = try await tool.execute(mutation, context: context)
            XCTFail("temporary chat must keep refusing CAD mutations")
        } catch let error as FloeError {
            guard case .unauthorized = error else {
                return XCTFail("unexpected temporary CAD refusal: \(error)")
            }
        }
    }

    func testAppleCopyAndSettingsBadgeDoNotClaimUnsupportedCapabilities() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FloeAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // FloeAgent package root

        let catalogURL = packageRoot.appendingPathComponent(
            "FloeApp/Resources/Localizable.xcstrings"
        )
        let viewURL = packageRoot.appendingPathComponent(
            "FloeApp/Settings/LocalModelsSettingsView.swift"
        )
        guard FileManager.default.isReadableFile(atPath: catalogURL.path),
              FileManager.default.isReadableFile(atPath: viewURL.path) else {
            throw XCTSkip(
                "source catalog/view are not readable in this test host; the UI-copy source check remains a Root host review"
            )
        }
        let catalog = try object(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)))
        let strings = try object(catalog["strings"])
        let appleEntry = try object(strings["composer.local.confirm.message.apple"])
        let localizations = try object(appleEntry["localizations"])
        let en = try object(try object(localizations["en"])["stringUnit"])
        let zh = try object(try object(localizations["zh-Hans"])["stringUnit"])
        let english = try XCTUnwrap(en["value"] as? String)
        let chinese = try XCTUnwrap(zh["value"] as? String)
        XCTAssertTrue(english.contains("Floe offers the tools"))
        XCTAssertFalse(english.contains("unavailable with this model"))
        XCTAssertTrue(chinese.contains("工具"))
        XCTAssertFalse(chinese.contains("不能使用"))

        // The Apple settings row must not show the OS-native vision badge:
        // Floe never sends a user image directly to Foundation Models.
        let view = try String(contentsOf: viewURL, encoding: .utf8)
        let start = try XCTUnwrap(view.range(of: "private var appleFoundationModelSection"))
        let end = try XCTUnwrap(view.range(of: "private var appleFoundationModelStatusRow"))
        let appleSection = String(view[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(appleSection.contains("localmodels.vision"))
        XCTAssertFalse(appleSection.contains("if vision"))
    }

    func testExplicitSavedVisionCannotAddAVisionClaimToAppleIntent() throws {
        let provider = LocalProviderAdapter.providerProfile
        let id = UUID()
        let existing = ModelProfile(
            id: id,
            providerID: provider.id,
            remoteModelID: AppleFoundationModelIdentity.remoteModelID,
            displayName: "Apple Foundation Model",
            limits: .init(contextTokens: 4_096, maxOutputTokens: 512),
            capabilities: [.text, .tools],
            explicitCapabilities: [.vision]
        )
        let discovered = ModelProfile(
            id: id,
            providerID: provider.id,
            remoteModelID: AppleFoundationModelIdentity.remoteModelID,
            displayName: "Apple Foundation Model",
            limits: .init(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: [.text, .tools, .vision]
        )
        let merged = ModelCatalogMerger.merge(existing: [existing], discovered: [discovered])
        let row = try XCTUnwrap(merged.first)
        XCTAssertFalse(row.capabilities.contains(.vision))
        XCTAssertTrue(row.capabilities.contains(.tools))
    }

    // MARK: - Helpers

    private func decodeArgs(_ object: [String: Any]) throws -> CadDocumentArguments {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(CadDocumentArguments.self, from: data)
    }

    private func helpArguments(
        _ selector: [String: Any]
    ) throws -> CadDocumentArguments {
        let payloadData = try JSONSerialization.data(
            withJSONObject: selector,
            options: [.sortedKeys]
        )
        return try decodeArgs([
            "action": "capabilities",
            "payload": String(decoding: payloadData, as: UTF8.self),
        ])
    }

    private func executeHelp(
        _ tool: CadDocumentTool,
        context: ToolContext,
        _ selector: [String: Any]
    ) async throws -> [String: Any] {
        let args = try helpArguments(selector)
        try tool.validate(args)
        let output = try await tool.execute(args, context: context)
        let text = try XCTUnwrap(output.capturedOutput)
        let prefix = "cad.document help: "
        XCTAssertTrue(text.hasPrefix(prefix))
        let json = String(text.dropFirst(prefix.count))
        return try object(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    /// The same validate → execute path as `executeHelp`, but the selector must
    /// fail closed with a typed field error before any help page is served.
    private func assertHelpRefused(
        _ tool: CadDocumentTool,
        context: ToolContext,
        _ selector: [String: Any],
        field: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let args = try helpArguments(selector)
        do {
            try tool.validate(args)
            _ = try await tool.execute(args, context: context)
            XCTFail(
                "documentation \(field) accepted a non-integer value",
                file: file,
                line: line
            )
        } catch let error as FloeError {
            guard case .validationFailed(let message) = error else {
                return XCTFail(
                    "unexpected documentation \(field) error: \(error)",
                    file: file,
                    line: line
                )
            }
            XCTAssertTrue(
                message.contains("documentation \(field) must be an integer"),
                message,
                file: file,
                line: line
            )
        }
    }
}

/// A host that must never be reached by static help. Only `authorizeAccess`
/// returns so the temporary-scope mutation test reaches the tool's own outer
/// refusal; every data operation fails the test by throwing.
private struct HelpOnlyHost: CadDocumentHost {
    /// Static help must never call the host. The temporary-scope mutation test
    /// opts in only so the tool's own outer refusal can be reached.
    var authorize: Bool = false

    private func unused(_ operation: String) -> FloeError {
        FloeError.notFound("help-only host must not be reached (\(operation))")
    }

    func authorizeAccess(access: CadDocumentAccess) async throws {
        guard authorize else { throw unused("authorizeAccess") }
    }

    func capabilities(access: CadDocumentAccess) async throws -> String {
        throw unused("capabilities")
    }

    func snapshot(documentID: String, access: CadDocumentAccess) async throws -> CadDocumentSnapshot {
        throw unused("snapshot")
    }

    func query(documentID: String, requestJSON: String, access: CadDocumentAccess) async throws -> String {
        throw unused("query")
    }

    func prepareProposal(
        documentID: String,
        snapshot: CadDocumentSnapshot,
        summary: String,
        operationsJSON: String,
        access: CadDocumentAccess
    ) async throws -> CadProposal {
        throw unused("prepareProposal")
    }

    func storeProposal(_ proposal: CadProposal) async throws {
        throw unused("storeProposal")
    }

    func loadProposal(id: UUID, access: CadDocumentAccess) async throws -> CadProposal? {
        throw unused("loadProposal")
    }

    func loadProposalOutcome(id: UUID, access: CadDocumentAccess) async throws -> CadProposalOutcome? {
        throw unused("loadProposalOutcome")
    }

    func verifyProposalBinding(
        _ proposal: CadProposal,
        documentID: String,
        access: CadDocumentAccess
    ) async throws {
        throw unused("verifyProposalBinding")
    }

    func removeProposal(id: UUID) async throws {
        throw unused("removeProposal")
    }

    func consumeGrant(
        grantID: String,
        proposalID: UUID,
        documentID: String,
        revision: Int64,
        sha256: String
    ) async -> CadGrantDecision {
        .unknownGrant
    }

    func apply(
        proposal: CadProposal,
        grantID: String,
        requestID: String,
        access: CadDocumentAccess
    ) async throws -> CadDocumentReceipt {
        throw unused("apply")
    }

    func save(
        documentID: String,
        expectedSHA256: String,
        requestID: String,
        access: CadDocumentAccess
    ) async throws -> CadDocumentReceipt {
        throw unused("save")
    }

    func export(
        documentID: String,
        relativeOutput: String,
        access: CadDocumentAccess
    ) async throws -> CadExportReceipt {
        throw unused("export")
    }
}
