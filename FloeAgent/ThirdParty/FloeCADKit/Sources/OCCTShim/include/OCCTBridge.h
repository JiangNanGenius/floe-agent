//
//  OCCTBridge.h
//  openshape3d — OCCT B-rep port, Milestone 0 (spike)
//
//  Narrow Obj-C facade over OpenCASCADE. Swift links ONLY against this header,
//  never OCCT's C++ headers — keeping the template-heavy kernel behind a stable
//  C/Obj-C surface (see docs/OCCT_BREP_PORT_DESIGN.md). This M0 surface exists
//  only to prove the toolchain: mesh a box, and confirm an extruded circle
//  becomes ONE analytic cylindrical face (the fix for the 48-gon-prism bug).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Result of tessellating a B-rep solid into a triangle mesh.
@interface OCCTMeshResult : NSObject
@property (nonatomic, readonly) NSInteger triangleCount;
@property (nonatomic, readonly) NSInteger vertexCount;
/// Exact solid volume from `BRepGProp` (mm³), independent of tessellation.
@property (nonatomic, readonly) double volume;
@end

/// Count of faces by analytic surface type on a solid.
@interface OCCTFaceTypeCounts : NSObject
@property (nonatomic, readonly) NSInteger planar;
@property (nonatomic, readonly) NSInteger cylindrical;
@property (nonatomic, readonly) NSInteger other;
@end

/// A tessellated triangle mesh with SMOOTH per-vertex normals evaluated from the
/// analytic surface (not per-facet). Buffers are tightly packed:
///   positions/normals: `vertexCount` × 3 floats (x,y,z), plane-local
///   indices:           `triangleCount` × 3 uint32
@interface OCCTRenderMesh : NSObject
@property (nonatomic, readonly) NSInteger vertexCount;
@property (nonatomic, readonly) NSInteger triangleCount;
@property (nonatomic, readonly) NSData *positions;  // float32 x 3 x vertexCount
@property (nonatomic, readonly) NSData *normals;    // float32 x 3 x vertexCount
@property (nonatomic, readonly) NSData *indices;    // uint32  x 3 x triangleCount
/// One uint32 PER TRIANGLE: the 1-based index of the OCCT face that triangle
/// tessellates, into `TopExp::MapShapes(shape, TopAbs_FACE)` — the same
/// numbering the health report's "Face3" uses. 0 = unknown. This is the
/// bridge between mesh-derived face groups and kernel-history element naming
/// (docs/TOPO_NAMING_HISTORY_DESIGN.md step 1): a mesh face claims an OCCT
/// face by majority vote over its triangles' entries here.
@property (nonatomic, readonly) NSData *faceIndices;
@end

/// Opaque handle to a world-space OCCT solid (`TopoDS_Shape`). Reference type;
/// the underlying B-rep is freed on dealloc and is immutable after creation, so
/// it is safe to pass across the kernel/render boundary.
@interface OCCTShape : NSObject
@end

/// Why a kernel op ended the way it did. Every mutating op used to collapse
/// all of its failure modes into one nil — "no edge matched the pick", "the
/// radius is too big for the geometry", "OCCT built half of what you asked
/// and we threw it away" all looked identical, so the UI could only guess at
/// a message. Callers allocate one of these, pass it in, and read it back;
/// nil is accepted everywhere for callers that don't care.
typedef NS_ENUM(NSInteger, OCCTOpCode) {
    OCCTOpCodeOK = 0,
    /// No edge/face lay within tolerance of the picked points (or none of the
    /// matched ones was usable — `detail` says which).
    OCCTOpCodeNoTargetMatched = 1,
    /// The op succeeded on some targets and failed on others. The partial
    /// shape is DISCARDED — `failedCount` of `requestedCount` failed.
    OCCTOpCodePartialResult = 2,
    /// The op reported success but its result failed `BRepCheck_Analyzer`
    /// even after one healing attempt, or flunked a sanity check.
    OCCTOpCodeInvalidResult = 3,
    /// The op succeeded but produced `solidCount` (> 1) disjoint solids.
    /// The shape IS returned; callers decide whether that's acceptable.
    OCCTOpCodeMultiSolid = 4,
    /// The kernel declined the inputs or threw before producing a result.
    OCCTOpCodeKernelRefused = 5,
};

@interface OCCTOpStatus : NSObject
@property (nonatomic) OCCTOpCode code;
/// Short machine-ish diagnostic ("2 of 6 edges failed to blend"). Input for
/// building a user-facing message, not the message itself.
@property (nonatomic, copy, nullable) NSString *detail;
@property (nonatomic) NSInteger failedCount;
@property (nonatomic) NSInteger requestedCount;
@property (nonatomic) NSInteger solidCount;
@end

/// Kernel-history ancestry of an op result (docs/TOPO_NAMING_HISTORY_DESIGN.md
/// step 1): which input sub-shape each result FACE came from, from OCCT's own
/// Modified()/Generated() history — never geometric resemblance. Caller
/// allocates and passes in, like `OCCTOpStatus`; the bridge fills it.
///
/// `rows` is packed int32s, 5 per row:
///   resultFaceIndex, inputOrdinal, inputKind, inputSubshapeIndex, relation
/// `resultFaceIndex` is 1-based into the RESULT's indexed face map — the same
/// numbering the render mesh's `faceIndices` channel and the health report
/// use. `inputSubshapeIndex` is 1-based into input `inputOrdinal`'s indexed
/// map of `inputKind` (0 = face, 1 = edge), over the operand AS THE KERNEL
/// CONSUMED IT (after any operand heal). `relation`: 0 = the input face
/// survives untouched, 1 = modified, 2 = generated.
///
/// Every row is validated against the final shape before it is emitted —
/// OCCT history can report phantoms that never reach the result (measured in
/// FreeCAD's revolve), and a wrong ancestor is worse than a missing one. So
/// a face with NO rows means "history doesn't know"; consumers fall back to
/// signature matching, which stays mandatory.
@interface OCCTShapeHistory : NSObject
@property (nonatomic) NSInteger rowCount;
@property (nonatomic, copy) NSData *rows;  // int32 x 5 x rowCount
/// A post-history heal rebuilt the result. Surviving rows are still valid
/// (each was checked against the FINAL shape), but coverage may have holes.
@property (nonatomic) BOOL truncatedByHeal;
@end

/// Orthonormal sketch-plane basis: world = origin + xAxis·x + yAxis·y + normal·z.
@interface OCCTPlaneBasis : NSObject
- (instancetype)initWithOriginX:(double)ox originY:(double)oy originZ:(double)oz
                         xAxisX:(double)xx xAxisY:(double)xy xAxisZ:(double)xz
                         yAxisX:(double)yx yAxisY:(double)yy yAxisZ:(double)yz
                        normalX:(double)nx normalY:(double)ny normalZ:(double)nz;
@end

@interface OCCTBridge : NSObject

/// OCCT version string (e.g. "7.8.1") — proves the library linked and runs.
+ (NSString *)occtVersion;

/// Build a box of the given edge length, tessellate it, and report triangle
/// count + exact volume. Volume should be size³.
+ (OCCTMeshResult *)meshBoxWithSize:(double)size;

/// Build a circle (radius `r`) on the XY plane, make a planar face, and extrude
/// it `height` along +Z into a solid. Returns the analytic face-type histogram:
/// a true cylinder is 2 planar caps + 1 cylindrical side + 0 other — the direct
/// proof the kernel keeps circles analytic instead of faceting them.
+ (OCCTFaceTypeCounts *)extrudeCircleFaceCountsWithRadius:(double)r
                                                   height:(double)height;

/// Build a true cylinder (analytic B-rep) centered at (`cx`,`cy`) in plane-local
/// space, spanning z ∈ [`zMin`,`zMax`], and tessellate it with SMOOTH normals.
/// `angularDeflection` (radians) controls how many facets wrap the circle
/// (smaller = rounder); `linearDeflection` bounds chord error. Returns a mesh in
/// plane-local coordinates — the caller maps it to world with the sketch-plane
/// basis. This is what makes an extruded circle render round.
+ (OCCTRenderMesh *)cylinderRenderMeshWithCenterX:(double)cx
                                          centerY:(double)cy
                                           radius:(double)r
                                             zMin:(double)zMin
                                             zMax:(double)zMax
                                 angularDeflection:(double)angularDeflection
                                  linearDeflection:(double)linearDeflection;

// MARK: - B-rep source of truth (extrude → boolean → render)

/// Build a world-space extruded solid from a closed profile. `outerLoop` is
/// packed doubles (x,y pairs) in plane-local coords; if `isCircle` an ANALYTIC
/// circle edge is used instead (→ a true cylinder). `holes` are inner boundary
/// loops (packed doubles). The solid spans plane-local z ∈ [`zMin`,`zMax`], then
/// is mapped to world by `basis`. Returns nil if the profile is degenerate.
/// `holeCircles`, when present, is 3 doubles PER HOLE (centre x, centre y,
/// radius) parallel to `holes`; a radius <= 0 means "not a circle, use the
/// polyline". A hole that IS a circle becomes an analytic cylindrical wall
/// instead of the tessellation it was drawn with — without this a plate with a
/// Ø8 hole comes back with a 64-sided bore that only looks round.
/// `outerConic` / `holeConics` describe a boundary that is one exact curve:
/// 5 packed doubles — `cx, cy, rx, ry, rotation` — where `rx`/`ry` are the
/// semi-axes in either order and a non-positive `rx` means "no conic here".
/// Equal semi-axes build a `gp_Circ`, unequal a `gp_Elips`. `holeConics` is
/// one such entry per hole, parallel to `holes`.
///
/// `outerSegments` / `holeSegments` describe a boundary EXACTLY, for loops
/// that contain an arc: 7 packed doubles per edge —
/// `isArc, x1, y1, x2, y2, midX, midY` — where `isArc` > 0.5 means a circular
/// arc from (x1,y1) to (x2,y2) passing through (midX,midY), and anything else
/// is a straight line (the mid pair is then ignored). Nil or empty falls back
/// to the polyline, which is already exact for an all-straight loop. A conic
/// wins over both, and every fallback is per-wire: one unusable boundary uses
/// its polyline without affecting the others.
+ (nullable OCCTShape *)extrudedShapeWithOuterLoop:(NSData *)outerLoop
                                        outerConic:(nullable NSData *)outerConic
                                             holes:(NSArray<NSData *> *)holes
                                        holeConics:(nullable NSData *)holeConics
                                     outerSegments:(nullable NSData *)outerSegments
                                      holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                              zMin:(double)zMin
                                              zMax:(double)zMax
                                             basis:(OCCTPlaneBasis *)basis;

/// `extrudedShapeWithOuterLoop:` that also reports per-face ancestry.
/// Identical result for identical inputs — `history` is fill-only.
///
/// Extrude row convention (documented here because the packed format is
/// shared with the boolean): `inputOrdinal` is the LOOP — 0 = outer,
/// 1…N = holes in argument order. Wall faces: `inputKind` 1 (edge),
/// `inputSubshapeIndex` = 1-based edge ordinal within that loop's wire in
/// construction order (polyline point-pair order / segment order / 1 for a
/// conic), relation 2 (generated). Cap faces: `inputOrdinal` 0, `inputKind`
/// 0 (face), `inputSubshapeIndex` 1 = start cap (at zMin) and 2 = end cap,
/// relation 1 (the profile face's own images). Composed across the
/// plane-local → world transform hop; every row validated against the final
/// shape.
+ (nullable OCCTShape *)extrudedShapeWithOuterLoop:(NSData *)outerLoop
                                        outerConic:(nullable NSData *)outerConic
                                             holes:(NSArray<NSData *> *)holes
                                        holeConics:(nullable NSData *)holeConics
                                     outerSegments:(nullable NSData *)outerSegments
                                      holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                              zMin:(double)zMin
                                              zMax:(double)zMax
                                             basis:(OCCTPlaneBasis *)basis
                                           history:(nullable OCCTShapeHistory *)history;

/// Revolve a profile about a WORLD-space axis.
///
/// Profile arguments match `extrudedShapeWithOuterLoop:` exactly and are built
/// into the same face, so a circle revolves as a torus rather than as a
/// 48-sided approximation of one. `axis` is 6 packed doubles — origin xyz then
/// direction xyz. `angle` is radians; a full turn is 2π.
+ (nullable OCCTShape *)revolvedShapeWithOuterLoop:(NSData *)outerLoop
                                        outerConic:(nullable NSData *)outerConic
                                             holes:(NSArray<NSData *> *)holes
                                        holeConics:(nullable NSData *)holeConics
                                     outerSegments:(nullable NSData *)outerSegments
                                      holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                             basis:(OCCTPlaneBasis *)basis
                                              axis:(NSData *)axis
                                             angle:(double)angle;

/// Revolve/sweep with ancestry (fill-only `history`, same extrude row
/// convention: walls Generated per wire edge, caps = the profile face's
/// start/end images — a full revolve has none, which the in-result gate
/// handles for free).
+ (nullable OCCTShape *)revolvedShapeWithOuterLoop:(NSData *)outerLoop
                                        outerConic:(nullable NSData *)outerConic
                                             holes:(NSArray<NSData *> *)holes
                                        holeConics:(nullable NSData *)holeConics
                                     outerSegments:(nullable NSData *)outerSegments
                                      holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                             basis:(OCCTPlaneBasis *)basis
                                              axis:(NSData *)axis
                                             angle:(double)angle
                                           history:(nullable OCCTShapeHistory *)history;
+ (nullable OCCTShape *)sweptShapeWithOuterLoop:(NSData *)outerLoop
                                     outerConic:(nullable NSData *)outerConic
                                          holes:(NSArray<NSData *> *)holes
                                     holeConics:(nullable NSData *)holeConics
                                  outerSegments:(nullable NSData *)outerSegments
                                   holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                          basis:(OCCTPlaneBasis *)basis
                                          spine:(NSData *)spine
                                          helix:(nullable NSData *)helix
                                        history:(nullable OCCTShapeHistory *)history;

/// Loft through ordered section profiles, each on its own plane.
///
/// `sections` is one dictionary-free parallel set of arrays: every index i
/// describes one section exactly as the extrude arguments describe a profile.
/// Holes are not supported here (OCCT's ThruSections takes one wire per
/// section); a section's inner loops are ignored, which the caller must know.
+ (nullable OCCTShape *)loftedShapeWithOuterLoops:(NSArray<NSData *> *)outerLoops
                                      outerConics:(NSArray<NSData *> *)outerConics
                                    outerSegments:(NSArray<NSData *> *)outerSegments
                                           bases:(NSArray<OCCTPlaneBasis *> *)bases;

+ (nullable OCCTShape *)loftedShapeWithOuterLoops:(NSArray<NSData *> *)outerLoops
                                      outerConics:(NSArray<NSData *> *)outerConics
                                    outerSegments:(NSArray<NSData *> *)outerSegments
                                           bases:(NSArray<OCCTPlaneBasis *> *)bases
                                          history:(nullable OCCTShapeHistory *)history;

/// `ruled`: straight bands between consecutive sections (a three-section
/// symmetric draft is then exactly two frustums back to back) instead of
/// ThruSections' smooth surface through all of them, which bulges past the
/// middle section — 6.5 % of volume on a 5° symmetric draft (2026-09-02).
/// The history then names the walls of EVERY band from its section's edges.
+ (nullable OCCTShape *)loftedShapeWithOuterLoops:(NSArray<NSData *> *)outerLoops
                                      outerConics:(NSArray<NSData *> *)outerConics
                                    outerSegments:(NSArray<NSData *> *)outerSegments
                                           bases:(NSArray<OCCTPlaneBasis *> *)bases
                                            ruled:(BOOL)ruled
                                          history:(nullable OCCTShapeHistory *)history;

/// Sweep a profile along a polyline spine.
///
/// `spine` is 3 doubles per point in WORLD space. The profile is built on its
/// own plane and swept with `BRepOffsetAPI_MakePipe`.
+ (nullable OCCTShape *)sweptShapeWithOuterLoop:(NSData *)outerLoop
                                     outerConic:(nullable NSData *)outerConic
                                          holes:(NSArray<NSData *> *)holes
                                     holeConics:(nullable NSData *)holeConics
                                  outerSegments:(nullable NSData *)outerSegments
                                   holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                          basis:(OCCTPlaneBasis *)basis
                                          spine:(NSData *)spine;

/// Build a primitive matching Euclid's conventions exactly (base sits on y=0;
/// cylinder axis is +Y), so the B-rep coincides with the Euclid CSG mesh.
/// `kind`: 0 = box (a=width, b=depth, c=height), 1 = cylinder (a=radius,
/// b=height), 2 = sphere (a=radius). `transform` is 12 packed doubles
/// (row-major 3×4 placement) or nil for identity.
+ (nullable OCCTShape *)primitiveShapeOfKind:(NSInteger)kind
                                           a:(double)a
                                           b:(double)b
                                           c:(double)c
                                   transform:(nullable NSData *)transform;

/// Apply a rigid placement to a solid. `transform` is 12 packed doubles
/// (row-major 3×4). Needed because a `Body` carries its own transform, which
/// must be baked in before two solids can be booleaned in a common space.
/// Reflect a shape in the PLANE through `origin` with the given `normal`.
///
/// Separate from `transformedShape:` because a reflection cannot be expressed
/// as a `Transform3D` at all — that type is translation + a rotation
/// quaternion + a single uniform scale, and a plane mirror is none of those
/// (a negative uniform scale is a POINT reflection, which is a different
/// transform). `gp_Trsf::SetMirror(gp_Ax2)` does it properly.
+ (nullable OCCTShape *)mirroredShape:(OCCTShape *)shape
                              originX:(double)ox
                              originY:(double)oy
                              originZ:(double)oz
                              normalX:(double)nx
                              normalY:(double)ny
                              normalZ:(double)nz;

+ (nullable OCCTShape *)transformedShape:(OCCTShape *)shape
                                  matrix:(NSData *)transform;

/// Merge faces that lie on the SAME underlying surface, and the edges between
/// them. A fuse of two solids meeting on a shared plane leaves both original
/// faces plus the seam edge, so a box extended by a prism comes back with ten
/// planar faces instead of six — geometrically right, topologically wrong, and
/// the spurious edges are selectable and blendable. Nil on failure; callers
/// keep the un-unified solid, which is still valid.
+ (nullable OCCTShape *)unifiedShape:(OCCTShape *)shape;

/// Boolean of two world-space shapes. `op`: 0 = union (fuse), 1 = subtract
/// (cut a from ... i.e. a − b), 2 = intersect (common). Nil on failure.
///
/// Hardened per the FreeCAD boolean pattern (docs/FREECAD_PLAYBOOK.md B1):
/// both operands are validity-checked (with one healing attempt) before OCCT
/// sees them, the builder runs non-destructive with a fuzzy tolerance derived
/// from the operands' combined extent (retried once at 10×), and a
/// single-solid result is unwrapped from its compound, unified
/// (`ShapeUpgrade_UnifySameDomain`) and validated before it is returned — so
/// downstream shell/fillet receive in-contract input. A result of several
/// disjoint solids is returned as-is with `OCCTOpCodeMultiSolid` in `status`.
+ (nullable OCCTShape *)booleanOfShape:(OCCTShape *)a
                             withShape:(OCCTShape *)b
                                    op:(NSInteger)op
                                status:(nullable OCCTOpStatus *)status;

/// `booleanOfShape:` that also reports per-face ancestry. Identical result
/// for identical inputs — `history` is fill-only, composed across BOTH hops
/// of the pipeline: the boolean builder's own Modified()/Generated(), then
/// `ShapeUpgrade_UnifySameDomain::History()` for faces the seam merge
/// rewrote. Input ordinal 0 = `a` (target), 1 = `b` (tool).
+ (nullable OCCTShape *)booleanOfShape:(OCCTShape *)a
                             withShape:(OCCTShape *)b
                                    op:(NSInteger)op
                                status:(nullable OCCTOpStatus *)status
                               history:(nullable OCCTShapeHistory *)history;

/// Remove the faces nearest `worldPoints` and heal the result
/// (`BRepAlgoAPI_Defeaturing`) — spec §4.16 Delete Face. A face counts as picked
/// when a sample on it lies within `tolerance` of a point. Nil when nothing
/// matched or the solid couldn't be healed (OCCT refuses when removal would
/// leave an unclosable gap), so callers can report a recoverable failure —
/// `status` says which of those it was.
+ (nullable OCCTShape *)defeaturedShape:(OCCTShape *)shape
                                 atWorldPoints:(NSData *)worldPoints
                                     tolerance:(double)tolerance
                                        status:(nullable OCCTOpStatus *)status;

/// Analytic face-type histogram of any solid — the check that geometry stayed
/// exact through an operation (e.g. a filleted cylinder keeps ONE cylindrical
/// wall and gains a curved blend face).
+ (OCCTFaceTypeCounts *)faceTypeCountsOfShape:(OCCTShape *)shape;

/// The poles (x,y pairs) of the B-spline edge the kernel builds for a sketch
/// spline through `xy` (x,y pairs) — the cross-language pin for
/// `CatmullRomBezier` (docs/SPLINE_PROFILE_DESIGN.md): a Swift test compares
/// them pole for pole with the Swift conversion. Nil if the edge cannot be built.
+ (nullable NSData *)splineEdgePolesForPoints:(NSData *)xy closed:(BOOL)closed;

/// Round the edges that pass near `worldPoints` to `radius`
/// (`BRepFilletAPI_MakeFillet`). `worldPoints` is packed doubles (x,y,z triples)
/// — typically the midpoints of the mesh edges the user picked. An edge counts
/// as picked when any sample along it lies within `tolerance` of a point.
///
/// Because a tessellated rim is many mesh segments but ONE analytic edge, this
/// gives tangent-chain propagation for free: picking a single segment of a
/// cylinder's rim rounds the entire circular edge. Nil if nothing matched or
/// the blend failed — `status` distinguishes "no edge there", "radius too big
/// for N of M edges" (a partial build is DISCARDED, never returned) and "the
/// result didn't validate". Picked edges are pre-qualified first: degenerate
/// edges, seams, free edges and tangent-continuous edges are refused up front
/// (docs/FREECAD_PLAYBOOK.md F1/F2) instead of being handed to ChFi3d, which
/// crashes or silently no-ops on them.
+ (nullable OCCTShape *)filletedShape:(OCCTShape *)shape
                        atWorldPoints:(NSData *)worldPoints
                               radius:(double)radius
                            tolerance:(double)tolerance
                               status:(nullable OCCTOpStatus *)status;

/// Bevel the edges near `worldPoints` by `distance`
/// (`BRepFilletAPI_MakeChamfer`) — the chamfer half of spec §4.3. Same
/// edge-matching, pre-qualification, post-validation and tangent-chain
/// behaviour as `filletedShape:`.
+ (nullable OCCTShape *)chamferedShape:(OCCTShape *)shape
                        atWorldPoints:(NSData *)worldPoints
                             distance:(double)distance
                            tolerance:(double)tolerance
                                status:(nullable OCCTOpStatus *)status;

/// Hollow a solid to a wall of `thickness`, opening the faces near
/// `worldPoints` (`BRepOffsetAPI_MakeThickSolid`) — spec §4.4 Shell. Pass an
/// empty `worldPoints` for a fully-enclosed hollow. Correct on CURVED walls,
/// unlike the mesh inset approximation. Nil when OCCT can't offset the solid
/// (thickness out of the valid range) or the result fails validation/the
/// volume-must-shrink sanity check — `status` says which.
+ (nullable OCCTShape *)shelledShape:(OCCTShape *)shape
                       atWorldPoints:(NSData *)worldPoints
                           thickness:(double)thickness
                           tolerance:(double)tolerance
                              status:(nullable OCCTOpStatus *)status;

/// Exact face draft (`BRepOffsetAPI_DraftAngle`): every face with a sample
/// within `tolerance` of a picked point is tilted by `angleRadians` about its
/// intersection with the neutral plane, pulled along `direction` — a casting's
/// taper as an analytic solid, where the mesh path (`KernelOps.draftFace`)
/// only shears render polygons. A positive angle NARROWS the body away from
/// the neutral plane along the pull direction, the same sign the mesh path
/// uses. Nil when a face cannot take the draft or the result fails
/// validation — `status` says which.
+ (nullable OCCTShape *)draftedShape:(OCCTShape *)shape
                       atWorldPoints:(NSData *)worldPoints
                        angleRadians:(double)angleRadians
                          directionX:(double)dx directionY:(double)dy directionZ:(double)dz
                      neutralOriginX:(double)ox neutralOriginY:(double)oy neutralOriginZ:(double)oz
                      neutralNormalX:(double)nx neutralNormalY:(double)ny neutralNormalZ:(double)nz
                           tolerance:(double)tolerance
                              status:(nullable OCCTOpStatus *)status;

/// Identity-addressed blends (docs/TOPO_NAMING_HISTORY_DESIGN.md step 4b):
/// same pre-qualification, per-edge checks and validation as the
/// point-matched entries — the two share one implementation — but edges are
/// chosen by 1-based indexed-map position (the numbering
/// `edgeFaceAdjacencyOfShape:` reports) instead of nearest-to-a-point. An
/// out-of-range index fails the WHOLE op: identity addressing that silently
/// blended a subset would be worse than failing.
+ (nullable OCCTShape *)filletedShape:(OCCTShape *)shape
                          edgeIndices:(NSData *)edgeIndices
                               radius:(double)radius
                               status:(nullable OCCTOpStatus *)status
                              history:(nullable OCCTShapeHistory *)history;
+ (nullable OCCTShape *)chamferedShape:(OCCTShape *)shape
                           edgeIndices:(NSData *)edgeIndices
                              distance:(double)distance
                                status:(nullable OCCTOpStatus *)status
                               history:(nullable OCCTShapeHistory *)history;

/// Modifier-op ancestry (step 5): shell and delete-face with the same
/// fill-only `history` the boolean carries — untouched faces report `same`,
/// offset/healed faces `modified`, new faces `generated` — so these ops
/// stop erasing every name downstream. The closed-hollow shell branch
/// reports survival only (its inner faces stay honestly unnamed).
+ (nullable OCCTShape *)shelledShape:(OCCTShape *)shape
                       atWorldPoints:(NSData *)worldPoints
                           thickness:(double)thickness
                           tolerance:(double)tolerance
                              status:(nullable OCCTOpStatus *)status
                             history:(nullable OCCTShapeHistory *)history;
+ (nullable OCCTShape *)defeaturedShape:(OCCTShape *)shape
                          atWorldPoints:(NSData *)worldPoints
                              tolerance:(double)tolerance
                                 status:(nullable OCCTOpStatus *)status
                                history:(nullable OCCTShapeHistory *)history;

/// Per-kernel-face geometry, straight from the shape: packed doubles, 10
/// per face — `index, kindCode, normal xyz, centroid xyz, area, extra` —
/// in 1-based indexed-map order. `kindCode`: 0 planar (`extra` = plane
/// offset n·centroid), 1 cylindrical (`normal` = axis direction, `extra` =
/// radius), 2 other (`extra` = 0). Face-orientation is honoured, so a
/// planar normal points OUT of the solid. This is the identity source for
/// bodies whose RENDER is not the kernel tessellation (revolve/sweep/loft
/// assign their brep) — the mesh-table channel votes garbage against a
/// different tessellation, and /v1/faces served duplicate indices for a
/// revolved washer exactly that way (measured 2026-09-01).
+ (nullable NSData *)faceInfoOfShape:(OCCTShape *)shape;

/// The plane's intersection with the shape (`BRepAlgoAPI_Section`), as
/// packed doubles: per section edge `count, x1 y1 z1, … xN yN zN` in the
/// edge's own direction — a line as its two ends, any other curve sampled
/// at `deflection` (chord error, mm). `plane` is six doubles: origin then
/// normal. Pieces arrive unordered; chaining them into loops is the
/// caller's job (`SectionKit`). Nil on a null shape or a failed cut.
+ (nullable NSData *)sectionOfShape:(OCCTShape *)shape
                              plane:(NSData *)plane
                         deflection:(double)deflection;

/// Every edge with exactly two distinct adjacent faces, as packed int32
/// triples `(edgeIndex, faceA, faceB)` — 1-based indexed-map numbering
/// shared with the render mesh's face channel and the ancestry rows; the
/// pair is normalized `faceA < faceB`. Seams and border edges are omitted
/// on purpose: they carry no pair identity, and they are exactly the edges
/// the blend pre-qualifier vetoes anyway.
+ (nullable NSData *)edgeFaceAdjacencyOfShape:(OCCTShape *)shape;

/// The 1-based index of the edge nearest the world point (within
/// `tolerance`), 0 when none — the mint-time bridge from a picked mesh edge
/// to its kernel edge, using the same matching the point-based blends use.
+ (NSInteger)nearestEdgeIndexOfShape:(OCCTShape *)shape
                            toPointX:(double)x y:(double)y z:(double)z
                           tolerance:(double)tolerance;

/// Each edge's point halfway along its curve BY ARC LENGTH, as packed
/// doubles `x y z` per edge in the shared 1-based indexed-map order (entry
/// i−1 is edge i). NaN for an edge with no curve (degenerated) or whose
/// length cannot be computed. Independent of the edge's orientation; for a
/// closed edge (a full circle) it is measured from the curve's own first
/// parameter, so it is fixed by the shape. `/v1/edges` reports it, where a
/// tessellation segment's midpoint used to be whichever came first.
+ (nullable NSData *)edgeMidpointsOfShape:(OCCTShape *)shape;

/// The largest fillet radius the edges near `worldPoints` can actually
/// take, found by bisection over REAL (fully checked) `BRepFilletAPI`
/// builds — so the drag clamp and the commit agree by construction, unlike
/// the mesh heuristic it replaces (docs/FREECAD_PLAYBOOK.md F3). The
/// bracket starts at half the body diagonal, tightened by any cylindrical/
/// spherical neighbour's radius. Costs a handful of fillet builds — compute
/// once per drag, never per tick. 0 when nothing blendable is near the
/// points.
+ (double)maxFilletRadiusForShape:(OCCTShape *)shape
                    atWorldPoints:(NSData *)worldPoints
                        tolerance:(double)tolerance;

/// Exact solid volume (mm³) via `BRepGProp`; 0 on failure. Cheap enough for
/// sanity checks (a shell must REMOVE material) and exact enough for tests to
/// pin against analytically-derived values.
+ (double)volumeOfShape:(OCCTShape *)shape;

/// The largest tolerance any sub-shape of `shape` carries
/// (`ShapeAnalysis_ShapeTolerance`). Healthy analytic solids sit at
/// `Precision::Confusion()` (1e-7); a shape that has been through healing can
/// carry more, and pick tolerances should scale with THIS, not with the
/// body's bounding box (docs/FREECAD_PLAYBOOK.md T1).
+ (double)maxToleranceOfShape:(OCCTShape *)shape;

// MARK: - STEP interchange (spec §12.1 / §12.2)

/// Write `shapes` to a STEP AP214 file at `path`. Exports EXACT B-rep geometry
/// (analytic surfaces survive), unlike the mesh formats. NO on failure.
+ (BOOL)writeSTEPShapes:(NSArray<OCCTShape *> *)shapes toPath:(NSString *)path;

/// Read every solid from the STEP file at `path`. Empty array on failure — the
/// caller reports an unreadable/unsupported file rather than crashing.
+ (NSArray<OCCTShape *> *)readSTEPFromPath:(NSString *)path;

// MARK: - Geometry health + capture replay (docs/FREECAD_PLAYBOOK.md D1/D2)

/// Deep validity report over a shape — the "Check Geometry" pipeline every
/// mature OCCT consumer grows, re-derived from the OCCT documentation with
/// FreeCAD's checker as the worked example. Always cheap context first
/// (sub-shape counts, volume, min/avg/max tolerance, free boundary wires),
/// then `BRepCheck_Analyzer`: when the shape is INVALID, every sub-shape's
/// named statuses are collected — both the status a shape carries in itself
/// and the status it carries IN ITS PARENT (a wire can be fine alone and
/// self-intersecting in its face; OCCT stores those separately). Sub-shapes
/// are named `Face3`/`Edge17` — 1-based indices into the root's indexed map
/// of that type, the convention CAD checkers report in.
///
/// `runBOPCheck` additionally runs `BOPAlgo_ArgumentAnalyzer` (self-
/// intersection, small edges, continuity…) — only when the shape passed
/// `BRepCheck_Analyzer` (its findings are advisory and it is SLOW; FreeCAD
/// gates it the same way), under the kernel deadline so a pathological shape
/// can't hang the caller. Keys: `valid`, `findings` (subshape/type/status/
/// context?), `bopCheckRan`, `bopFindings`, `counts`, `tolerance`,
/// `volumeMM3`, `openFreeWires`, `closedFreeWires` — all JSON-safe.
+ (NSDictionary<NSString *, id> *)healthReportForShape:(OCCTShape *)shape
                                           runBOPCheck:(BOOL)runBOPCheck;

/// Raw deserialization for DIAGNOSTIC REPLAY ONLY. `shapeFromSerialized:`
/// heals-and-validates because stored blobs are a trust boundary — but a
/// capture replay must hand the op EXACTLY the bytes the failing op saw, or
/// it reproduces a different bug. Keeps only the guards that stop the suite
/// dying (read deadline, finite-bounds NaN gate); skips heal-and-validate.
+ (nullable OCCTShape *)rawShapeFromSerialized:(NSData *)data;

#if DEBUG
/// A deterministically INVALID solid — a box whose shell is missing one face
/// (`BRepCheck_NotClosed`) — so tests can exercise the health-report findings
/// path. No public op can build an invalid shape (they all validate), which
/// is exactly why this factory exists. DEBUG only.
+ (nullable OCCTShape *)debugInvalidOpenBoxWithSize:(double)size;
/// Turns off the boolean's fallback to its unmerged result (on by default),
/// so a test can reach the path behind it: the loosened-heal refusal. DEBUG
/// only.
+ (void)debugSetBooleanUnmergedFallbackEnabled:(BOOL)enabled;
#endif

/// Serialize a solid to OCCT's BRep text format, so the analytic geometry can be
/// stored in the document and survive a reload. Nil on failure.
+ (nullable NSData *)serializedShape:(OCCTShape *)shape;

/// Rebuild a solid from `serializedShape:` output. Nil on failure (including a
/// blob written by a different/incompatible OCCT version — callers fall back to
/// the persisted render mesh).
+ (nullable OCCTShape *)shapeFromSerialized:(NSData *)data;

/// Tessellate a world-space shape into a smooth-normalled render mesh (world
/// coordinates). Same deflection semantics as the cylinder method.
+ (OCCTRenderMesh *)renderMeshFromShape:(OCCTShape *)shape
                       angularDeflection:(double)angularDeflection
                        linearDeflection:(double)linearDeflection;

@end

NS_ASSUME_NONNULL_END
