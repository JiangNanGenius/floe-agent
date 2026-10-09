//
//  OCCTBridge.mm
//  openshape3d — OCCT B-rep port, Milestone 0 (spike)
//
//  Obj-C++ implementation of the narrow OCCT facade. This file is the ONLY
//  place OCCT's C++ headers are included; everything else in the app sees the
//  plain Obj-C interface in OCCTBridge.h.
//

// OCCT was built with OCC_CONVERT_SIGNALS (its handler machinery is in the
// archive); defining it here makes OCC_CATCH_SIGNALS expand to the matching
// setjmp point, so a hardware fault inside the kernel becomes a C++
// exception instead of taking the app down. See "Crash guard" below.
#define OCC_CONVERT_SIGNALS 1
#import "OCCTBridge.h"

#include <vector>
#include <algorithm>
#include <csignal>
#include <memory>
#include <OSD.hxx>
#include <Standard_ErrorHandler.hxx>
#include <Standard_Failure.hxx>
#include <limits>
#include <set>
#include <cmath>
#include <Bnd_Box.hxx>
#include <BRepBndLib.hxx>
#include <cstdint>
#include <sstream>
#include <string>

#include <BRepTools.hxx>
#include <BRepGProp_Face.hxx>
#include <BRep_Builder.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepAlgoAPI_Defeaturing.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <TopTools_ListOfShape.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_LocalOperation.hxx>
#include <STEPControl_Writer.hxx>
#include <STEPControl_Reader.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <ShapeUpgrade_ShapeDivideContinuity.hxx>
#include <ShapeBuild_ReShape.hxx>
#include <BRepTools_History.hxx>
#include <BRepOffsetAPI_DraftAngle.hxx>
#include <BRepOffsetAPI_MakeOffsetShape.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <BRepAlgoAPI_Section.hxx>
#include <GCPnts_UniformDeflection.hxx>
#include <GCPnts_AbscissaPoint.hxx>
#include <gp_Pln.hxx>
#include <Geom_Surface.hxx>
#include <Geom_BSplineSurface.hxx>
#include <Geom_SurfaceOfLinearExtrusion.hxx>
#include <Geom_SurfaceOfRevolution.hxx>
#include <Geom_RectangularTrimmedSurface.hxx>
#include <Geom2d_Curve.hxx>
#include <GeomAPI_ProjectPointOnCurve.hxx>
#include <Geom_Curve.hxx>
#include <TopExp.hxx>
#include <TopTools_IndexedMapOfShape.hxx>

#include <Standard_Version.hxx>

#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepOffsetAPI_MakePipe.hxx>
#include <BRepOffsetAPI_MakePipeShell.hxx>
#include <TopTools_DataMapOfShapeShape.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <Geom2d_Line.hxx>
#include <BRepLib.hxx>
#include <gp_Ax3.hxx>
#include <BRepBuilderAPI_TransitionMode.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <Poly_Triangle.hxx>
#include <TopAbs_Orientation.hxx>
#include <gp_Pnt2d.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <IMeshTools_Parameters.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <BRep_Tool.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <GeomAbs_SurfaceType.hxx>
#include <Poly_Triangulation.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Wire.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Ax2.hxx>
#include <gp_Circ.hxx>
#include <gp_Elips.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <Geom_BSplineCurve.hxx>
#include <GeomConvert.hxx>
#include <TColGeom_HArray1OfBSplineCurve.hxx>
#include <Geom_Plane.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <gp_Pnt2d.hxx>
#include <algorithm>
#include <cmath>
#include <Geom_TrimmedCurve.hxx>
#include <gp_Dir.hxx>
#include <gp_Pnt.hxx>
#include <gp_Vec.hxx>
#include <gp_Trsf.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_BooleanOperation.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <ShapeFix_Shape.hxx>
#include <ShapeAnalysis_ShapeTolerance.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepBuilderAPI_MakeShape.hxx>
#include <Precision.hxx>
#include <Standard_Failure.hxx>
#include <GeomAbs_Shape.hxx>
#include <Message_ProgressIndicator.hxx>
#include <Message_ProgressScope.hxx>
#include <TopTools_FormatVersion.hxx>
#include <functional>
#include <map>
#include <array>
#include <BRepCheck_Result.hxx>
#include <BRepCheck_ListIteratorOfListOfStatus.hxx>
#include <BRepCheck_Status.hxx>
#include <BOPAlgo_ArgumentAnalyzer.hxx>
#include <BOPAlgo_CheckResult.hxx>
#include <BOPAlgo_ListOfCheckResult.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <ShapeAnalysis_FreeBounds.hxx>
#include <TopTools_MapOfShape.hxx>
#include <TopTools_ListIteratorOfListOfShape.hxx>
#include <TopoDS_Iterator.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Shell.hxx>
#include <TopoDS_Solid.hxx>

// Opaque handle: a world-space solid. The C++ TopoDS_Shape ivar is destroyed
// automatically (ARC runs C++ ivar destructors in Obj-C++).
@interface OCCTShape () {
@public
    TopoDS_Shape _shape;
}
@end
@implementation OCCTShape
@end

@interface OCCTPlaneBasis () {
@public
    double _o[3], _x[3], _y[3], _n[3];
}
@end
@implementation OCCTPlaneBasis
- (instancetype)initWithOriginX:(double)ox originY:(double)oy originZ:(double)oz
                         xAxisX:(double)xx xAxisY:(double)xy xAxisZ:(double)xz
                         yAxisX:(double)yx yAxisY:(double)yy yAxisZ:(double)yz
                        normalX:(double)nx normalY:(double)ny normalZ:(double)nz {
    if ((self = [super init])) {
        _o[0]=ox; _o[1]=oy; _o[2]=oz;
        _x[0]=xx; _x[1]=xy; _x[2]=xz;
        _y[0]=yx; _y[1]=yy; _y[2]=yz;
        _n[0]=nx; _n[1]=ny; _n[2]=nz;
    }
    return self;
}
@end

@implementation OCCTOpStatus
@end

@implementation OCCTShapeHistory
- (instancetype)init {
    if ((self = [super init])) {
        _rows = [NSData data];
    }
    return self;
}
@end

// Fill a caller-supplied status object (nil status = caller doesn't care).
static void OS3DSetStatus(OCCTOpStatus *status, OCCTOpCode code, NSString *detail) {
    if (status == nil) return;
    status.code = code;
    status.detail = detail;
}

// MARK: - Crash guard
//
// OCCT has a few hardware faults left in it: ChFi3d's corner solver
// dereferences an empty extrema result on the practice-sheet 4.7 clevis
// (an R2 fillet on the concave arcs where a lug cylinder meets the plate's
// side faces) and took the whole app, and the unsaved document, with it
// (2026-09-04). A C++ catch cannot see a SIGSEGV, so the builder calls that
// do real work run inside OCCT's own conversion: OSD::SetSignal installs
// handlers that turn the fault into a longjmp to the nearest
// OCC_CATCH_SIGNALS, which rethrows it as a Standard_Failure — from a normal
// context, with every Standard_ErrorHandler on the way unlinked while the
// stack is still intact (a home-made sigsetjmp guard left them dangling and
// the NEXT kernel call died in Standard_ErrorHandler::FindHandler). OCCT's
// own try blocks up the stack may swallow it (a faulty contour), else the
// catch in OS3D_GUARDED reports it typed. The previous signal actions are
// restored on the way out, so a fault anywhere else still crashes the way
// it always did.
struct OS3DSignalScope {
    static constexpr int signals[] = {SIGHUP, SIGINT, SIGQUIT, SIGILL, SIGTRAP, SIGABRT,
                                      SIGFPE, SIGBUS, SIGSEGV, SIGSYS, SIGPIPE, SIGTERM};
    static constexpr int count = sizeof(signals) / sizeof(signals[0]);
    struct sigaction saved[count];
    OS3DSignalScope() {
        for (int i = 0; i < count; i++) sigaction(signals[i], nullptr, &saved[i]);
        OSD::SetSignal(OSD_SignalMode_Set, Standard_False);
    }
    ~OS3DSignalScope() {
        for (int i = 0; i < count; i++) sigaction(signals[i], &saved[i], nullptr);
        // The jump out of the handler may have left the faulting signal
        // blocked on this thread; a blocked synchronous signal is fatal.
        sigset_t set;
        sigemptyset(&set);
        for (int i = 0; i < count; i++) sigaddset(&set, signals[i]);
        pthread_sigmask(SIG_UNBLOCK, &set, nullptr);
    }
};

static NSString *OS3DCrashMessage(const char *what, const char *detail) {
    NSString *reason = detail ? [NSString stringWithUTF8String:detail] : @"";
    if ([reason rangeOfString:@"SIG"].location != NSNotFound) {
        return [NSString stringWithFormat:
                @"%s: the kernel faulted computing this (%@) and the operation was "
                @"abandoned — the body is unchanged; try a smaller size or fewer edges",
                what, reason];
    }
    return [NSString stringWithFormat:@"%s: %@", what, reason.length ? reason : @"kernel error"];
}

// Run one kernel builder call under the guard. Any Standard_Failure that
// escapes — a converted signal, or a plain OCCT exception the algorithm
// did not handle itself — becomes a typed refusal and returns nil.
#define OS3D_GUARDED(statusObj, what, ...) \
    do { \
        OS3DSignalScope _signalScope; \
        try { \
            OCC_CATCH_SIGNALS \
            __VA_ARGS__; \
        } catch (Standard_Failure &_failure) { \
            OS3DSetStatus(statusObj, OCCTOpCodeKernelRefused, \
                          OS3DCrashMessage(what, _failure.GetMessageString())); \
            return nil; \
        } \
    } while (0)

// True when the shape has a bounding box with only finite coordinates. A
// shape carrying NaN/inf can parse cleanly and then spin forever inside
// BRepMesh_IncrementalMesh (an infinite loop no catch(...) reaches) — see the
// note in TessellateShape. Also the cheap first gate at every constructive-op
// entry, so degenerate operands are refused instead of propagated.
static bool OS3DFiniteBounds(const TopoDS_Shape &shape) {
    if (shape.IsNull()) return false;
    Bnd_Box bounds;
    BRepBndLib::Add(shape, bounds);
    if (bounds.IsVoid()) return false;
    Standard_Real xmin, ymin, zmin, xmax, ymax, zmax;
    bounds.Get(xmin, ymin, zmin, xmax, ymax, zmax);
    for (Standard_Real v : {xmin, ymin, zmin, xmax, ymax, zmax}) {
        if (!std::isfinite(v)) return false;
    }
    return true;
}

static bool OS3DHasTriangulation(const TopoDS_Shape &shape) {
    for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) {
        TopLoc_Location location;
        if (!BRep_Tool::Triangulation(TopoDS::Face(ex.Current()), location).IsNull()) {
            return true;
        }
    }
    return false;
}

// The same shape without its triangulation: new TShapes sharing the original
// curves and surfaces (so it is cheap), with no face triangulations and no
// edge polygons on them. Null when the copy fails.
static TopoDS_Shape OS3DWithoutMesh(const TopoDS_Shape &shape) {
    BRepBuilderAPI_Copy copy(shape, /*copyGeom*/ Standard_False, /*copyMesh*/ Standard_False);
    return copy.IsDone() ? copy.Shape() : TopoDS_Shape();
}

// Whether a shape's GEOMETRY is valid. BRepCheck_Analyzer also checks the
// triangulation a shape carries (each edge's polygon on a face triangulation
// must lie on the edge's 3D curve within its tolerance), and here that
// triangulation is not model data: it is the render cache TessellateShape's
// BRepMesh_IncrementalMesh writes into every adopted body. The mesher can
// write one the analyzer rejects. A pocket whose R1 fillets meet a boss
// tangentially came out exact (188.986 mm³ removed, the hand figure) and
// valid, until its render mesh made Edge21 `invalidPolygonOnTriangulation`;
// then /v1/check called the body invalid and every later boolean refused it
// as "the target solid is invalid" (practice problems round 6, bug 2,
// 2026-09-16). So when the shape as stored fails and carries a mesh, judge a
// copy without it. Documents are written without triangulation, so a
// reloaded body never had this problem.
static bool OS3DIsValid(const TopoDS_Shape &shape) {
    if (BRepCheck_Analyzer(shape).IsValid()) return true;
    if (!OS3DHasTriangulation(shape)) return false;
    const TopoDS_Shape bare = OS3DWithoutMesh(shape);
    return !bare.IsNull() && BRepCheck_Analyzer(bare).IsValid();
}

// Post-op contract (docs/FREECAD_PLAYBOOK.md I2): a builder's IsDone() is not
// a statement about the RESULT, so check it with BRepCheck_Analyzer; on
// failure make exactly one healing attempt (ShapeFix_Shape) and re-check.
// Returns a null shape when the result is still invalid — the caller must
// fail rather than store it, because a stored invalid solid becomes the
// body's source of truth and is persisted.
static TopoDS_Shape OS3DHealAndValidate(const TopoDS_Shape &result) {
    if (result.IsNull()) return result;
    if (OS3DIsValid(result)) return result;
    Handle(ShapeFix_Shape) fixer = new ShapeFix_Shape(result);
    fixer->Perform();
    const TopoDS_Shape healed = fixer->Shape();
    if (!healed.IsNull() && OS3DIsValid(healed)) return healed;
    return TopoDS_Shape();
}

static double OS3DMaxTolerance(const TopoDS_Shape &shape) {
    ShapeAnalysis_ShapeTolerance analysis;
    return analysis.Tolerance(shape, 1);   // mode > 0: the largest any sub-shape carries
}

// Unwrap the single solid from an op result. OCCT booleans hand back a
// COMPOUND even when it holds exactly one solid; storing the compound feeds
// downstream ops (shell, fillet) input they are not specified for. Returns
// the solid itself when there is exactly one, otherwise a null shape with
// `solidCount` saying whether that was 0 (empty result) or several.
static TopoDS_Shape OS3DExtractSingleSolid(const TopoDS_Shape &shape,
                                           int &solidCount) {
    solidCount = 0;
    TopoDS_Shape single;
    for (TopExp_Explorer ex(shape, TopAbs_SOLID); ex.More(); ex.Next()) {
        ++solidCount;
        if (solidCount == 1) single = ex.Current();
    }
    return solidCount == 1 ? single : TopoDS_Shape();
}

// A progress indicator whose only job is to abort a runaway kernel loop: the
// NaN fuzzing rounds proved BRepMesh_IncrementalMesh (and BRepTools::Read)
// can spin FOREVER on degenerate input — an infinite loop no catch(...)
// reaches, on the MainActor. Passed as `indicator->Start()` to any op that
// accepts a Message_ProgressRange; `Fired()` says the deadline tripped, so
// the caller returns a clean failure instead of trusting a half-built
// result. (FreeCAD wraps the same mechanism around its long ops —
// docs/FREECAD_PLAYBOOK.md H1.)
class OS3DDeadlineProgress : public Message_ProgressIndicator {
public:
    explicit OS3DDeadlineProgress(double seconds)
        : myDeadline(CFAbsoluteTimeGetCurrent() + seconds) {}
    Standard_Boolean UserBreak() Standard_OVERRIDE {
        return CFAbsoluteTimeGetCurrent() > myDeadline;
    }
    void Show(const Message_ProgressScope &, const Standard_Boolean) Standard_OVERRIDE {}
    bool Fired() const { return CFAbsoluteTimeGetCurrent() > myDeadline; }
private:
    double myDeadline;
};

// Generous against real work (normal tessellation is milliseconds), tight
// against a hang the user would otherwise force-quit out of.
static const double kOS3DKernelDeadlineSeconds = 5.0;

// Deadline for CONSTRUCTIVE builders (boolean/fillet/chamfer/defeaturing).
// Separate from the mesher/read deadline because a legitimately huge model's
// boolean deserves more rope than a tessellation — but not infinite rope:
// the Motorcycle-cover rebuild found a tangent union spinning the MainActor
// FOREVER at 99% CPU (health kept answering — it runs off the listener queue
// — which is exactly the wedge H1 exists to prevent). A hang also never
// returns, so it evades failure capture entirely; a deadline turns it into a
// typed, captured, reproducible failure.
static const double kOS3DOpDeadlineSeconds = 30.0;

// Same-domain unification, shared by unifiedShape: and the boolean result
// path. (unifyEdges, unifyFaces, concatBSplines) — faces and edges, but do
// NOT merge B-spline geometry: that would change analytic surfaces into
// something else. Returns the input on any failure — the un-unified shape is
// still valid.
static TopoDS_Shape OS3DUnified(const TopoDS_Shape &shape) {
    try {
        ShapeUpgrade_UnifySameDomain unifier(
            shape, Standard_True, Standard_True, Standard_False);
        unifier.Build();
        const TopoDS_Shape result = unifier.Shape();
        return result.IsNull() ? shape : result;
    } catch (...) {
        return shape;
    }
}

@interface OCCTRenderMesh () {
@public
    NSInteger _vertexCount;
    NSInteger _triangleCount;
    NSData *_positions;
    NSData *_normals;
    NSData *_indices;
    NSData *_faceIndices;
}
@end

static OCCTRenderMesh *EmptyRenderMesh() {
    OCCTRenderMesh *out = [OCCTRenderMesh new];
    out->_vertexCount = 0;
    out->_triangleCount = 0;
    out->_positions = [NSData data];
    out->_normals = [NSData data];
    out->_indices = [NSData data];
    out->_faceIndices = [NSData data];
    return out;
}

// Tessellate a shape and extract SMOOTH per-vertex normals from each face's
// analytic surface. Shared by the cylinder and general-shape render paths.
//
// Exception barrier: BRepMesh_IncrementalMesh and BRepAdaptor_Surface::D1
// raise Standard_Failure (a C++ exception) on degenerate or corrupt shapes —
// e.g. a marginal boolean result or a blob from another OCCT version.
// Letting one unwind through the Obj-C++ frame into Swift is a hard crash,
// and this runs on the main success path (adoptBRep tessellates every OCCT
// result). An empty mesh reads as failure upstream: adoptBRep leaves the
// body on the Euclid path.
static OCCTRenderMesh *TessellateShape(const TopoDS_Shape &solid,
                                       double linearDeflection,
                                       double angularDeflection) {
  try {
    // Refuse non-finite geometry BEFORE meshing. A shape carrying NaN/inf
    // coordinates can parse cleanly (correct face counts and all) and then
    // spin forever inside BRepMesh_IncrementalMesh — an INFINITE LOOP, which
    // the catch(...) below cannot catch, on the MainActor, i.e. an
    // unrecoverable freeze on document open. Verified by fuzzing the BREP
    // reader (2026-08-25 review round 3). Also protects the internal path
    // when a degenerate kernel op emits a NaN.
    if (!OS3DFiniteBounds(solid)) return EmptyRenderMesh();

    // The finite-bounds gate above catches NaN COORDINATES; the deadline
    // catches everything else that makes the mesher spin (degenerate
    // pcurves, self-intersecting tolerance zones from a fuzzed blob). A
    // tripped deadline yields an empty mesh — the same recoverable failure
    // as any other bad shape — instead of a frozen MainActor. (The simple
    // constructor auto-Performs with no progress hook, so parameters go
    // through IMeshTools_Parameters.)
    OS3DDeadlineProgress *deadline = new OS3DDeadlineProgress(kOS3DKernelDeadlineSeconds);
    Handle(Message_ProgressIndicator) progress(deadline);
    IMeshTools_Parameters params;
    params.Deflection = linearDeflection;
    params.Angle = angularDeflection;
    params.Relative = Standard_False;
    params.InParallel = Standard_True;
    BRepMesh_IncrementalMesh mesher(solid, params, progress->Start());
    if (deadline->Fired()) return EmptyRenderMesh();

    std::vector<float> positions, normals;
    std::vector<uint32_t> indices;
    std::vector<uint32_t> faceIndices;

    // The SAME numbering the health report and (coming) element naming use:
    // 1-based index into the shape's indexed face map. The explorer below
    // usually walks in map order, but "usually" is not a contract — look each
    // face up instead of trusting the walk.
    TopTools_IndexedMapOfShape faceMap;
    TopExp::MapShapes(solid, TopAbs_FACE, faceMap);

    for (TopExp_Explorer ex(solid, TopAbs_FACE); ex.More(); ex.Next()) {
        TopoDS_Face face = TopoDS::Face(ex.Current());
        const uint32_t faceIndex = (uint32_t)faceMap.FindIndex(face);
        TopLoc_Location loc;
        Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
        if (tri.IsNull()) continue;

        const gp_Trsf trsf = loc.Transformation();
        const bool reversed = (face.Orientation() == TopAbs_REVERSED);
        const bool haveUV = tri->HasUVNodes();
        BRepAdaptor_Surface surf(face, Standard_False);
        const uint32_t base = (uint32_t)(positions.size() / 3);

        for (Standard_Integer i = 1; i <= tri->NbNodes(); ++i) {
            gp_Pnt p = tri->Node(i).Transformed(trsf);
            positions.push_back((float)p.X());
            positions.push_back((float)p.Y());
            positions.push_back((float)p.Z());

            gp_Vec n(0.0, 0.0, 1.0);
            if (haveUV) {
                gp_Pnt2d uv = tri->UVNode(i);
                gp_Pnt sp; gp_Vec du, dv;
                surf.D1(uv.X(), uv.Y(), sp, du, dv);
                gp_Vec cross = du.Crossed(dv);
                if (cross.Magnitude() > 1e-12) {
                    n = cross.Normalized();
                    if (reversed) n.Reverse();
                    n.Transform(trsf);
                }
            }
            normals.push_back((float)n.X());
            normals.push_back((float)n.Y());
            normals.push_back((float)n.Z());
        }

        for (Standard_Integer t = 1; t <= tri->NbTriangles(); ++t) {
            Standard_Integer a, b, c;
            tri->Triangle(t).Get(a, b, c);
            if (reversed) std::swap(b, c);
            indices.push_back(base + (uint32_t)(a - 1));
            indices.push_back(base + (uint32_t)(b - 1));
            indices.push_back(base + (uint32_t)(c - 1));
            faceIndices.push_back(faceIndex);
        }
    }

    OCCTRenderMesh *out = [OCCTRenderMesh new];
    out->_vertexCount = (NSInteger)(positions.size() / 3);
    out->_triangleCount = (NSInteger)(indices.size() / 3);
    out->_positions = [NSData dataWithBytes:positions.data() length:positions.size() * sizeof(float)];
    out->_normals = [NSData dataWithBytes:normals.data() length:normals.size() * sizeof(float)];
    out->_indices = [NSData dataWithBytes:indices.data() length:indices.size() * sizeof(uint32_t)];
    out->_faceIndices = [NSData dataWithBytes:faceIndices.data() length:faceIndices.size() * sizeof(uint32_t)];
    return out;
  } catch (...) {
    return EmptyRenderMesh();
  }
}

@implementation OCCTMeshResult {
@public
    NSInteger _triangleCount;
    NSInteger _vertexCount;
    double _volume;
}
- (NSInteger)triangleCount { return _triangleCount; }
- (NSInteger)vertexCount { return _vertexCount; }
- (double)volume { return _volume; }
@end

@implementation OCCTFaceTypeCounts {
@public
    NSInteger _planar;
    NSInteger _cylindrical;
    NSInteger _other;
}
- (NSInteger)planar { return _planar; }
- (NSInteger)cylindrical { return _cylindrical; }
- (NSInteger)other { return _other; }
@end

@implementation OCCTRenderMesh
- (NSInteger)vertexCount { return _vertexCount; }
- (NSInteger)triangleCount { return _triangleCount; }
- (NSData *)positions { return _positions; }
- (NSData *)normals { return _normals; }
- (NSData *)indices { return _indices; }
- (NSData *)faceIndices { return _faceIndices; }
@end

@implementation OCCTBridge

+ (NSString *)occtVersion {
    return @OCC_VERSION_COMPLETE;
}

+ (OCCTMeshResult *)meshBoxWithSize:(double)size {
    TopoDS_Shape box = BRepPrimAPI_MakeBox(size, size, size).Shape();

    // Tessellate. Linear deflection 0.1 mm is fine for a spike sanity check.
    BRepMesh_IncrementalMesh mesher(box, 0.1);
    mesher.Perform();

    NSInteger tris = 0;
    NSInteger verts = 0;
    for (TopExp_Explorer ex(box, TopAbs_FACE); ex.More(); ex.Next()) {
        TopoDS_Face face = TopoDS::Face(ex.Current());
        TopLoc_Location loc;
        Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
        if (!tri.IsNull()) {
            tris += tri->NbTriangles();
            verts += tri->NbNodes();
        }
    }

    GProp_GProps props;
    BRepGProp::VolumeProperties(box, props);

    OCCTMeshResult *result = [OCCTMeshResult new];
    result->_triangleCount = tris;
    result->_vertexCount = verts;
    result->_volume = props.Mass();
    return result;
}

+ (OCCTFaceTypeCounts *)extrudeCircleFaceCountsWithRadius:(double)r
                                                   height:(double)height {
    // Circle on the XY plane → planar face → prism along +Z.
    gp_Ax2 axis(gp_Pnt(0.0, 0.0, 0.0), gp_Dir(0.0, 0.0, 1.0));
    gp_Circ circle(axis, r);
    TopoDS_Edge edge = BRepBuilderAPI_MakeEdge(circle);
    TopoDS_Wire wire = BRepBuilderAPI_MakeWire(edge);
    TopoDS_Face face = BRepBuilderAPI_MakeFace(wire);
    TopoDS_Shape solid = BRepPrimAPI_MakePrism(face, gp_Vec(0.0, 0.0, height));

    NSInteger planar = 0, cyl = 0, other = 0;
    for (TopExp_Explorer ex(solid, TopAbs_FACE); ex.More(); ex.Next()) {
        BRepAdaptor_Surface surf(TopoDS::Face(ex.Current()));
        switch (surf.GetType()) {
            case GeomAbs_Plane: planar++; break;
            case GeomAbs_Cylinder: cyl++; break;
            default: other++; break;
        }
    }

    OCCTFaceTypeCounts *counts = [OCCTFaceTypeCounts new];
    counts->_planar = planar;
    counts->_cylindrical = cyl;
    counts->_other = other;
    return counts;
}

+ (OCCTRenderMesh *)cylinderRenderMeshWithCenterX:(double)cx
                                          centerY:(double)cy
                                           radius:(double)r
                                             zMin:(double)zMin
                                             zMax:(double)zMax
                                 angularDeflection:(double)angularDeflection
                                  linearDeflection:(double)linearDeflection {
    const double height = zMax - zMin;
    gp_Ax2 axis(gp_Pnt(cx, cy, zMin), gp_Dir(0.0, 0.0, 1.0));
    TopoDS_Shape solid = BRepPrimAPI_MakeCylinder(axis, r, height).Shape();
    return TessellateShape(solid, linearDeflection, angularDeflection);
}

// MARK: - B-rep source of truth

// Build a wire on the plane z=`z` from packed (x,y) doubles.
static TopoDS_Wire PolyWire(NSData *loop, double z) {
    const double *p = (const double *)loop.bytes;
    NSUInteger n = loop.length / (2 * sizeof(double));
    BRepBuilderAPI_MakePolygon poly;
    for (NSUInteger i = 0; i < n; ++i) poly.Add(gp_Pnt(p[2*i], p[2*i+1], z));
    poly.Close();
    return poly.Wire();
}

// Build a closed wire from one packed conic: `cx, cy, rx, ry, rotation`
// (see OCCTBridge.h). Null wire when `rx` is not positive — the caller then
// falls back to the polyline.
//
// `gp_Elips` REQUIRES its major radius first and refuses major < minor, and
// the sketch's own semi-axes are in no particular order, so the larger one is
// chosen here and the reference direction turned a quarter turn when that is
// the y semi-axis. Equal radii would make `gp_Elips` degenerate, so a circle
// is built as a circle — which is also what keeps a drilled hole reporting as
// a cylindrical face rather than a surface of extrusion.
static TopoDS_Wire ConicWire(const double *c, double z) {
    const double cx = c[0], cy = c[1], rx = c[2], ry = c[3], rot = c[4];
    if (!(rx > 1e-12) || !(ry > 1e-12)) return TopoDS_Wire();
    const gp_Pnt centre(cx, cy, z);
    const gp_Dir up(0.0, 0.0, 1.0);
    if (fabs(rx - ry) <= 1e-9 * fmax(rx, ry)) {
        gp_Ax2 ax(centre, up);
        BRepBuilderAPI_MakeEdge me{gp_Circ(ax, rx)};
        if (!me.IsDone()) return TopoDS_Wire();
        return BRepBuilderAPI_MakeWire(me.Edge()).Wire();
    }
    const bool xIsMajor = rx > ry;
    const double angle = xIsMajor ? rot : rot + M_PI_2;
    gp_Ax2 ax(centre, up, gp_Dir(cos(angle), sin(angle), 0.0));
    BRepBuilderAPI_MakeEdge me{
        gp_Elips(ax, xIsMajor ? rx : ry, xIsMajor ? ry : rx)};
    if (!me.IsDone()) return TopoDS_Wire();
    return BRepBuilderAPI_MakeWire(me.Edge()).Wire();
}

// Build a wire on the plane z=`z` from packed edges: 7 doubles each,
// `isArc, x1, y1, x2, y2, midX, midY` (see OCCTBridge.h).
//
// A tessellated arc reaches OCCT as a polyline and stays one forever after: a
// fillet on the rim then has one segment per facet, and STEP exports every
// one of them as a plane. Three points reconstruct the circle exactly, and
// GC_MakeArcOfCircle takes them in traversal order, so a chain walked
// backwards needs no sign flip anywhere.
//
// Returns a null wire on any bad edge; the caller falls back to the polyline
// rather than building half a boundary.
/// ONE B-spline edge through a sketch spline's control points — the SAME
/// curve the sketch draws (docs/SPLINE_PROFILE_DESIGN.md). Each span of the
/// centripetal Catmull–Rom is exactly a cubic Bézier (the math mirrors
/// `CatmullRomBezier.swift`; the Swift tests pin it against `splinePoints`,
/// the volume tests pin this against the Swift); the spans are joined into
/// a single C1 B-spline so the wall it sweeps is one face, not one per span.
/// Degenerate spans — an OPEN spline's ends, whose neighbours are clamped —
/// are straight, as the sketch draws them. A closed spline's curve returns
/// to its first point and MakeEdge makes it a closed edge.
static bool OS3DSplineEdge(const double *xy, NSUInteger count, bool closed,
                           double z, TopoDS_Edge &outEdge) {
    if (count < 2) return false;
    if (count == 2) {
        BRepBuilderAPI_MakeEdge me(gp_Pnt(xy[0], xy[1], z), gp_Pnt(xy[2], xy[3], z));
        if (!me.IsDone()) return false;
        outEdge = me.Edge();
        return true;
    }
    const long n = (long)count;
    const long spans = closed ? n : n - 1;
    auto P = [&](long i) -> gp_Pnt2d {
        long k = closed ? (((i % n) + n) % n) : std::min(std::max(i, 0L), n - 1);
        return gp_Pnt2d(xy[2 * k], xy[2 * k + 1]);
    };
    // A chain of cubic Béziers IS a B-spline by construction: 3·spans + 1
    // poles, knots 0…spans with multiplicities [4, 3, …, 3, 4]. Assembled
    // directly — no concatenation utility, no tolerance, nothing that could
    // reshape a join — so the edge is exactly the Bézier chain.
    TColgp_Array1OfPnt poles(1, (Standard_Integer)(3 * spans + 1));
    for (long s = 0; s < spans; ++s) {
        const gp_Pnt2d p0 = P(s - 1), p1 = P(s), p2 = P(s + 1), p3 = P(s + 2);
        const double t0 = 0.0;
        const double t1 = t0 + std::sqrt(p0.Distance(p1));
        const double t2 = t1 + std::sqrt(p1.Distance(p2));
        const double t3 = t2 + std::sqrt(p2.Distance(p3));
        gp_Pnt2d b1, b2;
        if (!(t1 > t0 && t2 > t1 && t3 > t2)) {
            b1 = gp_Pnt2d(p1.X() + (p2.X() - p1.X()) / 3, p1.Y() + (p2.Y() - p1.Y()) / 3);
            b2 = gp_Pnt2d(p2.X() - (p2.X() - p1.X()) / 3, p2.Y() - (p2.Y() - p1.Y()) / 3);
        } else {
            const double h = t2 - t1;
            const double d1x = ((p1.X() - p0.X()) / (t1 - t0) * (t2 - t1)
                                + (p2.X() - p1.X()) / (t2 - t1) * (t1 - t0)) / (t2 - t0);
            const double d1y = ((p1.Y() - p0.Y()) / (t1 - t0) * (t2 - t1)
                                + (p2.Y() - p1.Y()) / (t2 - t1) * (t1 - t0)) / (t2 - t0);
            const double d2x = ((p2.X() - p1.X()) / (t2 - t1) * (t3 - t2)
                                + (p3.X() - p2.X()) / (t3 - t2) * (t2 - t1)) / (t3 - t1);
            const double d2y = ((p2.Y() - p1.Y()) / (t2 - t1) * (t3 - t2)
                                + (p3.Y() - p2.Y()) / (t3 - t2) * (t2 - t1)) / (t3 - t1);
            b1 = gp_Pnt2d(p1.X() + d1x * h / 3, p1.Y() + d1y * h / 3);
            b2 = gp_Pnt2d(p2.X() - d2x * h / 3, p2.Y() - d2y * h / 3);
        }
        const Standard_Integer base = (Standard_Integer)(3 * s);
        poles.SetValue(base + 1, gp_Pnt(p1.X(), p1.Y(), z));
        poles.SetValue(base + 2, gp_Pnt(b1.X(), b1.Y(), z));
        poles.SetValue(base + 3, gp_Pnt(b2.X(), b2.Y(), z));
        poles.SetValue(base + 4, gp_Pnt(p2.X(), p2.Y(), z));   // == next span's first pole
    }
    // Knots at the CENTRIPETAL parameters the tangents were derived with, so
    // consecutive Béziers meet with EQUAL derivatives — parametric C1 — and
    // each joint's multiplicity can drop from 3 to 2 without moving the
    // curve. Uniform knots left OCCT reading the chain as C0 from its knot
    // structure alone, and BRepOffset refuses C0 (BRepOffset_C0Geometry):
    // a revolved spline could not be shelled at any wall (2026-09-02).
    TColStd_Array1OfReal knots(1, (Standard_Integer)(spans + 1));
    TColStd_Array1OfInteger mults(1, (Standard_Integer)(spans + 1));
    knots.SetValue(1, 0.0);
    mults.SetValue(1, 4);
    double t = 0.0;
    for (long s = 0; s < spans; ++s) {
        double h = std::sqrt(P(s).Distance(P(s + 1)));
        if (!(h > 1e-9)) h = 1e-6;
        t += h;
        knots.SetValue((Standard_Integer)s + 2, t);
        mults.SetValue((Standard_Integer)s + 2, (s == spans - 1) ? 4 : 3);
    }
    Handle(Geom_BSplineCurve) curve;
    try {
        curve = new Geom_BSplineCurve(poles, knots, mults, 3);
    } catch (...) {
        return false;
    }
    if (curve.IsNull()) return false;
    // Lower every interior joint to C1 where the two Béziers agree (they do
    // by construction, except beside a straight end span or a degenerate
    // one); a joint that refuses stays C0 rather than being reshaped — the
    // wire builder then splits the edge there.
    for (Standard_Integer k = curve->NbKnots() - 1; k >= 2; --k) {
        if (curve->Multiplicity(k) > 2) {
            try { curve->RemoveKnot(k, 2, 1.0e-7); } catch (...) {}
        }
    }
    BRepBuilderAPI_MakeEdge me(curve);
    if (!me.IsDone()) return false;
    outEdge = me.Edge();
    return true;
}

/// Records are walked by KIND (see `packSegments`): a line or arc is 7
/// doubles, a spline is `kind, count, count x,y pairs` and becomes ONE edge.
static TopoDS_Wire SegWire(NSData *segs, double z) {
    const double *p = (const double *)segs.bytes;
    const NSUInteger total = segs.length / sizeof(double);
    BRepBuilderAPI_MakeWire mw;
    NSUInteger i = 0, records = 0;
    bool closedSpline = false;
    while (i < total) {
        const double kind = p[i];
        if (kind < 1.5) {
            if (i + 7 > total) return TopoDS_Wire();
            const double *e = p + i;
            gp_Pnt a(e[1], e[2], z), b(e[3], e[4], z);
            if (a.IsEqual(b, 1e-12)) return TopoDS_Wire();
            bool added = false;
            if (e[0] > 0.5) {
                gp_Pnt m(e[5], e[6], z);
                GC_MakeArcOfCircle mk(a, m, b);
                // Collinear samples have no circle through them; a "flat arc"
                // is a straight line and is built as one rather than failing.
                if (mk.IsDone()) {
                    BRepBuilderAPI_MakeEdge me(mk.Value());
                    if (!me.IsDone()) return TopoDS_Wire();
                    mw.Add(me.Edge());
                    added = true;
                }
            }
            if (!added) {
                BRepBuilderAPI_MakeEdge me(a, b);
                if (!me.IsDone()) return TopoDS_Wire();
                mw.Add(me.Edge());
            }
            i += 7;
        } else {
            if (i + 2 > total) return TopoDS_Wire();
            const NSUInteger count = (NSUInteger)p[i + 1];
            if (i + 2 + 2 * count > total) return TopoDS_Wire();
            const bool closed = kind > 2.5;
            TopoDS_Edge edge;
            if (!OS3DSplineEdge(p + i + 2, count, closed, z, edge)) return TopoDS_Wire();
            // A joint the spline could not make C1 (an open spline's straight
            // end span meeting the curve at a corner) becomes an EDGE
            // boundary: a face may not carry a crease inside it — offsets
            // refuse, tangent chains stop there anyway.
            Standard_Real f = 0, l = 0;
            Handle(Geom_Curve) c3d = BRep_Tool::Curve(edge, f, l);
            Handle(Geom_BSplineCurve) bs = Handle(Geom_BSplineCurve)::DownCast(c3d);
            bool split = false;
            if (!bs.IsNull()) {
                Handle(TColGeom_HArray1OfBSplineCurve) pieces;
                try {
                    GeomConvert::C0BSplineToArrayOfC1BSplineCurve(bs, pieces, 1.0e-7);
                } catch (...) { pieces.Nullify(); }
                if (!pieces.IsNull() && pieces->Length() > 1) {
                    for (Standard_Integer k = pieces->Lower(); k <= pieces->Upper(); ++k) {
                        const Handle(Geom_BSplineCurve) &piece = pieces->Value(k);
                        // A straight piece (an open spline's end span) is a
                        // LINE edge: it extrudes to a plane and revolves to a
                        // cone, and reads as such downstream.
                        bool straight = true;
                        const gp_Pnt a = piece->StartPoint(), b = piece->EndPoint();
                        const double len = a.Distance(b);
                        if (len > 1e-9) {
                            const gp_Dir d(gp_Vec(a, b));
                            for (Standard_Integer q = piece->Poles().Lower(); q <= piece->Poles().Upper() && straight; ++q) {
                                const gp_Vec ap(a, piece->Pole(q));
                                if (ap.CrossMagnitude(gp_Vec(d)) > 1e-7 * std::max(1.0, len)) straight = false;
                            }
                        } else {
                            straight = false;
                        }
                        BRepBuilderAPI_MakeEdge me = straight ? BRepBuilderAPI_MakeEdge(a, b)
                                                              : BRepBuilderAPI_MakeEdge(piece);
                        if (!me.IsDone()) return TopoDS_Wire();
                        mw.Add(me.Edge());
                        ++records;
                    }
                    split = true;
                }
            }
            if (!split) mw.Add(edge);
            if (closed) closedSpline = true;
            i += 2 + 2 * count;
        }
        ++records;
    }
    // A boundary needs at least two edges — unless it is one closed spline.
    if (records < 2 && !closedSpline) return TopoDS_Wire();
    if (!mw.IsDone()) return TopoDS_Wire();
    return mw.Wire();
}

/// Build the profile FACE that every profile-driven op starts from, on the
/// plane z = `z` in profile-local space.
///
/// Factored out of `extrudedShapeWithOuterLoop:` so revolve, sweep and loft
/// begin from EXACTLY the same wires an extrude does — the analytic conic, the
/// exact arc segments, or the polyline, chosen in that order. Anything less
/// would mean a circle staying round when extruded and going faceted when
/// revolved, which is the sort of quiet inconsistency the B-rep work exists to
/// remove. Returns a null face on any failure.
static TopoDS_Face OS3DProfileFace(NSData *outerLoop,
                                   NSData *outerConic,
                                   NSArray<NSData *> *holes,
                                   NSData *holeConics,
                                   NSData *outerSegments,
                                   NSArray<NSData *> *holeSegments,
                                   double z) {
    TopoDS_Wire outerWire;
    if (outerConic != nil && outerConic.length >= 5 * sizeof(double)) {
        outerWire = ConicWire((const double *)outerConic.bytes, z);
    }
    if (outerWire.IsNull() && outerSegments != nil && outerSegments.length > 0) {
        outerWire = SegWire(outerSegments, z);
    }
    if (outerWire.IsNull()) {
        if (outerLoop.length < 3 * 2 * (NSInteger)sizeof(double)) return TopoDS_Face();
        outerWire = PolyWire(outerLoop, z);
    }
    if (outerWire.IsNull()) return TopoDS_Face();

    BRepBuilderAPI_MakeFace mf(outerWire, Standard_True);
    const double *conics = NULL;
    NSUInteger conicCount = 0;
    if (holeConics != nil) {
        conics = (const double *)holeConics.bytes;
        conicCount = holeConics.length / (5 * sizeof(double));
    }
    NSUInteger index = 0;
    for (NSData *hole in holes) {
        TopoDS_Wire hw;
        if (index < conicCount) hw = ConicWire(conics + index * 5, z);
        if (hw.IsNull()) {
            NSData *hs = (holeSegments != nil && index < holeSegments.count)
                ? holeSegments[index] : nil;
            if (hs != nil && hs.length > 0) hw = SegWire(hs, z);
        }
        if (hw.IsNull()) {
            if (hole.length < 3 * 2 * (NSInteger)sizeof(double)) { index++; continue; }
            hw = PolyWire(hole, z);
        }
        hw.Reverse();  // inner boundary opposes the outer sense
        mf.Add(hw);
        index++;
    }
    if (!mf.IsDone()) return TopoDS_Face();
    return mf.Face();
}

/// plane-local → world, from the basis columns.
static gp_Trsf OS3DBasisTransform(OCCTPlaneBasis *basis) {
    gp_Trsf t;
    t.SetValues(basis->_x[0], basis->_y[0], basis->_n[0], basis->_o[0],
                basis->_x[1], basis->_y[1], basis->_n[1], basis->_o[1],
                basis->_x[2], basis->_y[2], basis->_n[2], basis->_o[2]);
    return t;
}

+ (nullable OCCTShape *)extrudedShapeWithOuterLoop:(NSData *)outerLoop
                                        outerConic:(nullable NSData *)outerConic
                                             holes:(NSArray<NSData *> *)holes
                                        holeConics:(nullable NSData *)holeConics
                                     outerSegments:(nullable NSData *)outerSegments
                                      holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                              zMin:(double)zMin
                                              zMax:(double)zMax
                                             basis:(OCCTPlaneBasis *)basis {
    return [self extrudedShapeWithOuterLoop:outerLoop outerConic:outerConic
                                      holes:holes holeConics:holeConics
                              outerSegments:outerSegments
                               holeSegments:holeSegments
                                       zMin:zMin zMax:zMax basis:basis
                                    history:nil];
}

+ (nullable OCCTShape *)extrudedShapeWithOuterLoop:(NSData *)outerLoop
                                        outerConic:(nullable NSData *)outerConic
                                             holes:(NSArray<NSData *> *)holes
                                        holeConics:(nullable NSData *)holeConics
                                     outerSegments:(nullable NSData *)outerSegments
                                      holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                              zMin:(double)zMin
                                              zMax:(double)zMax
                                             basis:(OCCTPlaneBasis *)basis
                                           history:(nullable OCCTShapeHistory *)history {
    const double height = zMax - zMin;
    if (height <= 1e-9) return nil;
    try {
        const TopoDS_Face face = OS3DProfileFace(outerLoop, outerConic, holes,
                                                 holeConics, outerSegments,
                                                 holeSegments, zMin);
        if (face.IsNull()) return nil;

        BRepPrimAPI_MakePrism prism(face, gp_Vec(0.0, 0.0, height));
        TopoDS_Shape solid = prism.Shape();
        // Copy=true: the transform COPIES every sub-shape, so prism faces are
        // NOT IsSame with world faces — ancestry must ride ModifiedShape().
        BRepBuilderAPI_Transform placer(solid, OS3DBasisTransform(basis),
                                        Standard_True);
        TopoDS_Shape world = placer.Shape();

        if (history != nil && !world.IsNull()) {
            TopTools_IndexedMapOfShape worldFaces;
            TopExp::MapShapes(world, TopAbs_FACE, worldFaces);
            std::set<std::array<int32_t, 5>> rowSet;

            // A prism-output face's index in the FINAL world shape: hop 2 is
            // the copying transform, and the in-result gate still applies.
            auto worldIndexOf = [&](const TopoDS_Shape &prismFace) -> int32_t {
                try {
                    const TopoDS_Shape placed = placer.ModifiedShape(prismFace);
                    if (!placed.IsNull()) {
                        const int32_t index = worldFaces.FindIndex(placed);
                        if (index > 0) return index;
                    }
                } catch (...) {}
                return (int32_t)worldFaces.FindIndex(prismFace);
            };
            auto emit = [&](const TopoDS_Shape &prismShape, int32_t ordinal,
                            int32_t kind, int32_t subIndex, int32_t relation) {
                if (prismShape.IsNull()) return;
                if (prismShape.ShapeType() != TopAbs_FACE) return;
                const int32_t index = worldIndexOf(prismShape);
                if (index <= 0) return;
                if (rowSet.size() >= kOS3DMaxHistoryRows) return;
                rowSet.insert({index, ordinal, kind, subIndex, relation});
            };

            // Caps: FirstShape is the base (the profile face's own image at
            // zMin), LastShape the top.
            try { emit(prism.FirstShape(), 0, 0, 1, 1); } catch (...) {}
            try { emit(prism.LastShape(), 0, 0, 2, 1); } catch (...) {}

            // Walls: one row per profile wire edge, per loop, in wire
            // construction order — the ordinal/subIndex convention the
            // header documents. Generated() on a prism edge is one of the
            // reliable OCCT histories; the phantom gate still guards it.
            int32_t ordinal = 0;
            for (TopExp_Explorer wires(face, TopAbs_WIRE); wires.More();
                 wires.Next(), ++ordinal) {
                int32_t subIndex = 1;
                for (TopExp_Explorer edges(wires.Current(), TopAbs_EDGE);
                     edges.More(); edges.Next(), ++subIndex) {
                    try {
                        const TopTools_ListOfShape &generated =
                            prism.Generated(edges.Current());
                        for (TopTools_ListIteratorOfListOfShape it(generated);
                             it.More(); it.Next()) {
                            emit(it.Value(), ordinal, 1, subIndex, 2);
                        }
                    } catch (...) {}
                }
            }

            std::vector<int32_t> packed;
            packed.reserve(rowSet.size() * 5);
            for (const auto &row : rowSet) {
                packed.insert(packed.end(), row.begin(), row.end());
            }
            history.rowCount = (NSInteger)rowSet.size();
            history.rows = [NSData dataWithBytes:packed.data()
                                          length:packed.size() * sizeof(int32_t)];
            history.truncatedByHeal = NO;
        }

        OCCTShape *out = [OCCTShape new];
        out->_shape = world;
        return out;
    } catch (...) {
        return nil;
    }
}

+ (nullable OCCTShape *)primitiveShapeOfKind:(NSInteger)kind
                                           a:(double)a
                                           b:(double)b
                                           c:(double)c
                                   transform:(nullable NSData *)transform {
    try {
        TopoDS_Shape shape;
        switch (kind) {
            case 0:  // box: Euclid centers x/z and puts the base on y=0
                if (a <= 0 || b <= 0 || c <= 0) return nil;
                shape = BRepPrimAPI_MakeBox(gp_Pnt(-a / 2.0, 0.0, -b / 2.0), a, c, b).Shape();
                break;
            case 1:  // cylinder: base on y=0, axis +Y
                if (a <= 0 || b <= 0) return nil;
                shape = BRepPrimAPI_MakeCylinder(
                    gp_Ax2(gp_Pnt(0.0, 0.0, 0.0), gp_Dir(0.0, 1.0, 0.0)), a, b).Shape();
                break;
            default:  // sphere: centered at (0, r, 0) so it rests on y=0
                if (a <= 0) return nil;
                shape = BRepPrimAPI_MakeSphere(gp_Pnt(0.0, a, 0.0), a).Shape();
                break;
        }
        if (transform != nil && transform.length >= 12 * sizeof(double)) {
            const double *m = (const double *)transform.bytes;  // row-major 3x4
            gp_Trsf t;
            t.SetValues(m[0], m[1], m[2],  m[3],
                        m[4], m[5], m[6],  m[7],
                        m[8], m[9], m[10], m[11]);
            shape = BRepBuilderAPI_Transform(shape, t, Standard_True).Shape();
        }
        OCCTShape *out = [OCCTShape new];
        out->_shape = shape;
        return out;
    } catch (...) {
        return nil;
    }
}

// Ancestry for the sweep-family makers (revolve, pipe): walls are Generated
// from the profile's wire edges — the SAME row convention the extrude
// documents (ordinal = loop, kind 1, subIndex = wire-edge construction
// ordinal, relation generated) — and the caps are the profile face's
// start/end images (FirstShape/LastShape; a full 360° revolve has none,
// which the in-result gate handles for free). The profile face went through
// a COPYING transform before the maker, so input edges map through the
// placer's ModifiedShape first. The result shape is the maker's own output
// (no unify/heal hop here).
//
// revolMaker: MakeRevol::Generated() gates on BRepSweep IsUsed(), which is
// FALSE for edges of a CLOSED (full 360°) sweep whose lateral face was built
// but never flagged used — the planar annuli of a washer, for one. The
// underlying BRepSweep_Revol::Shape(edge) has no such gate, so when
// Generated() comes back empty we query it directly; the in-result check in
// emit() keeps phantom shapes out, same as everywhere else.
/// Sweep one profile WIRE along `spine` into a solid with the section kept
/// NORMAL to the path and polyline corners MITRED.
///
/// This replaced BRepOffsetAPI_MakePipe (2026-09-02). MakePipe along a
/// polyline wire TRANSLATES the profile along each edge without turning it,
/// so on a curved spine every chord is a skewed prism whose section is
/// oblique to the path: measured V/(A·L) = mean of cos(chord angle) — 0.69
/// for a 9-chord quarter arc, ~0 around a full helix — while BRepCheck
/// still called the solid valid. MakePipeShell with RightCorner transitions
/// and profile correction gives exactly A·L for a polyline, and follows a
/// smooth spine with a corrected-Frenet frame.
/// An EXACT helix edge for a sweep spine: a straight line in the (angle,
/// height) parameter space of a cylindrical surface, whose 3D curve OCCT
/// then builds to tolerance (a helix is not a rational curve, so it is a
/// tight B-spline; the volume matches area × true length to 1e-6). 13
/// doubles: axis point, axis direction, reference direction (angle 0),
/// radius, pitch, turns, start angle — as `OCCTKernel.sweepSolid` packs
/// them. Positive pitch is right-handed about the axis. Also reports the
/// start point and the exact start tangent so the section can be placed.
static bool OS3DHelixWire(const double *h, TopoDS_Wire &outWire,
                          gp_Pnt &startPoint, gp_Vec &startTangent) {
    const gp_Pnt axisPoint(h[0], h[1], h[2]);
    const gp_Vec axisV(h[3], h[4], h[5]), refV(h[6], h[7], h[8]);
    const double radius = h[9], pitch = h[10], turns = h[11], theta0 = h[12];
    if (!(radius > 1e-9) || !(turns > 0) || std::fabs(pitch) < 1e-12) return false;
    if (axisV.Magnitude() < 1e-12 || refV.Magnitude() < 1e-12) return false;
    const gp_Ax3 frame(axisPoint, gp_Dir(axisV), gp_Dir(refV));      // Z = axis, X = angle 0
    Handle(Geom_CylindricalSurface) cylinder = new Geom_CylindricalSurface(frame, radius);
    // One turn is (u, v) += (2π, pitch) on the cylinder's parameter plane.
    Handle(Geom2d_Line) line = new Geom2d_Line(gp_Pnt2d(theta0, 0.0), gp_Dir2d(2.0 * M_PI, pitch));
    const double paramLength = turns * std::sqrt(4.0 * M_PI * M_PI + pitch * pitch);
    BRepBuilderAPI_MakeEdge me(line, cylinder, 0.0, paramLength);
    if (!me.IsDone()) return false;
    TopoDS_Edge edge = me.Edge();
    BRepLib::BuildCurves3d(edge, 1e-7);
    BRepBuilderAPI_MakeWire mw(edge);
    if (!mw.IsDone()) return false;
    outWire = mw.Wire();
    const gp_Vec X(frame.XDirection()), Y(frame.YDirection()), Z(frame.Direction());
    startPoint = axisPoint.Translated(X * (radius * std::cos(theta0)) + Y * (radius * std::sin(theta0)));
    startTangent = X * (-radius * std::sin(theta0)) + Y * (radius * std::cos(theta0))
                 + Z * (pitch / (2.0 * M_PI));
    return true;
}

static TopoDS_Shape OS3DPipeShellSolid(const TopoDS_Wire &profile,
                                       BRepOffsetAPI_MakePipeShell &mk,
                                       bool frenet = false) {
    // Frenet along a smooth helix keeps the section's orientation to the
    // axis constant (a thread); corrected Frenet handles polylines.
    mk.SetMode(frenet ? Standard_True : Standard_False);
    mk.SetTransitionMode(BRepBuilderAPI_RightCorner);    // mitre at corners
    // No WithContact / WithCorrection: both make the shell sweep a transformed
    // COPY of the profile and key its history by the copy's edges, which are
    // unreachable — the caller rotates the section normal to the spine itself
    // (and keeps the edge map for the history). The profile passed here must
    // already sit at the spine start, normal to its first segment.
    mk.Add(profile, Standard_False, Standard_False);
    mk.Build();
    if (!mk.IsDone()) return TopoDS_Shape();
    if (!mk.MakeSolid()) return TopoDS_Shape();
    return mk.Shape();
}

/// The face of `solid` bounded by every edge of `sectionWire` — the cap a
/// pipe shell's first/last section wire closes (PipeShell reports the
/// section WIRES as First/LastShape, and the history wants the faces).
static TopoDS_Shape OS3DCapFace(const TopoDS_Shape &solid, const TopoDS_Shape &section) {
    if (solid.IsNull() || section.IsNull()) return TopoDS_Shape();
    // After MakeSolid a pipe shell's First/LastShape ARE the cap faces.
    if (section.ShapeType() == TopAbs_FACE) return section;
    // A section wire: the cap is the face whose edge set EQUALS the wire's.
    // Merely containing them is not enough — a one-edge (circular) section's
    // only edge is shared with the lateral wall next to the cap, and that
    // wall would be found first (it was: caps landed on wall faces, every
    // face got two names, and the naming dropped them all as ambiguous).
    TopTools_IndexedMapOfShape wireEdges;
    TopExp::MapShapes(section, TopAbs_EDGE, wireEdges);
    if (wireEdges.Extent() == 0) return TopoDS_Shape();
    for (TopExp_Explorer f(solid, TopAbs_FACE); f.More(); f.Next()) {
        TopTools_IndexedMapOfShape faceEdges;
        TopExp::MapShapes(f.Current(), TopAbs_EDGE, faceEdges);
        if (faceEdges.Extent() != wireEdges.Extent()) continue;
        bool all = true;
        for (Standard_Integer i = 1; i <= wireEdges.Extent() && all; ++i) {
            if (!faceEdges.Contains(wireEdges(i))) all = false;
        }
        if (all) return f.Current();
    }
    return TopoDS_Shape();
}

static void OS3DFillSweepHistory(OCCTShapeHistory *history,
                                 BRepPrimAPI_MakeSweep &mk,
                                 BRepBuilderAPI_Transform &placer,
                                 const TopoDS_Face &localFace,
                                 const TopoDS_Shape &finalShape,
                                 BRepPrimAPI_MakeRevol *revolMaker = nullptr,
                                 const TopoDS_Shape &firstCap = TopoDS_Shape(),
                                 const TopoDS_Shape &lastCap = TopoDS_Shape(),
                                 const TopTools_DataMapOfShapeShape *profileToSection = nullptr) {
    if (history == nil || finalShape.IsNull()) return;
    TopTools_IndexedMapOfShape finalFaces;
    TopExp::MapShapes(finalShape, TopAbs_FACE, finalFaces);
    std::set<std::array<int32_t, 5>> rowSet;
    auto emit = [&](const TopoDS_Shape &shape, int32_t ordinal, int32_t kind,
                    int32_t subIndex, int32_t relation) {
        if (shape.IsNull() || rowSet.size() >= kOS3DMaxHistoryRows) return;
        if (shape.ShapeType() == TopAbs_FACE) {
            const int32_t index = (int32_t)finalFaces.FindIndex(shape);
            if (index > 0) rowSet.insert({index, ordinal, kind, subIndex, relation});
        } else if (shape.ShapeType() < TopAbs_FACE) {
            // Higher-level report: demote to faces, as everywhere.
            for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) {
                const int32_t index = (int32_t)finalFaces.FindIndex(ex.Current());
                if (index > 0 && rowSet.size() < kOS3DMaxHistoryRows) {
                    rowSet.insert({index, ordinal, kind, subIndex, relation});
                }
            }
        }
    };
    // Caps: a pipe shell hands its section WIRES back as First/LastShape, so
    // the caller finds the faces they bound and passes them in; the sweeps
    // whose First/LastShape are already faces pass nothing.
    try { emit(firstCap.IsNull() ? mk.FirstShape() : firstCap, 0, 0, 1, 1); } catch (...) {}
    try { emit(lastCap.IsNull() ? mk.LastShape() : lastCap, 0, 0, 2, 1); } catch (...) {}
    int32_t ordinal = 0;
    for (TopExp_Explorer wires(localFace, TopAbs_WIRE); wires.More();
         wires.Next(), ++ordinal) {
        int32_t subIndex = 1;
        for (TopExp_Explorer edges(wires.Current(), TopAbs_EDGE);
             edges.More(); edges.Next(), ++subIndex) {
            try {
                TopoDS_Shape placed = placer.ModifiedShape(edges.Current());
                if (placed.IsNull()) continue;
                // A pipe shell with profile correction works on a transformed
                // COPY of the profile, so its history is keyed by the first
                // section's edges, not the placed ones: translate when told.
                if (profileToSection != nullptr && profileToSection->IsBound(placed)) {
                    placed = profileToSection->Find(placed);
                }
                const TopTools_ListOfShape &generated = mk.Generated(placed);
                for (TopTools_ListIteratorOfListOfShape it(generated);
                     it.More(); it.Next()) {
                    emit(it.Value(), ordinal, 1, subIndex, 2);
                }
                if (generated.IsEmpty() && revolMaker != nullptr) {
                    // Shape(aGenS) is non-const only because it can build
                    // lazily; post-Build it is a lookup.
                    emit(const_cast<BRepSweep_Revol &>(revolMaker->Revol())
                             .Shape(placed),
                         ordinal, 1, subIndex, 2);
                }
            } catch (...) {
                // "No history for this edge" — never an error.
            }
        }
    }
    std::vector<int32_t> packed;
    packed.reserve(rowSet.size() * 5);
    for (const auto &row : rowSet) {
        packed.insert(packed.end(), row.begin(), row.end());
    }
    history.rowCount = (NSInteger)rowSet.size();
    history.rows = [NSData dataWithBytes:packed.data()
                                  length:packed.size() * sizeof(int32_t)];
    history.truncatedByHeal = NO;
}

// Ancestry for a ThruSections loft. Same row convention as the sweep family
// (ordinal = loop 0, kind 1 = edge, subIndex = wire-edge construction ordinal,
// relation generated), so `extrudeNames` names the walls from the FIRST
// section's profile edges and the caps from FirstShape/LastShape. ThruSections
// exposes `GeneratedFace(edge)` directly (one lateral face per section edge —
// no per-edge Generated list), so we query it on the first placed wire's
// edges; the in-result gate drops anything ThruSections rebuilt past
// recognition, leaving that wall to signatures.
static void OS3DFillLoftHistory(OCCTShapeHistory *history,
                                BRepOffsetAPI_ThruSections &mk,
                                const std::vector<TopoDS_Wire> &placedWires,
                                bool ruled,
                                const TopoDS_Shape &finalShape) {
    if (history == nil || finalShape.IsNull() || placedWires.empty()) return;
    TopTools_IndexedMapOfShape finalFaces;
    TopExp::MapShapes(finalShape, TopAbs_FACE, finalFaces);
    std::set<std::array<int32_t, 5>> rowSet;
    auto emit = [&](const TopoDS_Shape &shape, int32_t ordinal, int32_t kind,
                    int32_t subIndex, int32_t relation) {
        if (shape.IsNull() || rowSet.size() >= kOS3DMaxHistoryRows) return;
        if (shape.ShapeType() == TopAbs_FACE) {
            const int32_t index = (int32_t)finalFaces.FindIndex(shape);
            if (index > 0) rowSet.insert({index, ordinal, kind, subIndex, relation});
        } else if (shape.ShapeType() < TopAbs_FACE) {
            for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) {
                const int32_t index = (int32_t)finalFaces.FindIndex(ex.Current());
                if (index > 0 && rowSet.size() < kOS3DMaxHistoryRows) {
                    rowSet.insert({index, ordinal, kind, subIndex, relation});
                }
            }
        }
    };
    try { emit(mk.FirstShape(), 0, 0, 1, 1); } catch (...) {}
    try { emit(mk.LastShape(), 0, 0, 2, 1); } catch (...) {}
    // A smooth loft has ONE lateral face per first-section edge. A RULED loft
    // has one band per consecutive pair of sections, generated from the
    // earlier section's edges — so query every section but the last, with
    // the same edge ordinal, and both bands of a symmetric draft carry the
    // profile edge's name.
    const size_t wires = ruled ? placedWires.size() - 1 : 1;
    for (size_t w = 0; w < wires; ++w) {
        int32_t subIndex = 1;
        for (TopExp_Explorer edges(placedWires[w], TopAbs_EDGE); edges.More();
             edges.Next(), ++subIndex) {
            try {
                emit(mk.GeneratedFace(edges.Current()), 0, 1, subIndex, 2);
            } catch (...) {
                // "No face for this edge" — never an error.
            }
        }
    }
    std::vector<int32_t> packed;
    packed.reserve(rowSet.size() * 5);
    for (const auto &row : rowSet) {
        packed.insert(packed.end(), row.begin(), row.end());
    }
    history.rowCount = (NSInteger)rowSet.size();
    history.rows = [NSData dataWithBytes:packed.data()
                                  length:packed.size() * sizeof(int32_t)];
    history.truncatedByHeal = NO;
}

+ (nullable OCCTShape *)revolvedShapeWithOuterLoop:(NSData *)outerLoop
                                        outerConic:(nullable NSData *)outerConic
                                             holes:(NSArray<NSData *> *)holes
                                        holeConics:(nullable NSData *)holeConics
                                     outerSegments:(nullable NSData *)outerSegments
                                      holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                             basis:(OCCTPlaneBasis *)basis
                                              axis:(NSData *)axis
                                             angle:(double)angle {
    return [self revolvedShapeWithOuterLoop:outerLoop outerConic:outerConic
                                      holes:holes holeConics:holeConics
                              outerSegments:outerSegments
                               holeSegments:holeSegments basis:basis
                                       axis:axis angle:angle history:nil];
}

+ (nullable OCCTShape *)revolvedShapeWithOuterLoop:(NSData *)outerLoop
                                        outerConic:(nullable NSData *)outerConic
                                             holes:(NSArray<NSData *> *)holes
                                        holeConics:(nullable NSData *)holeConics
                                     outerSegments:(nullable NSData *)outerSegments
                                      holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                             basis:(OCCTPlaneBasis *)basis
                                              axis:(NSData *)axis
                                             angle:(double)angle
                                           history:(nullable OCCTShapeHistory *)history {
    if (axis.length < 6 * sizeof(double)) return nil;
    if (!(fabs(angle) > 1e-9)) return nil;
    const double *a = (const double *)axis.bytes;
    const double dl = sqrt(a[3]*a[3] + a[4]*a[4] + a[5]*a[5]);
    if (!(dl > 1e-12)) return nil;
    try {
        const TopoDS_Face face = OS3DProfileFace(outerLoop, outerConic, holes,
                                                 holeConics, outerSegments,
                                                 holeSegments, 0.0);
        if (face.IsNull()) return nil;
        // Into world space first, because the axis is given in world space —
        // cheaper and less error-prone than mapping the axis into the profile's
        // own frame.
        BRepBuilderAPI_Transform placer(face, OS3DBasisTransform(basis),
                                        Standard_True);
        const TopoDS_Shape worldFace = placer.Shape();
        gp_Ax1 ax(gp_Pnt(a[0], a[1], a[2]), gp_Dir(a[3]/dl, a[4]/dl, a[5]/dl));
        BRepPrimAPI_MakeRevol mk(worldFace, ax, angle);
        mk.Build();
        if (!mk.IsDone()) return nil;
        const TopoDS_Shape solid = mk.Shape();
        if (solid.IsNull()) return nil;
        OS3DFillSweepHistory(history, mk, placer, face, solid, &mk);
        OCCTShape *out = [OCCTShape new];
        out->_shape = solid;
        return out;
    } catch (...) {
        // A profile that crosses or touches the axis is a legitimate user
        // mistake; the mesh path reports it as empty geometry.
        return nil;
    }
}

+ (nullable OCCTShape *)loftedShapeWithOuterLoops:(NSArray<NSData *> *)outerLoops
                                      outerConics:(NSArray<NSData *> *)outerConics
                                    outerSegments:(NSArray<NSData *> *)outerSegments
                                           bases:(NSArray<OCCTPlaneBasis *> *)bases {
    return [self loftedShapeWithOuterLoops:outerLoops outerConics:outerConics
                             outerSegments:outerSegments bases:bases history:nil];
}

+ (nullable OCCTShape *)loftedShapeWithOuterLoops:(NSArray<NSData *> *)outerLoops
                                      outerConics:(NSArray<NSData *> *)outerConics
                                    outerSegments:(NSArray<NSData *> *)outerSegments
                                           bases:(NSArray<OCCTPlaneBasis *> *)bases
                                          history:(nullable OCCTShapeHistory *)history {
    return [self loftedShapeWithOuterLoops:outerLoops outerConics:outerConics
                             outerSegments:outerSegments bases:bases
                                     ruled:NO history:history];
}

+ (nullable OCCTShape *)loftedShapeWithOuterLoops:(NSArray<NSData *> *)outerLoops
                                      outerConics:(NSArray<NSData *> *)outerConics
                                    outerSegments:(NSArray<NSData *> *)outerSegments
                                           bases:(NSArray<OCCTPlaneBasis *> *)bases
                                            ruled:(BOOL)ruled
                                          history:(nullable OCCTShapeHistory *)history {
    if (outerLoops.count < 2 || bases.count != outerLoops.count) return nil;
    try {
        BRepOffsetAPI_ThruSections mk(Standard_True /* solid */,
                                      ruled ? Standard_True : Standard_False);
        std::vector<TopoDS_Wire> placedWires;
        for (NSUInteger i = 0; i < outerLoops.count; ++i) {
            NSData *conic = (i < outerConics.count && outerConics[i].length > 0)
                ? outerConics[i] : nil;
            NSData *segs = (i < outerSegments.count && outerSegments[i].length > 0)
                ? outerSegments[i] : nil;
            TopoDS_Wire wire;
            if (conic != nil && conic.length >= 5 * sizeof(double)) {
                wire = ConicWire((const double *)conic.bytes, 0.0);
            }
            if (wire.IsNull() && segs != nil) wire = SegWire(segs, 0.0);
            if (wire.IsNull()) {
                if (outerLoops[i].length < 3 * 2 * (NSInteger)sizeof(double)) return nil;
                wire = PolyWire(outerLoops[i], 0.0);
            }
            if (wire.IsNull()) return nil;
            const TopoDS_Shape placed = BRepBuilderAPI_Transform(
                wire, OS3DBasisTransform(bases[i]), Standard_True).Shape();
            const TopoDS_Wire placedWire = TopoDS::Wire(placed);
            placedWires.push_back(placedWire);
            mk.AddWire(placedWire);
        }
        mk.Build();
        if (!mk.IsDone()) return nil;
        const TopoDS_Shape solid = mk.Shape();
        if (solid.IsNull()) return nil;
        OS3DFillLoftHistory(history, mk, placedWires, ruled, solid);
        OCCTShape *out = [OCCTShape new];
        out->_shape = solid;
        return out;
    } catch (...) {
        return nil;
    }
}

+ (nullable OCCTShape *)sweptShapeWithOuterLoop:(NSData *)outerLoop
                                     outerConic:(nullable NSData *)outerConic
                                          holes:(NSArray<NSData *> *)holes
                                     holeConics:(nullable NSData *)holeConics
                                  outerSegments:(nullable NSData *)outerSegments
                                   holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                          basis:(OCCTPlaneBasis *)basis
                                          spine:(NSData *)spine {
    return [self sweptShapeWithOuterLoop:outerLoop outerConic:outerConic
                                   holes:holes holeConics:holeConics
                           outerSegments:outerSegments
                            holeSegments:holeSegments basis:basis
                                   spine:spine helix:nil history:nil];
}

+ (nullable OCCTShape *)sweptShapeWithOuterLoop:(NSData *)outerLoop
                                     outerConic:(nullable NSData *)outerConic
                                          holes:(NSArray<NSData *> *)holes
                                     holeConics:(nullable NSData *)holeConics
                                  outerSegments:(nullable NSData *)outerSegments
                                   holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                          basis:(OCCTPlaneBasis *)basis
                                          spine:(NSData *)spine
                                          helix:(nullable NSData *)helix
                                        history:(nullable OCCTShapeHistory *)history {
    const NSUInteger points = spine.length / (3 * sizeof(double));
    if (points < 2) return nil;
    const double *s = (const double *)spine.bytes;
    const bool exactHelix = (helix != nil && helix.length >= 13 * sizeof(double));
    try {
        const TopoDS_Face face = OS3DProfileFace(outerLoop, outerConic, holes,
                                                 holeConics, outerSegments,
                                                 holeSegments, 0.0);
        if (face.IsNull()) return nil;
        BRepBuilderAPI_Transform placer(face, OS3DBasisTransform(basis),
                                        Standard_True);
        const TopoDS_Shape worldFace = placer.Shape();

        // The spine: an EXACT helix when the spec is given (the polyline then
        // only came along for the render), else the polyline itself. Either
        // way the section is placed at the spine's start, normal to its true
        // opening tangent.
        TopoDS_Wire spineWire;
        gp_Pnt startPoint(s[0], s[1], s[2]);
        gp_Vec startTangent(startPoint, gp_Pnt(s[3], s[4], s[5]));
        if (exactHelix) {
            if (!OS3DHelixWire((const double *)helix.bytes, spineWire, startPoint, startTangent)) return nil;
        } else {
            BRepBuilderAPI_MakePolygon poly;
            for (NSUInteger i = 0; i < points; ++i) {
                poly.Add(gp_Pnt(s[3*i], s[3*i+1], s[3*i+2]));
            }
            if (!poly.IsDone()) return nil;
            spineWire = poly.Wire();
        }
        if (spineWire.IsNull()) return nil;

        // The OUTER wire sweeps into the solid (see OS3DPipeShellSolid for why
        // not MakePipe); each hole wire sweeps the same way and is cut out.
        //
        // The section is first turned NORMAL to the spine's opening segment by
        // a transform of our own (pivot: the spine start), never by the pipe
        // shell's WithCorrection — that sweeps a transformed COPY whose edges
        // key the history and are unreachable. Our rotator's ModifiedShape
        // keeps placed edge -> section edge, so face ancestry survives. When
        // the profile is already normal (every exec sweep is), nothing moves.
        TopoDS_Face sectionFace = TopoDS::Face(worldFace);
        TopTools_DataMapOfShapeShape placedToSection;
        {
            const gp_Pnt start = startPoint;
            const gp_Vec along = startTangent;
            Handle(Geom_Plane) plane = Handle(Geom_Plane)::DownCast(BRep_Tool::Surface(sectionFace));
            if (!plane.IsNull() && along.Magnitude() > 1e-12) {
                const gp_Dir t(along);
                gp_Dir n = plane->Axis().Direction();
                if (n.Dot(t) < 0) n.Reverse();
                const double cosine = n.Dot(t);
                const gp_Vec axis = gp_Vec(n).Crossed(gp_Vec(t));
                if (cosine < 1.0 - 1e-12 && axis.Magnitude() > 1e-12) {
                    gp_Trsf rot;
                    rot.SetRotation(gp_Ax1(start, gp_Dir(axis)),
                                    std::acos(std::max(-1.0, std::min(1.0, cosine))));
                    BRepBuilderAPI_Transform rotator(sectionFace, rot, Standard_True);
                    for (TopExp_Explorer e(sectionFace, TopAbs_EDGE); e.More(); e.Next()) {
                        placedToSection.Bind(e.Current(), rotator.ModifiedShape(e.Current()));
                    }
                    sectionFace = TopoDS::Face(rotator.Shape());
                }
            }
        }
        const TopoDS_Wire outerWire = BRepTools::OuterWire(sectionFace);
        if (outerWire.IsNull()) return nil;
        BRepOffsetAPI_MakePipeShell mk(spineWire);
        TopoDS_Shape solid = OS3DPipeShellSolid(outerWire, mk, exactHelix);
        if (solid.IsNull()) return nil;
        const TopoDS_Shape firstCap = OS3DCapFace(solid, mk.FirstShape());
        const TopoDS_Shape lastCap = OS3DCapFace(solid, mk.LastShape());
        const TopTools_DataMapOfShapeShape &profileToSection = placedToSection;
        for (TopExp_Explorer w(sectionFace, TopAbs_WIRE); w.More(); w.Next()) {
            if (w.Current().IsSame(outerWire)) continue;
            BRepOffsetAPI_MakePipeShell hm(spineWire);
            const TopoDS_Shape tube = OS3DPipeShellSolid(TopoDS::Wire(w.Current()), hm, exactHelix);
            if (tube.IsNull()) return nil;
            BRepAlgoAPI_Cut cut(solid, tube);
            cut.Build();
            if (!cut.IsDone() || cut.Shape().IsNull()) return nil;
            solid = cut.Shape();
        }
        OS3DFillSweepHistory(history, mk, placer, face, solid, nullptr, firstCap, lastCap,
                             &profileToSection);
        OCCTShape *out = [OCCTShape new];
        out->_shape = solid;
        return out;
    } catch (...) {
        return nil;
    }
}

+ (nullable OCCTShape *)mirroredShape:(OCCTShape *)shape
                              originX:(double)ox
                              originY:(double)oy
                              originZ:(double)oz
                              normalX:(double)nx
                              normalY:(double)ny
                              normalZ:(double)nz {
    if (shape == nil) return nil;
    const double len = sqrt(nx * nx + ny * ny + nz * nz);
    if (!(len > 1e-12)) return nil;
    try {
        // gp_Ax2's main direction is the plane NORMAL; SetMirror reflects in
        // the plane that system spans, which is what a mirror feature means.
        gp_Ax2 ax(gp_Pnt(ox, oy, oz), gp_Dir(nx / len, ny / len, nz / len));
        gp_Trsf t;
        t.SetMirror(ax);
        TopoDS_Shape out = BRepBuilderAPI_Transform(shape->_shape, t, Standard_True).Shape();
        if (out.IsNull()) return nil;
        OCCTShape *result = [OCCTShape new];
        result->_shape = out;
        return result;
    } catch (...) {
        return nil;
    }
}

+ (nullable OCCTShape *)transformedShape:(OCCTShape *)shape
                                  matrix:(NSData *)transform {
    if (shape == nil || transform.length < 12 * sizeof(double)) return nil;
    try {
        const double *m = (const double *)transform.bytes;  // row-major 3x4
        gp_Trsf t;
        t.SetValues(m[0], m[1], m[2],  m[3],
                    m[4], m[5], m[6],  m[7],
                    m[8], m[9], m[10], m[11]);
        TopoDS_Shape moved = BRepBuilderAPI_Transform(shape->_shape, t, Standard_True).Shape();
        if (moved.IsNull()) return nil;
        OCCTShape *out = [OCCTShape new];
        out->_shape = moved;
        return out;
    } catch (...) {
        return nil;
    }
}

+ (nullable OCCTShape *)unifiedShape:(OCCTShape *)shape {
    if (shape == nil || shape->_shape.IsNull()) return nil;
    const TopoDS_Shape result = OS3DUnified(shape->_shape);
    if (result.IsNull()) return nil;
    OCCTShape *out = [OCCTShape new];
    out->_shape = result;
    return out;
}

// MARK: - Kernel-history ancestry (docs/TOPO_NAMING_HISTORY_DESIGN.md step 1)

// One (input sub-shape → builder-output shape) history edge, held with the
// live TopoDS target until the unify/heal hops decide what it maps to in the
// FINAL shape. Mined reliability facts baked in below (from FreeCAD's Mapper
// catalog, re-derived — see the playbook's licensing rules):
//   - Modified()/Generated() THROW on sub-shapes some builders don't know;
//     a throw means "no history", never an error.
//   - Builders can report a HIGHER-level result ("this face generated the
//     whole solid"); demote to faces instead of trusting it.
//   - History can name phantoms that never reach the result; every emitted
//     row is checked against the final face map first.
struct OS3DHistEdge {
    TopoDS_Shape target;
    int32_t ordinal;
    int32_t kind;      // 0 = face, 1 = edge (of the input)
    int32_t subIndex;  // 1-based in that input's map of `kind`
    int32_t relation;  // 1 = modified, 2 = generated
};

static const size_t kOS3DMaxHistoryRows = 4096;

// Harvest a maker's own history while it is still alive. Works for ANY
// BRepBuilderAPI_MakeShape descendant — booleans, blends, thick-solid,
// defeaturing — which is what lets every modifier op reuse one collector.
static void OS3DCollectMakerHistory(BRepBuilderAPI_MakeShape &builder,
                                    const std::vector<TopoDS_Shape> &inputs,
                                    std::vector<OS3DHistEdge> &edges) {
    for (int32_t ordinal = 0; ordinal < (int32_t)inputs.size(); ++ordinal) {
        const struct { TopAbs_ShapeEnum type; int32_t kind; } kinds[] = {
            {TopAbs_FACE, 0}, {TopAbs_EDGE, 1}};
        for (const auto &k : kinds) {
            TopTools_IndexedMapOfShape map;
            TopExp::MapShapes(inputs[(size_t)ordinal], k.type, map);
            for (Standard_Integer i = 1; i <= map.Extent(); ++i) {
                const TopoDS_Shape &sub = map(i);
                for (int32_t relation : {1, 2}) {
                    try {
                        const TopTools_ListOfShape &list = relation == 1
                            ? builder.Modified(sub) : builder.Generated(sub);
                        for (TopTools_ListIteratorOfListOfShape it(list);
                             it.More(); it.Next()) {
                            edges.push_back({it.Value(), ordinal, k.kind,
                                             (int32_t)i, relation});
                        }
                    } catch (...) {
                        // "No history for this sub-shape", reported loudly.
                    }
                }
            }
        }
    }
}

// Compose builder edges across the unify hop, validate every row against the
// FINAL shape, add same-face survivals, and pack the result.
static void OS3DFillHistory(OCCTShapeHistory *history,
                            const std::vector<OS3DHistEdge> &edges,
                            const std::vector<TopoDS_Shape> &inputs,
                            const Handle(BRepTools_History) &unifyHistory,
                            const TopoDS_Shape &finalShape,
                            BOOL truncatedByHeal,
                            const TopTools_DataMapOfShapeShape *copied = nullptr) {
    TopTools_IndexedMapOfShape finalFaces;
    TopExp::MapShapes(finalShape, TopAbs_FACE, finalFaces);
    // A builder-result face as the unify hop saw it: its copy, when the
    // unify ran on a copy (the boolean), else the face itself.
    auto through = [&](const TopoDS_Shape &face) -> TopoDS_Shape {
        return (copied != nullptr && copied->IsBound(face)) ? copied->Find(face) : face;
    };

    std::set<std::array<int32_t, 5>> rowSet;

    // Final face indices an intermediate face maps to: its unify images
    // when the seam merge rewrote it, else the face itself. Empty when the
    // face never reached the final shape — the phantom gate.
    auto finalIndices = [&](const TopoDS_Shape &builderFace) {
        std::vector<int32_t> out;
        const TopoDS_Shape face = through(builderFace);
        if (!unifyHistory.IsNull()) {
            try {
                const TopTools_ListOfShape &images = unifyHistory->Modified(face);
                for (TopTools_ListIteratorOfListOfShape it(images);
                     it.More(); it.Next()) {
                    const int32_t index = finalFaces.FindIndex(it.Value());
                    if (index > 0) out.push_back(index);
                }
            } catch (...) {}
        }
        if (out.empty()) {
            const int32_t index = finalFaces.FindIndex(face);
            if (index > 0) out.push_back(index);
        }
        return out;
    };

    auto emitFace = [&](const TopoDS_Shape &face, const OS3DHistEdge &edge,
                        int32_t relation) {
        for (int32_t index : finalIndices(face)) {
            if (rowSet.size() >= kOS3DMaxHistoryRows) return;
            rowSet.insert({index, edge.ordinal, edge.kind, edge.subIndex, relation});
        }
    };

    for (const OS3DHistEdge &edge : edges) {
        const TopAbs_ShapeEnum type = edge.target.ShapeType();
        if (type == TopAbs_FACE) {
            emitFace(edge.target, edge, edge.relation);
        } else if (type < TopAbs_FACE) {
            // Higher-level report (solid/shell/compound): demote to faces.
            for (TopExp_Explorer ex(edge.target, TopAbs_FACE); ex.More(); ex.Next()) {
                emitFace(ex.Current(), edge, edge.relation);
            }
        }
        // Wire/edge/vertex targets: edge-level ancestry is a later step.
    }

    // Faces the builder never mentions: either they survive untouched
    // (relation 0) or only the unify hop rewrote them (relation 1). Recorded
    // per input FACE so a result face merged from both operands lists both.
    for (int32_t ordinal = 0; ordinal < (int32_t)inputs.size(); ++ordinal) {
        TopTools_IndexedMapOfShape faces;
        TopExp::MapShapes(inputs[(size_t)ordinal], TopAbs_FACE, faces);
        for (Standard_Integer i = 1; i <= faces.Extent(); ++i) {
            const TopoDS_Shape face = through(faces(i));
            const int32_t direct = finalFaces.FindIndex(face);
            if (direct > 0 && rowSet.size() < kOS3DMaxHistoryRows) {
                rowSet.insert({direct, ordinal, 0, (int32_t)i, 0});
                continue;
            }
            if (unifyHistory.IsNull()) continue;
            try {
                const TopTools_ListOfShape &images = unifyHistory->Modified(face);
                for (TopTools_ListIteratorOfListOfShape it(images);
                     it.More(); it.Next()) {
                    const int32_t index = finalFaces.FindIndex(it.Value());
                    if (index > 0 && rowSet.size() < kOS3DMaxHistoryRows) {
                        rowSet.insert({index, ordinal, 0, (int32_t)i, 1});
                    }
                }
            } catch (...) {}
        }
    }

    std::vector<int32_t> packed;
    packed.reserve(rowSet.size() * 5);
    for (const auto &row : rowSet) {
        packed.insert(packed.end(), row.begin(), row.end());
    }
    history.rowCount = (NSInteger)rowSet.size();
    history.rows = [NSData dataWithBytes:packed.data()
                                  length:packed.size() * sizeof(int32_t)];
    history.truncatedByHeal = truncatedByHeal;
}

// Defined with the blend machinery below; declared here because the
// single-input modifier ops (defeaturing, shell) sit between the two.
static void OS3DFillModifierHistory(OCCTShapeHistory *history,
                                    BRepBuilderAPI_MakeShape &maker,
                                    const TopoDS_Shape &input,
                                    const TopoDS_Shape &finalShape);

// Same-domain unification, exposing the unifier's own history for the
// ancestry composition above. Mirrors OS3DUnified (which stays the plain
// path); returns the input on any failure, with a null history.
static TopoDS_Shape OS3DUnifiedWithHistory(const TopoDS_Shape &shape,
                                           Handle(BRepTools_History) &outHistory) {
    try {
        ShapeUpgrade_UnifySameDomain unifier(
            shape, Standard_True, Standard_True, Standard_False);
        unifier.Build();
        const TopoDS_Shape result = unifier.Shape();
        if (result.IsNull()) return shape;
        outHistory = unifier.History();
        return result;
    } catch (...) {
        return shape;
    }
}

#if DEBUG
static bool gOS3DBooleanUnmergedFallback = true;
#endif

+ (nullable OCCTShape *)booleanOfShape:(OCCTShape *)a
                             withShape:(OCCTShape *)b
                                    op:(NSInteger)op
                                status:(nullable OCCTOpStatus *)status {
    return [self booleanOfShape:a withShape:b op:op status:status history:nil];
}

+ (nullable OCCTShape *)booleanOfShape:(OCCTShape *)a
                             withShape:(OCCTShape *)b
                                    op:(NSInteger)op
                                status:(nullable OCCTOpStatus *)status
                               history:(nullable OCCTShapeHistory *)history {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"missing operand");
    if (a == nil || b == nil) return nil;
    try {
        // Garbage in was how "solid ops corrupt": an invalid operand doesn't
        // make the boolean FAIL, it makes the result subtly wrong, and that
        // result becomes a body's source of truth and gets persisted. So
        // check both operands up front (with one healing attempt each) —
        // the same gate FreeCAD's boolean wrapper applies
        // (docs/FREECAD_PLAYBOOK.md B1).
        TopoDS_Shape sa = a->_shape, sb = b->_shape;
        if (!OS3DFiniteBounds(sa) || !OS3DFiniteBounds(sb)) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"an operand has empty or non-finite geometry");
            return nil;
        }
        if (!OS3DIsValid(sa)) {
            sa = OS3DHealAndValidate(sa);
            if (sa.IsNull()) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                              @"the target solid is invalid");
                return nil;
            }
        }
        if (!OS3DIsValid(sb)) {
            sb = OS3DHealAndValidate(sb);
            if (sb.IsNull()) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                              @"the tool solid is invalid");
                return nil;
            }
        }

        // Fuzzy tolerance scaled to the operands' combined extent — the
        // near-coincident faces two snapped-together bodies meet on need a
        // merge tolerance proportional to the model, and Precision::Confusion
        // alone (1e-7) is far below it. Retry once at 10× before giving up:
        // a bounded ladder, not a loop.
        Bnd_Box bounds;
        BRepBndLib::Add(sa, bounds);
        BRepBndLib::Add(sb, bounds);
        const double baseFuzzy =
            sqrt(bounds.SquareExtent()) * Precision::Confusion();

        TopTools_ListOfShape args, tools;
        args.Append(sa);
        tools.Append(sb);
        const BOPAlgo_Operation operation =
            op == 0 ? BOPAlgo_FUSE : (op == 1 ? BOPAlgo_CUT : BOPAlgo_COMMON);

        TopoDS_Shape result;
        std::string errorDump;
        std::vector<OS3DHistEdge> histEdges;
        const std::vector<TopoDS_Shape> historyInputs = {sa, sb};
        for (const double fuzzy : {baseFuzzy, baseFuzzy * 10.0}) {
            BRepAlgoAPI_BooleanOperation builder;
            builder.SetArguments(args);
            builder.SetTools(tools);
            builder.SetOperation(operation);
            // Non-destructive: never let the builder modify the input
            // TShapes — handles are aliased by undo snapshots.
            builder.SetNonDestructive(Standard_True);
            builder.SetFuzzyValue(fuzzy);
            OS3DDeadlineProgress *deadline =
                new OS3DDeadlineProgress(kOS3DOpDeadlineSeconds);
            Handle(Message_ProgressIndicator) progress(deadline);
            builder.Build(progress->Start());
            if (deadline->Fired()) {
                // A hang is not cured by more fuzz — abandon the ladder.
                errorDump = "the operation exceeded the kernel deadline";
                break;
            }
            if (builder.IsDone() && !builder.HasErrors()) {
                result = builder.Shape();
                // Harvest ancestry NOW — the builder owns its history and
                // dies with this scope.
                if (history != nil) {
                    OS3DCollectMakerHistory(builder, historyInputs, histEdges);
                }
                break;
            }
            std::ostringstream os;
            builder.DumpErrors(os);
            errorDump = os.str();
        }
        if (result.IsNull()) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          [NSString stringWithFormat:@"boolean failed: %s",
                           errorDump.c_str()]);
            return nil;
        }

        // Normalize: unwrap the compound, merge coplanar seams, validate.
        // Downstream ops (shell, fillet) receive this shape as their input
        // and are only specified for a SOLID — feeding them the raw compound
        // was review finding R4-O3.
        int solidCount = 0;
        const TopoDS_Shape single = OS3DExtractSingleSolid(result, solidCount);
        if (solidCount == 0) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"the operation leaves no solid");
            return nil;
        }
        // Merge same-domain faces and edges on a COPY of the result.
        // ShapeUpgrade_UnifySameDomain rewrites edges of the shape it is given
        // in place (safe-input mode does not stop it), and a boolean result
        // shares its untouched sub-shapes with the operands: the stored
        // bodies. Practice problem 18.19 (2026-09-17): the Ø6 bore through
        // a boss whose face a window cut had split built valid; the face
        // merge, which merged nothing, left it invalid and the TARGET BODY
        // invalid too, so the heal passed it with a 12.9 mm tolerance and
        // every later cut on the part removed nothing. The copy keeps the
        // render mesh, so untouched faces need no new tessellation.
        const TopoDS_Shape built = solidCount == 1 ? single : result;
        Handle(BRepTools_History) unifyHistory;
        TopTools_DataMapOfShapeShape copied;
        TopoDS_Shape unified;
        BRepBuilderAPI_Copy copier(built, Standard_False, Standard_True);
        if (copier.IsDone() && !copier.Shape().IsNull()) {
            unified = history != nil ? OS3DUnifiedWithHistory(copier.Shape(), unifyHistory)
                                     : OS3DUnified(copier.Shape());
            if (history != nil) {
                for (TopExp_Explorer ex(built, TopAbs_FACE); ex.More(); ex.Next()) {
                    if (!copied.IsBound(ex.Current())) {
                        copied.Bind(ex.Current(), copier.ModifiedShape(ex.Current()));
                    }
                }
            }
        } else {
            unified = built;
        }
        bool unifiedValid = OS3DIsValid(unified);
        // When the merge itself broke a valid result (18.19's window cut
        // after its boss: the merged boss face comes out unorientable), keep
        // the result unmerged.
        bool keepUnmerged = !unifiedValid;
#if DEBUG
        keepUnmerged = keepUnmerged && gOS3DBooleanUnmergedFallback;
#endif
        if (keepUnmerged && !unified.IsSame(built) && OS3DIsValid(built)) {
            unified = built;
            unifiedValid = true;
            unifyHistory.Nullify();
            copied.Clear();
        }
        // Before the heal, which can change sub-shape tolerances in place.
        const double preHealTolerance = OS3DMaxTolerance(unified);
        TopoDS_Shape normalized = unifiedValid ? unified : OS3DHealAndValidate(unified);
        if (normalized.IsNull()) {
            OS3DSetStatus(status, OCCTOpCodeInvalidResult,
                          @"boolean result failed validity checking");
            return nil;
        }
        // A heal that can only pass BRepCheck by loosening the tolerance to
        // part size is not a repair: every later boolean reads the loosened
        // zone as touching and silently does nothing. Practice problem 18.19
        // (2026-09-16): a window pocket whose floor arc lies on a Ø13 boss,
        // cut after the boss. OCCT gave the coincident R6.5 edge a pcurve
        // 11.5 mm off on the boss face (an invalid result), ShapeFix passed it
        // with a 12.87 mm tolerance and the right volume, and the next four
        // cuts removed nothing, reported ok. Refuse here, at the op that made
        // it. Only a HEALED result: OCCT's boolean can return a valid result
        // with a large tolerance of its own, and later booleans on that are
        // fine (practice problem 15.6's bent pin, 2.44 mm, where cross-holes
        // near and far from the bend remove exactly the reference volume).
        if (!normalized.IsSame(unified)) {
            Bnd_Box resultBounds;
            BRepBndLib::Add(normalized, resultBounds);
            const double before = std::max({preHealTolerance, OS3DMaxTolerance(sa), OS3DMaxTolerance(sb)});
            const double limit = std::max(1e-2 * sqrt(resultBounds.SquareExtent()), 10.0 * before);
            const double healedTolerance = OS3DMaxTolerance(normalized);
            if (healedTolerance > limit) {
                OS3DSetStatus(status, OCCTOpCodeInvalidResult,
                              [NSString stringWithFormat:
                               @"the result could only be repaired by loosening its tolerance to "
                               @"%.3g mm, too loose to build on (faces meeting tangentially or "
                               @"coinciding)", healedTolerance]);
                return nil;
            }
        }
        if (history != nil) {
            // Rows are validated against the shape actually returned, so a
            // heal that rebuilt faces just drops their rows; the flag says
            // coverage may have holes.
            OS3DFillHistory(history, histEdges, historyInputs, unifyHistory,
                            normalized, !normalized.IsSame(unified),
                            copied.IsEmpty() ? nullptr : &copied);
        }

        if (solidCount > 1) {
            OS3DSetStatus(status, OCCTOpCodeMultiSolid, nil);
            if (status != nil) status.solidCount = solidCount;
        } else {
            OS3DSetStatus(status, OCCTOpCodeOK, nil);
        }
        OCCTShape *out = [OCCTShape new];
        out->_shape = normalized;
        return out;
    } catch (Standard_Failure &e) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                      [NSString stringWithFormat:@"%s", e.GetMessageString()]);
        return nil;
    } catch (...) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"kernel exception");
        return nil;
    }
}

/// Faces the user actually picked: for EACH picked point, the single NEAREST
/// face (when within `tolerance`). Same rationale as `OS3DNearestEdges` — at
/// 2% of the body diagonal, the old all-within-tolerance rule opened or
/// deleted the face on the OPPOSITE side of a thin plate.
///
/// Distance is the EXACT distance to the trimmed face
/// (`BRepExtrema_DistShapeShape`), not to samples on the surface's UV
/// bounding box. The old 5×5 UV grid measured the un-trimmed surface, so a
/// pick at the centroid of a triangular face could land 10+ mm from every
/// sample and be rejected, while a point under an overhanging face's UV box
/// could match a face it isn't even on (review finding R4-O2, closed here —
/// docs/FREECAD_PLAYBOOK.md FT1).
static std::set<Standard_Integer> OS3DNearestFaces(
    const TopTools_IndexedMapOfShape &faceMap,
    const double *pts, NSUInteger count, double tolerance
) {
    std::vector<double> bestDistance(count, std::numeric_limits<double>::max());
    std::vector<Standard_Integer> bestFace(count, 0);

    for (NSUInteger k = 0; k < count; ++k) {
        const TopoDS_Shape vertex = BRepBuilderAPI_MakeVertex(
            gp_Pnt(pts[3*k], pts[3*k+1], pts[3*k+2])).Shape();
        for (Standard_Integer i = 1; i <= faceMap.Extent(); ++i) {
            try {
                BRepExtrema_DistShapeShape dist(vertex, faceMap(i));
                if (!dist.IsDone() || dist.NbSolution() == 0) continue;
                const double d = dist.Value();
                if (d < bestDistance[k]) { bestDistance[k] = d; bestFace[k] = i; }
            } catch (...) {
                continue;  // an unmeasurable face simply can't win the pick
            }
        }
    }

    std::set<Standard_Integer> chosen;
    for (NSUInteger k = 0; k < count; ++k) {
        if (bestFace[k] != 0 && bestDistance[k] <= tolerance) {
            chosen.insert(bestFace[k]);
        }
    }
    return chosen;
}

+ (nullable OCCTShape *)defeaturedShape:(OCCTShape *)shape
                                 atWorldPoints:(NSData *)worldPoints
                                     tolerance:(double)tolerance
                                        status:(nullable OCCTOpStatus *)status {
    return [self defeaturedShape:shape atWorldPoints:worldPoints
                       tolerance:tolerance status:status history:nil];
}

+ (nullable OCCTShape *)defeaturedShape:(OCCTShape *)shape
                          atWorldPoints:(NSData *)worldPoints
                              tolerance:(double)tolerance
                                 status:(nullable OCCTOpStatus *)status
                                history:(nullable OCCTShapeHistory *)history {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"no input");
    if (shape == nil) return nil;
    const NSUInteger count = worldPoints.length / (3 * sizeof(double));
    if (count == 0) return nil;
    const double *pts = (const double *)worldPoints.bytes;

    try {
        if (!OS3DFiniteBounds(shape->_shape)) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"the body has empty or non-finite geometry");
            return nil;
        }
        TopTools_IndexedMapOfShape faceMap;
        TopExp::MapShapes(shape->_shape, TopAbs_FACE, faceMap);
        TopTools_ListOfShape toRemove;
        for (Standard_Integer i : OS3DNearestFaces(faceMap, pts, count, tolerance)) {
            toRemove.Append(TopoDS::Face(faceMap(i)));
        }
        if (toRemove.IsEmpty()) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched,
                          @"no face within tolerance of the pick");
            return nil;
        }

        BRepAlgoAPI_Defeaturing defeat;
        defeat.SetShape(shape->_shape);
        defeat.AddFacesToRemove(toRemove);
        OS3DDeadlineProgress *deadline =
            new OS3DDeadlineProgress(kOS3DOpDeadlineSeconds);
        Handle(Message_ProgressIndicator) progress(deadline);
        defeat.Build(progress->Start());
        if (deadline->Fired()) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"the operation exceeded the kernel deadline");
            return nil;
        }
        if (!defeat.IsDone() || defeat.HasErrors()) {
            std::ostringstream os;
            defeat.DumpErrors(os);
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          [NSString stringWithFormat:
                           @"the solid can't be healed without these faces: %s",
                           os.str().c_str()]);
            return nil;
        }
        const TopoDS_Shape valid = OS3DHealAndValidate(defeat.Shape());
        if (valid.IsNull()) {
            OS3DSetStatus(status, OCCTOpCodeInvalidResult,
                          @"the healed solid failed validity checking");
            return nil;
        }

        OS3DSetStatus(status, OCCTOpCodeOK, nil);
        // Ancestry: OCCT's Defeaturing DOES report history — FreeCAD drops
        // it and loses all names at every delete-face; we keep it (step 5).
        if (history != nil) {
            OS3DFillModifierHistory(history, defeat, shape->_shape, valid);
        }
        OCCTShape *out = [OCCTShape new];
        out->_shape = valid;
        return out;
    } catch (Standard_Failure &e) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                      [NSString stringWithFormat:@"%s", e.GetMessageString()]);
        return nil;
    } catch (...) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"kernel exception");
        return nil;
    }
}

+ (nullable NSData *)splineEdgePolesForPoints:(NSData *)xy closed:(BOOL)closed {
    const NSUInteger count = xy.length / (2 * sizeof(double));
    TopoDS_Edge edge;
    if (!OS3DSplineEdge((const double *)xy.bytes, count, closed, 0.0, edge)) return nil;
    Standard_Real first = 0, last = 0;
    Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, first, last);
    Handle(Geom_BSplineCurve) bspline = Handle(Geom_BSplineCurve)::DownCast(curve);
    if (bspline.IsNull()) return nil;
    // The edge's curve keeps C1 joints (multiplicity 2); the Swift
    // conversion is the Bézier chain. Same curve — raise the joints back to
    // full multiplicity on a copy and the poles ARE the Bézier control points.
    Handle(Geom_BSplineCurve) bezier = Handle(Geom_BSplineCurve)::DownCast(bspline->Copy());
    for (Standard_Integer k = 2; k < bezier->NbKnots(); ++k) {
        try { bezier->IncreaseMultiplicity(k, bezier->Degree()); } catch (...) {}
    }
    const TColgp_Array1OfPnt &poles = bezier->Poles();
    NSMutableData *out = [NSMutableData dataWithCapacity:poles.Length() * 2 * sizeof(double)];
    for (Standard_Integer i = poles.Lower(); i <= poles.Upper(); ++i) {
        double v[2] = { poles.Value(i).X(), poles.Value(i).Y() };
        [out appendBytes:v length:sizeof(v)];
    }
    return out;
}

+ (OCCTFaceTypeCounts *)faceTypeCountsOfShape:(OCCTShape *)shape {
    NSInteger planar = 0, cyl = 0, other = 0;
    if (shape != nil) {
        try {
            for (TopExp_Explorer ex(shape->_shape, TopAbs_FACE); ex.More(); ex.Next()) {
                BRepAdaptor_Surface surf(TopoDS::Face(ex.Current()));
                switch (surf.GetType()) {
                    case GeomAbs_Plane: planar++; break;
                    case GeomAbs_Cylinder: cyl++; break;
                    default: other++; break;
                }
            }
        } catch (...) {
            // Same exception barrier as TessellateShape: a corrupt shape
            // (e.g. deserialized from a newer OCCT) must not crash the app.
            planar = 0; cyl = 0; other = 0;
        }
    }
    OCCTFaceTypeCounts *counts = [OCCTFaceTypeCounts new];
    counts->_planar = planar;
    counts->_cylindrical = cyl;
    counts->_other = other;
    return counts;
}

/// Edges the user actually picked: for EACH picked point, the single NEAREST
/// edge (when it is within `tolerance`), rather than every edge that happens
/// to fall inside the tolerance ball.
///
/// The all-within-tolerance rule was a real defect: tolerance is 1–2% of the
/// body's AABB diagonal, so on an ordinary 100×100×1 mm plate it is 1.4–2.8 mm
/// against a 1 mm thickness — picking one rim also rounded the rim on the
/// opposite face (2026-08-25 review round 4). Nearest-wins keeps a
/// tessellated rim working (its many midpoints all resolve to the same OCCT
/// edge) while making the pick unambiguous on thin parts.
static std::set<Standard_Integer> OS3DNearestEdges(
    const TopTools_IndexedMapOfShape &edgeMap,
    const double *pts, NSUInteger count, double tolerance
) {
    std::vector<double> bestDistance(count, std::numeric_limits<double>::max());
    std::vector<Standard_Integer> bestEdge(count, 0);

    for (Standard_Integer i = 1; i <= edgeMap.Extent(); ++i) {
        const TopoDS_Edge edge = TopoDS::Edge(edgeMap(i));
        if (BRep_Tool::Degenerated(edge)) continue;

        BRepAdaptor_Curve curve(edge);
        const double first = curve.FirstParameter();
        const double last = curve.LastParameter();

        // The TRUE distance to the curve, by projection — not the distance to
        // the nearest of a handful of samples.
        //
        // This used to sample 16 points along the parameter range, which is
        // ample for a straight edge and badly wrong for a circle: on a Ø10 rim
        // the samples sit ~2 mm apart, so a point ON the rim can measure up to
        // ~1 mm from the nearest one. Tolerance is 1% of the body diagonal —
        // 0.185 mm there — so most taps on a cylinder's rim were rejected as
        // "no edge near here" and the fillet silently did nothing. Measured:
        // of the first 8 rim segments only 2 resolved; at a 1 mm tolerance 7
        // did, which is the sampling gap showing through.
        Standard_Real curveFirst = 0, curveLast = 0;
        Handle(Geom_Curve) geom = BRep_Tool::Curve(edge, curveFirst, curveLast);
        for (NSUInteger k = 0; k < count; ++k) {
            const gp_Pnt target(pts[3*k], pts[3*k+1], pts[3*k+2]);
            // Endpoints first: a projection can legitimately find nothing when
            // the nearest point on the trimmed curve is an end.
            double d = std::min(curve.Value(first).Distance(target),
                                curve.Value(last).Distance(target));
            if (!geom.IsNull()) {
                try {
                    GeomAPI_ProjectPointOnCurve proj(target, geom, curveFirst, curveLast);
                    if (proj.NbPoints() > 0) d = std::min(d, (double)proj.LowerDistance());
                } catch (...) {
                    // Fall back to the endpoint distance already computed.
                }
            }
            if (d < bestDistance[k]) { bestDistance[k] = d; bestEdge[k] = i; }
        }
    }

    std::set<Standard_Integer> chosen;
    for (NSUInteger k = 0; k < count; ++k) {
        if (bestEdge[k] != 0 && bestDistance[k] <= tolerance) {
            chosen.insert(bestEdge[k]);
        }
    }
    return chosen;
}

// Keep only the edges a blend can actually be built on. Policy re-derived
// from PartDesign's dress-up edge filter (docs/FREECAD_PLAYBOOK.md F2): an
// edge must join exactly two DISTINCT faces (a seam — the vertical closure of
// a cylinder wall — has the same face on both sides and nothing to blend; a
// free edge has one), must not be degenerate (an apex "edge" has zero
// length), and must meet its faces with only C0 continuity — ChFi3d picks up
// tangent-continuous neighbours by chain propagation on its own, and adding
// one explicitly is a failure mode, not a request it honours. Handing ChFi3d
// an edge that violates any of these is how the SIGTRAP-in-`Polygon.clip`
// class of crash started upstream of here.
//
// When the filter empties the pick, `reason` gets the first rejection so the
// caller can say WHY nothing was blendable.
static std::set<Standard_Integer> OS3DBlendableEdges(
    const TopoDS_Shape &shape,
    const TopTools_IndexedMapOfShape &edgeMap,
    const std::set<Standard_Integer> &candidates,
    NSString *__strong *reason
) {
    TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
    TopExp::MapShapesAndAncestors(shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);

    std::set<Standard_Integer> out;
    NSString *why = nil;
    for (Standard_Integer i : candidates) {
        const TopoDS_Edge edge = TopoDS::Edge(edgeMap(i));
        if (BRep_Tool::Degenerated(edge)) {
            if (why == nil) why = @"the picked edge is degenerate";
            continue;
        }
        if (!edgeFaces.Contains(edge)) {
            if (why == nil) why = @"the picked edge is not attached to a face";
            continue;
        }
        const TopTools_ListOfShape &faces = edgeFaces.FindFromKey(edge);
        if (faces.Extent() != 2) {
            if (why == nil) why = @"the picked edge does not join two faces";
            continue;
        }
        const TopoDS_Face f1 = TopoDS::Face(faces.First());
        const TopoDS_Face f2 = TopoDS::Face(faces.Last());
        if (f1.IsSame(f2)) {
            if (why == nil) why = @"the picked edge is a seam, not a boundary";
            continue;
        }
        if (BRep_Tool::Continuity(edge, f1, f2) != GeomAbs_C0) {
            if (why == nil) {
                why = @"the faces already meet smoothly here — "
                      @"blend a neighbouring sharp edge instead";
            }
            continue;
        }
        out.insert(i);
    }
    if (out.empty() && reason != NULL && *reason == nil) *reason = why;
    return out;
}

// Whether a blend builder blended `edge`. Generated() alone is not enough:
// ChFi3d credits a tangent chain's blend faces to some of its edges only, so
// an edge inside a chain can generate nothing and still be blended. Six of
// 18.5A's 22 port-junction edges did, and a valid R5 result was refused as
// "6 of 22 edges can't take this size" (2026-09-16). Such an edge is gone
// from the result with no modified image. A dropped edge is still there,
// and an edge a neighbouring blend only trimmed has a modified image.
static bool OS3DEdgeBlended(BRepFilletAPI_LocalOperation &mk,
                            const TopoDS_Shape &edge,
                            const TopTools_IndexedMapOfShape &resultEdges) {
    if (!mk.Generated(edge).IsEmpty()) return true;
    return !resultEdges.Contains(edge) && mk.Modified(edge).IsEmpty();
}

// Shared tail of the fillet and chamfer paths: count the picked edges the
// builder actually blended (OS3DEdgeBlended — MakeChamfer has no other
// per-edge success signal), refuse partial builds outright, then
// unwrap/validate the result. Returns nil with `status` filled on any
// failure. `faultyContours` is the fillet builder's own count (-1 when the
// builder doesn't expose one).
static OCCTShape *OS3DFinishBlend(BRepFilletAPI_LocalOperation &mk,
                                  const TopTools_IndexedMapOfShape &edgeMap,
                                  const std::set<Standard_Integer> &edges,
                                  NSInteger faultyContours,
                                  OCCTOpStatus *status) {
    const NSInteger requested = (NSInteger)edges.size();
    if (!mk.IsDone() || faultyContours > 0) {
        const NSInteger failed =
            faultyContours > 0 ? faultyContours : requested;
        OS3DSetStatus(status, OCCTOpCodePartialResult,
                      @"the size is too large for the local geometry");
        if (status != nil) {
            status.failedCount = failed;
            status.requestedCount = requested;
        }
        return nil;
    }

    // IsDone() with zero faulty contours can STILL mean an edge was quietly
    // dropped: check that every requested edge was blended.
    TopTools_IndexedMapOfShape resultEdges;
    TopExp::MapShapes(mk.Shape(), TopAbs_EDGE, resultEdges);
    NSInteger blended = 0;
    for (Standard_Integer i : edges) {
        if (OS3DEdgeBlended(mk, edgeMap(i), resultEdges)) ++blended;
    }
    if (blended < requested) {
        OS3DSetStatus(status, OCCTOpCodePartialResult,
                      @"the size is too large for the local geometry");
        if (status != nil) {
            status.failedCount = requested - blended;
            status.requestedCount = requested;
        }
        return nil;
    }

    int solidCount = 0;
    const TopoDS_Shape single = OS3DExtractSingleSolid(mk.Shape(), solidCount);
    if (solidCount != 1) {
        OS3DSetStatus(status, OCCTOpCodeInvalidResult,
                      @"the blend did not produce a single solid");
        if (status != nil) status.solidCount = solidCount;
        return nil;
    }
    const TopoDS_Shape valid = OS3DHealAndValidate(single);
    if (valid.IsNull()) {
        OS3DSetStatus(status, OCCTOpCodeInvalidResult,
                      @"the blended solid failed validity checking");
        return nil;
    }
    OS3DSetStatus(status, OCCTOpCodeOK, nil);
    OCCTShape *out = [OCCTShape new];
    out->_shape = valid;
    return out;
}

// Qualify → build → finish for one validated edge-index set — shared by the
// point-matched entries and the identity-addressed ones, so both make
// IDENTICAL kernel decisions (pre-qualification, per-edge Generated check,
// single-solid, heal-and-validate). MakeChamfer has no NbFaultyContours;
// the per-edge Generated() check in OS3DFinishBlend is its signal.
// Post-finish ancestry for a single-input modifier op: harvest the maker's
// history, validate every row against the RETURNED shape (the phantom gate
// again — the finish path may have healed), and pack. Shared by blends,
// shell and defeaturing so they all report identity the same way.
static void OS3DFillModifierHistory(OCCTShapeHistory *history,
                                    BRepBuilderAPI_MakeShape &maker,
                                    const TopoDS_Shape &input,
                                    const TopoDS_Shape &finalShape) {
    if (history == nil || finalShape.IsNull()) return;
    std::vector<OS3DHistEdge> edges;
    const std::vector<TopoDS_Shape> inputs = {input};
    OS3DCollectMakerHistory(maker, inputs, edges);
    // The finish paths heal only an invalid result; when they did, rows for
    // rebuilt faces simply fail the final-shape lookup and drop out.
    int solidCount = 0;
    const TopoDS_Shape raw = OS3DExtractSingleSolid(maker.Shape(), solidCount);
    const BOOL healed = solidCount == 1 && !finalShape.IsSame(raw);
    OS3DFillHistory(history, edges, inputs, Handle(BRepTools_History)(),
                    finalShape, healed);
}

static OCCTShape *OS3DBlendEdgeSet(const TopoDS_Shape &shape,
                                   const TopTools_IndexedMapOfShape &edgeMap,
                                   const std::set<Standard_Integer> &chosen,
                                   double amount, bool isFillet,
                                   OCCTOpStatus *status,
                                   OCCTShapeHistory *history) {
    NSString *reason = nil;
    const std::set<Standard_Integer> qualified =
        OS3DBlendableEdges(shape, edgeMap, chosen, &reason);
    if (qualified.empty()) {
        OS3DSetStatus(status, OCCTOpCodeNoTargetMatched, reason);
        return nil;
    }
    if (isFillet) {
        BRepFilletAPI_MakeFillet mk(shape);
        for (Standard_Integer i : qualified) {
            mk.Add(amount, TopoDS::Edge(edgeMap(i)));
        }
        OS3DDeadlineProgress *deadline =
            new OS3DDeadlineProgress(kOS3DOpDeadlineSeconds);
        Handle(Message_ProgressIndicator) progress(deadline);
        OS3D_GUARDED(status, "fillet", mk.Build(progress->Start()));
        if (deadline->Fired()) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"the operation exceeded the kernel deadline");
            return nil;
        }
        OCCTShape *out = OS3DFinishBlend(mk, edgeMap, qualified,
                                         mk.IsDone() ? mk.NbFaultyContours() : -1,
                                         status);
        if (out != nil) OS3DFillModifierHistory(history, mk, shape, out->_shape);
        return out;
    }
    BRepFilletAPI_MakeChamfer mk(shape);
    for (Standard_Integer i : qualified) {
        // Symmetric chamfer: equal setback on both adjacent faces.
        mk.Add(amount, TopoDS::Edge(edgeMap(i)));
    }
    OS3DDeadlineProgress *deadline =
        new OS3DDeadlineProgress(kOS3DOpDeadlineSeconds);
    Handle(Message_ProgressIndicator) progress(deadline);
    OS3D_GUARDED(status, "chamfer", mk.Build(progress->Start()));
    if (deadline->Fired()) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                      @"the operation exceeded the kernel deadline");
        return nil;
    }
    OCCTShape *out = OS3DFinishBlend(mk, edgeMap, qualified, -1, status);
    if (out != nil) OS3DFillModifierHistory(history, mk, shape, out->_shape);
    return out;
}

// Shared entry for the identity-addressed blends: 1-based edge indices into
// the shape's indexed edge map (the numbering edgeFaceAdjacencyOfShape:
// reports). An out-of-range index fails the WHOLE op — identity addressing
// that silently blended a subset would be worse than failing.
static OCCTShape *OS3DBlendByIndices(OCCTShape *shape, NSData *edgeIndices,
                                     double amount, bool isFillet,
                                     OCCTOpStatus *status,
                                     OCCTShapeHistory *history) {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"no input");
    if (shape == nil || amount <= 0.0) return nil;
    const NSUInteger count = edgeIndices.length / sizeof(int32_t);
    if (count == 0) return nil;
    try {
        if (!OS3DFiniteBounds(shape->_shape)) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"the body has empty or non-finite geometry");
            return nil;
        }
        TopTools_IndexedMapOfShape edgeMap;
        TopExp::MapShapes(shape->_shape, TopAbs_EDGE, edgeMap);
        const int32_t *indices = (const int32_t *)edgeIndices.bytes;
        std::set<Standard_Integer> chosen;
        for (NSUInteger i = 0; i < count; ++i) {
            if (indices[i] < 1 || indices[i] > edgeMap.Extent()) {
                OS3DSetStatus(status, OCCTOpCodeNoTargetMatched,
                              @"an edge index is out of range for this body");
                return nil;
            }
            chosen.insert((Standard_Integer)indices[i]);
        }
        return OS3DBlendEdgeSet(shape->_shape, edgeMap, chosen,
                                amount, isFillet, status, history);
    } catch (Standard_Failure &e) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                      [NSString stringWithFormat:@"%s", e.GetMessageString()]);
        return nil;
    } catch (...) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"kernel exception");
        return nil;
    }
}

+ (nullable OCCTShape *)filletedShape:(OCCTShape *)shape
                          edgeIndices:(NSData *)edgeIndices
                               radius:(double)radius
                               status:(nullable OCCTOpStatus *)status
                              history:(nullable OCCTShapeHistory *)history {
    return OS3DBlendByIndices(shape, edgeIndices, radius, true, status, history);
}

+ (nullable OCCTShape *)chamferedShape:(OCCTShape *)shape
                           edgeIndices:(NSData *)edgeIndices
                              distance:(double)distance
                                status:(nullable OCCTOpStatus *)status
                               history:(nullable OCCTShapeHistory *)history {
    return OS3DBlendByIndices(shape, edgeIndices, distance, false, status, history);
}

/// Whether the face's UV domain is an untrimmed iso-rectangle — one wire,
/// every edge's pcurve running along u or v — and if so its bounds. That is
/// every wall of an extrude or revolve and every unpierced B-spline face;
/// a wall with a hole through it has a curved inner pcurve and fails.
static bool OS3DIsoRectangularDomain(const TopoDS_Face &face,
                                     double &u1, double &u2, double &v1, double &v2) {
    int wires = 0;
    for (TopExp_Explorer w(face, TopAbs_WIRE); w.More(); w.Next()) { if (++wires > 1) return false; }
    if (wires == 0) return false;
    for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
        const TopoDS_Edge edge = TopoDS::Edge(e.Current());
        double f = 0.0, l = 0.0;
        Handle(Geom2d_Curve) pc = BRep_Tool::CurveOnSurface(edge, face, f, l);
        if (pc.IsNull()) return false;
        // Sample rather than trust the type: a straight B-spline pcurve counts.
        const gp_Pnt2d a = pc->Value(f), b = pc->Value(l), m = pc->Value(0.5 * (f + l));
        const bool uConst = fabs(a.X() - b.X()) < 1e-9 && fabs(a.X() - m.X()) < 1e-9;
        const bool vConst = fabs(a.Y() - b.Y()) < 1e-9 && fabs(a.Y() - m.Y()) < 1e-9;
        if (!uConst && !vConst) return false;
    }
    BRepTools::UVBounds(face, u1, u2, v1, v2);
    return u2 > u1 + 1e-12 && v2 > v1 + 1e-12;
}

/// Knot values of `curve` (through a trim) inside (lo, hi), for span splitting.
static void OS3DCurveKnots(const Handle(Geom_Curve) &curve, double lo, double hi, std::vector<double> &out) {
    Handle(Geom_Curve) basis = curve;
    if (!basis.IsNull() && basis->DynamicType() == STANDARD_TYPE(Geom_TrimmedCurve))
        basis = Handle(Geom_TrimmedCurve)::DownCast(basis)->BasisCurve();
    if (basis.IsNull() || basis->DynamicType() != STANDARD_TYPE(Geom_BSplineCurve)) return;
    Handle(Geom_BSplineCurve) bs = Handle(Geom_BSplineCurve)::DownCast(basis);
    for (Standard_Integer i = bs->FirstUKnotIndex(); i <= bs->LastUKnotIndex(); ++i) {
        const double k = bs->Knot(i);
        if (k > lo + 1e-12 && k < hi - 1e-12) out.push_back(k);
    }
}

/// The face's area by 10-point Gauss–Legendre per KNOT SPAN of |∂S/∂u × ∂S/∂v|
/// over its iso-rectangular UV domain — exact to ~1e-10 on B-spline walls,
/// where both `BRepGProp::SurfaceProperties` rules are off (the default by
/// +1.3 %, the adaptive by −4.6 % on a closed-spline extrude, gotcha 23):
/// neither splits at knots, and unlike `VolumePropertiesGK` there is no
/// `IsUseSpan`. Returns a negative number when the face is not iso-rectangular.
static double OS3DSpanExactArea(const TopoDS_Face &face) {
    double u1, u2, v1, v2;
    if (!OS3DIsoRectangularDomain(face, u1, u2, v1, v2)) return -1.0;
    TopLoc_Location loc;
    Handle(Geom_Surface) S = BRep_Tool::Surface(face, loc);      // area is rigid-invariant: ignore loc
    if (S.IsNull()) return -1.0;
    Handle(Geom_Surface) base = S;
    if (base->DynamicType() == STANDARD_TYPE(Geom_RectangularTrimmedSurface))
        base = Handle(Geom_RectangularTrimmedSurface)::DownCast(base)->BasisSurface();
    std::vector<double> us = {u1}, vs = {v1};
    std::vector<double> ku, kv;
    if (base->DynamicType() == STANDARD_TYPE(Geom_BSplineSurface)) {
        Handle(Geom_BSplineSurface) bs = Handle(Geom_BSplineSurface)::DownCast(base);
        for (Standard_Integer i = bs->FirstUKnotIndex(); i <= bs->LastUKnotIndex(); ++i) {
            const double k = bs->UKnot(i); if (k > u1 + 1e-12 && k < u2 - 1e-12) ku.push_back(k);
        }
        for (Standard_Integer i = bs->FirstVKnotIndex(); i <= bs->LastVKnotIndex(); ++i) {
            const double k = bs->VKnot(i); if (k > v1 + 1e-12 && k < v2 - 1e-12) kv.push_back(k);
        }
    } else if (base->DynamicType() == STANDARD_TYPE(Geom_SurfaceOfLinearExtrusion)) {
        OS3DCurveKnots(Handle(Geom_SurfaceOfLinearExtrusion)::DownCast(base)->BasisCurve(), u1, u2, ku);
    } else if (base->DynamicType() == STANDARD_TYPE(Geom_SurfaceOfRevolution)) {
        OS3DCurveKnots(Handle(Geom_SurfaceOfRevolution)::DownCast(base)->BasisCurve(), v1, v2, kv);
    }
    std::sort(ku.begin(), ku.end()); std::sort(kv.begin(), kv.end());
    us.insert(us.end(), ku.begin(), ku.end()); us.push_back(u2);
    vs.insert(vs.end(), kv.begin(), kv.end()); vs.push_back(v2);
    // A smooth integrand within a span still wants a few cells per span for
    // long spans (a full circle of revolution is one span of 2π).
    static const double gx[10] = {-0.9739065285171717, -0.8650633666889845, -0.6794095682990244, -0.4333953941292472, -0.1488743389816312,
                                   0.1488743389816312, 0.4333953941292472, 0.6794095682990244, 0.8650633666889845, 0.9739065285171717};
    static const double gw[10] = {0.0666713443086881, 0.1494513491505806, 0.2190863625159820, 0.2692667193099963, 0.2955242247147529,
                                  0.2955242247147529, 0.2692667193099963, 0.2190863625159820, 0.1494513491505806, 0.0666713443086881};
    auto cells = [](std::vector<double> &knots) {
        std::vector<double> out;
        for (size_t i = 0; i + 1 < knots.size(); ++i) {
            const int sub = std::max(1, std::min(8, (int)ceil((knots[i + 1] - knots[i]) / 1.0)));
            for (int s = 0; s <= sub; ++s) {
                if (s == 0 && i > 0) continue;
                out.push_back(knots[i] + (knots[i + 1] - knots[i]) * (double)s / sub);
            }
        }
        return out;
    };
    const std::vector<double> cu = cells(us), cv = cells(vs);
    double area = 0.0;
    gp_Pnt P; gp_Vec dU, dV;
    for (size_t i = 0; i + 1 < cu.size(); ++i) {
        const double ha = 0.5 * (cu[i + 1] - cu[i]), ua = 0.5 * (cu[i + 1] + cu[i]);
        for (size_t j = 0; j + 1 < cv.size(); ++j) {
            const double hb = 0.5 * (cv[j + 1] - cv[j]), vb = 0.5 * (cv[j + 1] + cv[j]);
            double cell = 0.0;
            for (int a = 0; a < 10; ++a) for (int b = 0; b < 10; ++b) {
                S->D1(ua + ha * gx[a], vb + hb * gx[b], P, dU, dV);
                cell += gw[a] * gw[b] * dU.Crossed(dV).Magnitude();
            }
            area += cell * ha * hb;
        }
    }
    return area;
}

+ (nullable NSData *)faceInfoOfShape:(OCCTShape *)shape {
    if (shape == nil || shape->_shape.IsNull()) return nil;
    try {
        TopTools_IndexedMapOfShape faceMap;
        TopExp::MapShapes(shape->_shape, TopAbs_FACE, faceMap);
        std::vector<double> rows;
        rows.reserve((size_t)faceMap.Extent() * 10);
        for (Standard_Integer i = 1; i <= faceMap.Extent(); ++i) {
            const TopoDS_Face face = TopoDS::Face(faceMap(i));
            BRepAdaptor_Surface surf(face);
            GProp_GProps props;
            // Face areas are identity signatures, and on a B-spline wall BOTH
            // `BRepGProp::SurfaceProperties` rules are off (gotcha 23: default
            // +1.3 %, adaptive −4.6 % — neither splits at knots). So: a plane
            // takes the adaptive rule (exact to 1e-7 along a spline boundary);
            // an untrimmed iso-rectangular face is integrated per knot span
            // here (`OS3DSpanExactArea`); only a trimmed curved face is left
            // to the default rule. Centroids stay the kernel's (a sample
            // point, not a measurement). `testClosedSplineExtrudesToOneSmoothWall`.
            const bool planar = surf.GetType() == GeomAbs_Plane;
            if (planar) {
                BRepGProp::SurfaceProperties(face, props, 1e-7);
            } else {
                BRepGProp::SurfaceProperties(face, props);
            }
            const gp_Pnt centroid = props.CentreOfMass();
            double area = props.Mass();
            if (!planar) {
                const double exact = OS3DSpanExactArea(face);
                if (exact > 0.0) area = exact;
            }
            double kind = 2.0, extra = 0.0;
            gp_Dir normal(0.0, 0.0, 1.0);
            if (surf.GetType() == GeomAbs_Plane) {
                kind = 0.0;
                // The OUTWARD normal from the face's own parametrisation with
                // its orientation applied — the normal the volume integral
                // uses. The plane axis flipped by the orientation flag is NOT
                // enough: a face whose location mirrors (a MakeRevol cap)
                // has an axis that already points the other way, and the
                // flag alone reported a revolve's base cap pointing INTO the
                // body, so a FaceRef minted from it never resolved
                // (2026-09-02, the Coke-bottle shell).
                Standard_Real u0 = 0, u1 = 0, v0 = 0, v1 = 0;
                BRepTools::UVBounds(face, u0, u1, v0, v1);
                BRepGProp_Face oriented(face);
                gp_Pnt at; gp_Vec nv;
                oriented.Normal((u0 + u1) / 2, (v0 + v1) / 2, at, nv);
                if (nv.Magnitude() > 1e-12) {
                    normal = gp_Dir(nv);
                } else {
                    normal = surf.Plane().Axis().Direction();
                    if (face.Orientation() == TopAbs_REVERSED) normal.Reverse();
                }
                extra = normal.X() * centroid.X() + normal.Y() * centroid.Y()
                      + normal.Z() * centroid.Z();
            } else if (surf.GetType() == GeomAbs_Cylinder) {
                kind = 1.0;
                normal = surf.Cylinder().Axis().Direction();
                extra = surf.Cylinder().Radius();
            }
            const double row[10] = {
                (double)i, kind,
                normal.X(), normal.Y(), normal.Z(),
                centroid.X(), centroid.Y(), centroid.Z(),
                area, extra,
            };
            rows.insert(rows.end(), row, row + 10);
        }
        return [NSData dataWithBytes:rows.data()
                              length:rows.size() * sizeof(double)];
    } catch (...) {
        return nil;
    }
}

+ (nullable NSData *)sectionOfShape:(OCCTShape *)shape
                              plane:(NSData *)plane
                         deflection:(double)deflection {
    if (shape == nil || shape->_shape.IsNull() || plane.length < 6 * sizeof(double)) return nil;
    try {
        const double *p = (const double *)plane.bytes;
        gp_Pln pln(gp_Pnt(p[0], p[1], p[2]), gp_Dir(p[3], p[4], p[5]));
        BRepAlgoAPI_Section section(shape->_shape, pln, Standard_False);
        section.ComputePCurveOn1(Standard_True);
        section.Approximation(Standard_True);
        section.Build();
        if (!section.IsDone()) return nil;
        const double chord = deflection > 0 ? deflection : 0.05;
        std::vector<double> out;
        for (TopExp_Explorer ex(section.Shape(), TopAbs_EDGE); ex.More(); ex.Next()) {
            const TopoDS_Edge edge = TopoDS::Edge(ex.Current());
            BRepAdaptor_Curve curve(edge);
            std::vector<gp_Pnt> pts;
            if (curve.GetType() == GeomAbs_Line) {
                pts.push_back(curve.Value(curve.FirstParameter()));
                pts.push_back(curve.Value(curve.LastParameter()));
            } else {
                GCPnts_UniformDeflection disc(curve, chord, curve.FirstParameter(), curve.LastParameter());
                if (disc.IsDone() && disc.NbPoints() >= 2) {
                    for (Standard_Integer i = 1; i <= disc.NbPoints(); ++i) pts.push_back(disc.Value(i));
                } else {
                    pts.push_back(curve.Value(curve.FirstParameter()));
                    pts.push_back(curve.Value(curve.LastParameter()));
                }
            }
            if (edge.Orientation() == TopAbs_REVERSED) std::reverse(pts.begin(), pts.end());
            out.push_back((double)pts.size());
            for (const gp_Pnt &q : pts) { out.push_back(q.X()); out.push_back(q.Y()); out.push_back(q.Z()); }
        }
        return [NSData dataWithBytes:out.data() length:out.size() * sizeof(double)];
    } catch (...) {
        return nil;
    }
}

+ (nullable NSData *)edgeFaceAdjacencyOfShape:(OCCTShape *)shape {
    if (shape == nil || shape->_shape.IsNull()) return nil;
    try {
        TopTools_IndexedMapOfShape faceMap, edgeMap;
        TopExp::MapShapes(shape->_shape, TopAbs_FACE, faceMap);
        TopExp::MapShapes(shape->_shape, TopAbs_EDGE, edgeMap);
        TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
        TopExp::MapShapesAndAncestors(shape->_shape, TopAbs_EDGE, TopAbs_FACE,
                                      edgeFaces);
        std::vector<int32_t> rows;
        // Keyed explicitly through edgeMap so the numbering here is BY
        // CONSTRUCTION the one every other per-shape query uses — never an
        // assumption about two maps agreeing.
        for (Standard_Integer e = 1; e <= edgeMap.Extent(); ++e) {
            const TopoDS_Shape &edge = edgeMap(e);
            if (!edgeFaces.Contains(edge)) continue;
            std::set<int32_t> faces;
            for (TopTools_ListOfShape::Iterator it(edgeFaces.FindFromKey(edge));
                 it.More(); it.Next()) {
                const int32_t f = (int32_t)faceMap.FindIndex(it.Value());
                if (f > 0) faces.insert(f);
            }
            // Seams and borders have one distinct face (or none) — they
            // carry no PAIR identity and are unaddressable here on purpose:
            // they are also exactly the edges the blend pre-qualifier vetoes.
            if (faces.size() != 2) continue;
            auto it = faces.begin();
            const int32_t a = *it++;
            const int32_t b = *it;
            rows.push_back((int32_t)e);
            rows.push_back(a);
            rows.push_back(b);
        }
        return [NSData dataWithBytes:rows.data()
                              length:rows.size() * sizeof(int32_t)];
    } catch (...) {
        return nil;
    }
}

+ (NSInteger)nearestEdgeIndexOfShape:(OCCTShape *)shape
                            toPointX:(double)x y:(double)y z:(double)z
                           tolerance:(double)tolerance {
    if (shape == nil || shape->_shape.IsNull()) return 0;
    try {
        TopTools_IndexedMapOfShape edgeMap;
        TopExp::MapShapes(shape->_shape, TopAbs_EDGE, edgeMap);
        if (edgeMap.Extent() == 0) return 0;
        const double pt[3] = {x, y, z};
        const std::set<Standard_Integer> found =
            OS3DNearestEdges(edgeMap, pt, 1, tolerance);
        return found.empty() ? 0 : (NSInteger)*found.begin();
    } catch (...) {
        return 0;
    }
}

+ (nullable NSData *)edgeMidpointsOfShape:(OCCTShape *)shape {
    if (shape == nil || shape->_shape.IsNull()) return nil;
    try {
        TopTools_IndexedMapOfShape edgeMap;
        TopExp::MapShapes(shape->_shape, TopAbs_EDGE, edgeMap);
        std::vector<double> out((size_t)edgeMap.Extent() * 3,
                                std::numeric_limits<double>::quiet_NaN());
        for (Standard_Integer e = 1; e <= edgeMap.Extent(); ++e) {
            const TopoDS_Edge edge = TopoDS::Edge(edgeMap(e));
            if (BRep_Tool::Degenerated(edge)) continue;
            // One bad edge leaves its own NaN, not a nil for the whole body.
            try {
                BRepAdaptor_Curve curve(edge);
                const double first = curve.FirstParameter();
                const double last = curve.LastParameter();
                const double length = GCPnts_AbscissaPoint::Length(curve, first, last);
                if (!(length > 0.0) || !std::isfinite(length)) continue;
                GCPnts_AbscissaPoint half(curve, length / 2.0, first);
                if (!half.IsDone()) continue;
                const gp_Pnt p = curve.Value(half.Parameter());
                const size_t base = (size_t)(e - 1) * 3;
                out[base] = p.X();
                out[base + 1] = p.Y();
                out[base + 2] = p.Z();
            } catch (Standard_Failure &) {
                continue;
            }
        }
        return [NSData dataWithBytes:out.data() length:out.size() * sizeof(double)];
    } catch (...) {
        return nil;
    }
}

+ (nullable OCCTShape *)filletedShape:(OCCTShape *)shape
                        atWorldPoints:(NSData *)worldPoints
                               radius:(double)radius
                            tolerance:(double)tolerance
                               status:(nullable OCCTOpStatus *)status {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"no input");
    if (shape == nil || radius <= 0.0) return nil;
    const NSUInteger count = worldPoints.length / (3 * sizeof(double));
    if (count == 0) return nil;
    const double *pts = (const double *)worldPoints.bytes;

    try {
        if (!OS3DFiniteBounds(shape->_shape)) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"the body has empty or non-finite geometry");
            return nil;
        }
        TopTools_IndexedMapOfShape edgeMap;
        TopExp::MapShapes(shape->_shape, TopAbs_EDGE, edgeMap);
        if (edgeMap.Extent() == 0) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched,
                          @"the body has no edges");
            return nil;
        }

        const std::set<Standard_Integer> chosen =
            OS3DNearestEdges(edgeMap, pts, count, tolerance);
        if (chosen.empty()) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched,
                          @"no edge within tolerance of the pick");
            return nil;
        }
        return OS3DBlendEdgeSet(shape->_shape, edgeMap, chosen,
                                radius, /*isFillet*/ true, status, nil);
    } catch (Standard_Failure &e) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                      [NSString stringWithFormat:@"%s", e.GetMessageString()]);
        return nil;
    } catch (...) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"kernel exception");
        return nil;
    }
}

// One fully-checked fillet attempt at `radius` on the given edges: built,
// contour-complete, per-edge generated, single-solid, analyzer-valid. The
// bisection's probe — identical checks to the committing path, so what the
// clamp says fits IS what Apply builds.
static bool OS3DFilletBuilds(const TopoDS_Shape &shape,
                             const TopTools_IndexedMapOfShape &edgeMap,
                             const std::set<Standard_Integer> &edges,
                             double radius,
                             double deadlineSeconds = kOS3DKernelDeadlineSeconds) {
    try {
        BRepFilletAPI_MakeFillet mk(shape);
        for (Standard_Integer i : edges) {
            mk.Add(radius, TopoDS::Edge(edgeMap(i)));
        }
        // The SHORT deadline: a drag clamp runs ~7 of these probes, and one
        // hanging probe would wedge the drag exactly like the boolean hang.
        OS3DDeadlineProgress *deadline =
            new OS3DDeadlineProgress(deadlineSeconds);
        Handle(Message_ProgressIndicator) progress(deadline);
        mk.Build(progress->Start());
        if (deadline->Fired()) return false;
        if (!mk.IsDone() || mk.NbFaultyContours() > 0) return false;
        TopTools_IndexedMapOfShape resultEdges;
        TopExp::MapShapes(mk.Shape(), TopAbs_EDGE, resultEdges);
        for (Standard_Integer i : edges) {
            if (!OS3DEdgeBlended(mk, edgeMap(i), resultEdges)) return false;
        }
        int solidCount = 0;
        const TopoDS_Shape single = OS3DExtractSingleSolid(mk.Shape(), solidCount);
        if (solidCount != 1) return false;
        return OS3DIsValid(single);
    } catch (...) {
        return false;
    }
}

+ (double)maxFilletRadiusForShape:(OCCTShape *)shape
                    atWorldPoints:(NSData *)worldPoints
                        tolerance:(double)tolerance {
    if (shape == nil) return 0.0;
    const NSUInteger count = worldPoints.length / (3 * sizeof(double));
    if (count == 0) return 0.0;
    const double *pts = (const double *)worldPoints.bytes;

    try {
        if (!OS3DFiniteBounds(shape->_shape)) return 0.0;
        TopTools_IndexedMapOfShape edgeMap;
        TopExp::MapShapes(shape->_shape, TopAbs_EDGE, edgeMap);
        if (edgeMap.Extent() == 0) return 0.0;
        const std::set<Standard_Integer> chosen =
            OS3DNearestEdges(edgeMap, pts, count, tolerance);
        if (chosen.empty()) return 0.0;
        NSString *reason = nil;
        const std::set<Standard_Integer> qualified =
            OS3DBlendableEdges(shape->_shape, edgeMap, chosen, &reason);
        if (qualified.empty()) return 0.0;

        // Upper bracket: half the body diagonal, tightened by the local
        // curvature of any cylindrical/spherical face adjacent to a chosen
        // edge — a blend can never exceed the radius of the surface it eats
        // into.
        Bnd_Box bounds;
        BRepBndLib::Add(shape->_shape, bounds);
        double hi = 0.5 * sqrt(bounds.SquareExtent());
        TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
        TopExp::MapShapesAndAncestors(shape->_shape, TopAbs_EDGE, TopAbs_FACE,
                                      edgeFaces);
        for (Standard_Integer i : qualified) {
            const TopoDS_Edge edge = TopoDS::Edge(edgeMap(i));
            if (!edgeFaces.Contains(edge)) continue;
            for (TopTools_ListOfShape::Iterator it(edgeFaces.FindFromKey(edge));
                 it.More(); it.Next()) {
                BRepAdaptor_Surface surf(TopoDS::Face(it.Value()));
                if (surf.GetType() == GeomAbs_Cylinder) {
                    hi = std::min(hi, surf.Cylinder().Radius());
                } else if (surf.GetType() == GeomAbs_Sphere) {
                    hi = std::min(hi, surf.Sphere().Radius());
                }
            }
        }
        if (!(hi > 0)) return 0.0;

        // ~7-step bisection over real builds. `lo` is always a radius that
        // BUILT; a tiny probe first so a hopeless pick returns 0 fast.
        if (OS3DFilletBuilds(shape->_shape, edgeMap, qualified, hi)) return hi;
        double lo = 0.0;
        const double probe = std::min(hi * 0.01, 0.05);
        if (probe > 0 && OS3DFilletBuilds(shape->_shape, edgeMap, qualified, probe)) {
            lo = probe;
        } else {
            // Whether a size builds is not monotonic: a tiny blend can fail
            // validity where larger ones build. 18.5A's port/body chain fails
            // at R0.05, R8 and R10 and builds from R0.1 to R5; returning 0
            // left that drag unclamped (2026-09-17). Halve down from the
            // bracket for a size that builds, all of it within one kernel
            // deadline: this runs on the main thread as the drag starts.
            const CFAbsoluteTime budgetEnd =
                CFAbsoluteTimeGetCurrent() + kOS3DKernelDeadlineSeconds;
            for (double r = 0.5 * hi; r > probe; r *= 0.5) {
                const double left = budgetEnd - CFAbsoluteTimeGetCurrent();
                if (left <= 0) break;
                if (OS3DFilletBuilds(shape->_shape, edgeMap, qualified, r, left)) {
                    lo = r;
                    hi = 2.0 * r;   // the last size tried above it failed
                    break;
                }
            }
            if (lo == 0.0) return 0.0;
        }
        for (int step = 0; step < 7; ++step) {
            const double mid = 0.5 * (lo + hi);
            if (OS3DFilletBuilds(shape->_shape, edgeMap, qualified, mid)) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        return lo;
    } catch (...) {
        return 0.0;
    }
}

+ (nullable OCCTShape *)chamferedShape:(OCCTShape *)shape
                        atWorldPoints:(NSData *)worldPoints
                             distance:(double)distance
                            tolerance:(double)tolerance
                                status:(nullable OCCTOpStatus *)status {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"no input");
    if (shape == nil || distance <= 0.0) return nil;
    const NSUInteger count = worldPoints.length / (3 * sizeof(double));
    if (count == 0) return nil;
    const double *pts = (const double *)worldPoints.bytes;

    try {
        if (!OS3DFiniteBounds(shape->_shape)) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"the body has empty or non-finite geometry");
            return nil;
        }
        TopTools_IndexedMapOfShape edgeMap;
        TopExp::MapShapes(shape->_shape, TopAbs_EDGE, edgeMap);
        if (edgeMap.Extent() == 0) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched,
                          @"the body has no edges");
            return nil;
        }

        // Nearest-wins, same rule as the fillet path (see OS3DNearestEdges).
        const std::set<Standard_Integer> chosen =
            OS3DNearestEdges(edgeMap, pts, count, tolerance);
        if (chosen.empty()) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched,
                          @"no edge within tolerance of the pick");
            return nil;
        }
        return OS3DBlendEdgeSet(shape->_shape, edgeMap, chosen,
                                distance, /*isFillet*/ false, status, nil);
    } catch (Standard_Failure &e) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                      [NSString stringWithFormat:@"%s", e.GetMessageString()]);
        return nil;
    } catch (...) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"kernel exception");
        return nil;
    }
}

// Exact volume via BRepGProp; 0 on any failure. Shared by the public
// volumeOfShape: and the shell sanity check.
//
// The ADAPTIVE overload, integrating per knot span to a relative precision.
// The default fixed-order Gauss rule is exact for planar and analytic faces
// but not across a B-spline's knot spans: a spline-walled extrude read 0.4–
// 1.3% high depending only on how the same curve was parameterised (found by
// the spline-profile pin, 2026-09-02). With Eps + IsUseSpan the B-rep volume
// matches the closed-form area × height to 1e-6.
static double OS3DVolume(const TopoDS_Shape &shape) {
    if (shape.IsNull()) return 0.0;
    try {
        GProp_GProps props;
        BRepGProp::VolumePropertiesGK(shape, props, /*Eps*/ 1e-7,
                                      /*OnlyClosed*/ Standard_False,
                                      /*IsUseSpan*/ Standard_True);
        return props.Mass();
    } catch (...) {
        return 0.0;
    }
}


+ (nullable OCCTShape *)draftedShape:(OCCTShape *)shape
                       atWorldPoints:(NSData *)worldPoints
                        angleRadians:(double)angleRadians
                          directionX:(double)dx directionY:(double)dy directionZ:(double)dz
                      neutralOriginX:(double)ox neutralOriginY:(double)oy neutralOriginZ:(double)oz
                      neutralNormalX:(double)nx neutralNormalY:(double)ny neutralNormalZ:(double)nz
                           tolerance:(double)tolerance
                              status:(nullable OCCTOpStatus *)status {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"no input");
    if (shape == nil || fabs(angleRadians) < 1e-9) return nil;
    const NSUInteger count = worldPoints.length / (3 * sizeof(double));
    if (count == 0) return nil;
    const double *pts = (const double *)worldPoints.bytes;

    try {
        if (!OS3DFiniteBounds(shape->_shape)) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"the body has empty or non-finite geometry");
            return nil;
        }
        int inputSolids = 0;
        TopoDS_Shape input = OS3DExtractSingleSolid(shape->_shape, inputSolids);
        if (input.IsNull()) input = shape->_shape;

        TopTools_IndexedMapOfShape faceMap;
        TopExp::MapShapes(input, TopAbs_FACE, faceMap);
        const std::set<Standard_Integer> chosen =
            OS3DNearestFaces(faceMap, pts, count, tolerance);
        if (chosen.empty()) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched,
                          @"no face within tolerance of the pick");
            return nil;
        }

        const gp_Dir pull(dx, dy, dz);
        const gp_Pln neutral(gp_Pnt(ox, oy, oz), gp_Dir(nx, ny, nz));
        BRepOffsetAPI_DraftAngle mk(input);
        for (Standard_Integer i : chosen) {
            const TopoDS_Face face = TopoDS::Face(faceMap(i));
            // Sign checked against the mesh path (DraftFaceBRepTests): OCCT's
            // positive angle already NARROWS the section along the pull
            // direction, matching the app's convention.
            mk.Add(face, pull, angleRadians, neutral, Standard_True);
            if (!mk.AddDone()) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                              [NSString stringWithFormat:
                               @"draft: face %d cannot take this draft (it may be "
                               @"parallel to the neutral plane, or the angle too large)",
                               (int)i]);
                return nil;
            }
        }
        OS3D_GUARDED(status, "draft", mk.Build());
        if (!mk.IsDone() || mk.Shape().IsNull()) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"draft: the kernel could not rebuild the drafted faces");
            return nil;
        }
        const TopoDS_Shape valid = OS3DHealAndValidate(mk.Shape());
        if (valid.IsNull()) {
            OS3DSetStatus(status, OCCTOpCodeInvalidResult,
                          @"draft: the drafted solid failed validity checking");
            return nil;
        }
        int outSolids = 0;
        const TopoDS_Shape single = OS3DExtractSingleSolid(valid, outSolids);
        if (single.IsNull()) {
            OS3DSetStatus(status, OCCTOpCodeMultiSolid,
                          @"draft: the result is not a single solid");
            return nil;
        }
        OS3DSetStatus(status, OCCTOpCodeOK, nil);
        OCCTShape *out = [OCCTShape new];
        out->_shape = single;
        return out;
    } catch (Standard_Failure &e) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                      [NSString stringWithFormat:@"%s", e.GetMessageString()]);
        return nil;
    } catch (...) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"kernel exception");
        return nil;
    }
}

// A fillet's approximated B-spline faces carry C0 knots, and C0 edge curves,
// where the rolling ball crosses from one support face to the next: tangent
// in fact, C0 by knot multiplicity. BRepOffset refuses any C0 geometry before
// it tries a join (BRepOffset_C0Geometry), so a body could not be shelled once
// a fillet ran over a curved junction (18.23's pipe on its dome, 2026-09-16).
// Splitting at those knots leaves every piece C1 without moving a point.
// Null when nothing needed splitting or the split failed.
static TopoDS_Shape OS3DSplitAtC0(const TopoDS_Shape &shape,
                                  Handle(BRepTools_History) &history) {
    try {
        ShapeUpgrade_ShapeDivideContinuity divide(shape);
        divide.SetBoundaryCriterion(GeomAbs_C1);
        divide.SetPCurveCriterion(GeomAbs_C1);
        divide.SetSurfaceCriterion(GeomAbs_C1);
        divide.Perform();
        if (!divide.Status(ShapeExtend_DONE)) return TopoDS_Shape();
        history = divide.GetContext()->History();
        return divide.Result();
    } catch (...) {
        return TopoDS_Shape();
    }
}

// The offset of a split body comes back with edges whose SameRange flag is
// wrong (invalidSameRangeFlag, 18.23's pipe shell). ShapeFix repairs that
// too, but it rebuilds every face and the ancestry with them; setting the
// flags in place keeps both. Only on edges the offset made: the rest are
// shared with the stored body.
static void OS3DSetSameRangeOnNewEdges(const TopoDS_Shape &built, const TopoDS_Shape &input) {
    TopTools_IndexedMapOfShape inputEdges;
    TopExp::MapShapes(input, TopAbs_EDGE, inputEdges);
    TopTools_IndexedMapOfShape builtEdges;
    TopExp::MapShapes(built, TopAbs_EDGE, builtEdges);
    for (Standard_Integer i = 1; i <= builtEdges.Extent(); ++i) {
        if (inputEdges.Contains(builtEdges(i))) continue;
        try { BRepLib::SameRange(TopoDS::Edge(builtEdges(i))); } catch (...) {}
    }
}

// The pieces a face or edge became through `history`: itself when untouched,
// nothing when removed.
static std::vector<TopoDS_Shape> OS3DImagesThrough(const Handle(BRepTools_History) &history,
                                                   const TopoDS_Shape &shape) {
    std::vector<TopoDS_Shape> out;
    if (history.IsNull()) return {shape};
    try {
        if (history->IsRemoved(shape)) return out;
        const TopTools_ListOfShape &images = history->Modified(shape);
        for (TopTools_ListIteratorOfListOfShape it(images); it.More(); it.Next()) {
            if (it.Value().ShapeType() < shape.ShapeType()) {
                for (TopExp_Explorer ex(it.Value(), shape.ShapeType()); ex.More(); ex.Next()) {
                    out.push_back(ex.Current());
                }
            } else {
                out.push_back(it.Value());
            }
        }
    } catch (...) {
        out.clear();
    }
    if (out.empty()) out.push_back(shape);
    return out;
}

// OS3DCollectMakerHistory for a maker that ran on a split copy of `input`
// (OS3DSplitAtC0). Rows still name the input's own faces and edges: a piece
// is modified from its source, and whatever the maker made of a piece is
// credited to the source.
static void OS3DCollectMakerHistoryThrough(BRepBuilderAPI_MakeShape &builder,
                                           const TopoDS_Shape &input,
                                           const Handle(BRepTools_History) &split,
                                           std::vector<OS3DHistEdge> &edges) {
    const struct { TopAbs_ShapeEnum type; int32_t kind; } kinds[] = {
        {TopAbs_FACE, 0}, {TopAbs_EDGE, 1}};
    for (const auto &k : kinds) {
        TopTools_IndexedMapOfShape map;
        TopExp::MapShapes(input, k.type, map);
        for (Standard_Integer i = 1; i <= map.Extent(); ++i) {
            for (const TopoDS_Shape &piece : OS3DImagesThrough(split, map(i))) {
                if (!piece.IsSame(map(i))) {
                    edges.push_back({piece, 0, k.kind, (int32_t)i, 1});
                }
                for (int32_t relation : {1, 2}) {
                    try {
                        const TopTools_ListOfShape &list = relation == 1
                            ? builder.Modified(piece) : builder.Generated(piece);
                        for (TopTools_ListIteratorOfListOfShape it(list);
                             it.More(); it.Next()) {
                            edges.push_back({it.Value(), 0, k.kind, (int32_t)i, relation});
                        }
                    } catch (...) {
                        // No history for this piece.
                    }
                }
            }
        }
    }
}

+ (nullable OCCTShape *)shelledShape:(OCCTShape *)shape
                       atWorldPoints:(NSData *)worldPoints
                           thickness:(double)thickness
                           tolerance:(double)tolerance
                              status:(nullable OCCTOpStatus *)status {
    return [self shelledShape:shape atWorldPoints:worldPoints
                    thickness:thickness tolerance:tolerance
                       status:status history:nil];
}

+ (nullable OCCTShape *)shelledShape:(OCCTShape *)shape
                       atWorldPoints:(NSData *)worldPoints
                           thickness:(double)thickness
                           tolerance:(double)tolerance
                              status:(nullable OCCTOpStatus *)status
                             history:(nullable OCCTShapeHistory *)history {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"no input");
    if (shape == nil || thickness == 0.0) return nil;
    const NSUInteger count = worldPoints.length / (3 * sizeof(double));
    const double *pts = count > 0 ? (const double *)worldPoints.bytes : NULL;

    try {
        if (!OS3DFiniteBounds(shape->_shape)) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"the body has empty or non-finite geometry");
            return nil;
        }
        // MakeThickSolid is specified for a SOLID. A body stored before
        // boolean results were normalized can still carry a one-solid
        // COMPOUND — unwrap it here so the op stays in contract.
        int inputSolids = 0;
        TopoDS_Shape input = OS3DExtractSingleSolid(shape->_shape, inputSolids);
        if (input.IsNull()) input = shape->_shape;

        // Faces to open: those with a sample within tolerance of a picked point.
        // Empty selection => fully-enclosed hollow.
        TopTools_ListOfShape openFaces;
        // Signed: positive hollows INWARD (the wall lies inside the original
        // surface), negative grows OUTWARD (the original surface becomes the
        // cavity) — the tutorial move for a profile whose grooves are tighter
        // than any inward wall (2026-09-02, the Coke bottle).
        const bool outward = thickness < 0;
        const double offset = outward ? fabs(thickness) : -fabs(thickness);
        if (count > 0) {
            // Nearest-wins (see OS3DNearestFaces): the old rule opened every
            // face within tolerance, which on a thin plate meant picking the
            // top also opened the bottom.
            TopTools_IndexedMapOfShape faceMap;
            TopExp::MapShapes(input, TopAbs_FACE, faceMap);
            for (Standard_Integer i : OS3DNearestFaces(faceMap, pts, count, tolerance)) {
                openFaces.Append(TopoDS::Face(faceMap(i)));
            }
            // The caller ASKED for openings but nothing matched. Falling
            // through to the fully-enclosed branch silently sealed the body:
            // IsDone() passes, a valid closed hollow comes back, and the user
            // gets a shell with no opening and no diagnostic (2026-08-25
            // review round 4). Refuse instead, so the error surfaces.
            if (openFaces.IsEmpty()) {
                OS3DSetStatus(status, OCCTOpCodeNoTargetMatched,
                              @"no face within tolerance of the pick");
                return nil;
            }
        }

        TopoDS_Shape built;
        std::vector<OS3DHistEdge> histEdges;
        if (openFaces.IsEmpty()) {
            // Fully-enclosed hollow: offset the solid inward and SUBTRACT the
            // shrunken copy. (ByJoin with an empty closing-face list hands
            // back the original solid, and MakeThickSolidBySimple refuses a
            // closed solid outright — it never worked; the mesh fallback was
            // silently covering for it until eval stopped degrading.)
            BRepOffsetAPI_MakeOffsetShape off;
            off.PerformByJoin(input, offset, 1.0e-3);
            BRepOffsetAPI_MakeOffsetShape offSplit;
            BRepOffsetAPI_MakeOffsetShape *offMade =
                (off.IsDone() && !off.Shape().IsNull()) ? &off : nullptr;
            int offCode = -1;
            if (offMade == nullptr) {
                try { offCode = (int)off.MakeOffset().Error(); } catch (...) {}
            }
            // The same C0 split as the open shell below.
            if (offMade == nullptr && offCode == (int)BRepOffset_C0Geometry) {
                Handle(BRepTools_History) splitHistory;
                const TopoDS_Shape split = OS3DSplitAtC0(input, splitHistory);
                if (!split.IsNull()) {
                    try {
                        offSplit.PerformByJoin(split, offset, 1.0e-3);
                        if (offSplit.IsDone() && !offSplit.Shape().IsNull()) {
                            offMade = &offSplit;
                            OS3DSetSameRangeOnNewEdges(offSplit.Shape(), input);
                        }
                    } catch (...) {
                        offMade = nullptr;
                    }
                }
            }
            if (offMade == nullptr) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                              @"the wall thickness is out of range for this shape");
                return nil;
            }
            int innerSolids = 0;
            TopoDS_Shape inner = OS3DExtractSingleSolid(offMade->Shape(), innerSolids);
            if (inner.IsNull()) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                              @"the wall thickness is out of range for this shape");
                return nil;
            }
            // Inward: the original minus its shrunken copy. Outward: the
            // grown copy minus the original. Non-destructive, like
            // booleanOfShape: a default cut writes pcurves onto the input's
            // edges in place (24 on 18.23's filleted body, 2026-09-17), and
            // the input is the stored body undo snapshots share.
            TopTools_ListOfShape cutArgs, cutTools;
            cutArgs.Append(outward ? inner : input);
            cutTools.Append(outward ? input : inner);
            BRepAlgoAPI_Cut cut;
            cut.SetArguments(cutArgs);
            cut.SetTools(cutTools);
            cut.SetNonDestructive(Standard_True);
            cut.Build();
            if (!cut.IsDone() || cut.HasErrors()) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                              @"hollowing failed on this shape");
                return nil;
            }
            built = cut.Shape();
        } else {
            BRepOffsetAPI_MakeThickSolid mk;
            mk.MakeThickSolidByJoin(input, openFaces, offset, 1.0e-3);
            // Arc joins are OCCT's default and the robust choice on analytic
            // walls; a B-spline wall (a revolved traced profile) can fail
            // them and still offset with INTERSECTION joins. Try those
            // before refusing.
            BRepOffsetAPI_MakeThickSolid mkIntersection;
            BRepOffsetAPI_MakeThickSolid *made = mk.IsDone() ? &mk : nullptr;
            int code = -1;
            if (made == nullptr) {
                try { code = (int)mk.MakeOffset().Error(); } catch (...) {}
            }
            // A fillet's B-spline faces refuse every join (C0Geometry): split
            // the body where they are C0 and retry with arc joins. Intersection
            // joins on the split body did not heal (18.23, 2026-09-16).
            BRepOffsetAPI_MakeThickSolid mkSplit;
            TopoDS_Shape split;
            Handle(BRepTools_History) splitHistory;
            NSString *retryNote = @"";
            if (made == nullptr && code == (int)BRepOffset_C0Geometry) {
                split = OS3DSplitAtC0(input, splitHistory);
                if (!split.IsNull()) {
                    TopTools_ListOfShape splitOpenFaces;
                    for (TopTools_ListIteratorOfListOfShape it(openFaces); it.More(); it.Next()) {
                        for (const TopoDS_Shape &piece : OS3DImagesThrough(splitHistory, it.Value())) {
                            splitOpenFaces.Append(piece);
                        }
                    }
                    // The refusal names the retry's own failure: reporting
                    // the first C0Geometry sent readers after C0 faces the
                    // split had already removed (18.23, 2026-09-17).
                    try {
                        mkSplit.MakeThickSolidByJoin(split, splitOpenFaces, offset, 1.0e-3);
                        if (mkSplit.IsDone()) {
                            made = &mkSplit;
                        } else {
                            code = (int)mkSplit.MakeOffset().Error();
                            retryNote = @", after splitting its C0 faces";
                        }
                    } catch (Standard_Failure &e) {
                        made = nullptr;
                        code = -2;
                        NSString *what = [@(e.GetMessageString()) stringByTrimmingCharactersInSet:
                                          [NSCharacterSet whitespaceCharacterSet]];
                        if (what.length > 0) retryNote = [@": " stringByAppendingString:what];
                    } catch (...) {
                        made = nullptr;
                        code = -2;
                    }
                }
            }
            if (made == nullptr && split.IsNull()) {
                try {
                    mkIntersection.MakeThickSolidByJoin(
                        input, openFaces, offset, 1.0e-3, BRepOffset_Skin,
                        Standard_True, Standard_False, GeomAbs_Intersection);
                    if (mkIntersection.IsDone()) made = &mkIntersection;
                } catch (...) {
                    made = nullptr;
                }
            }
            if (made == nullptr) {
                // Say WHY: BRepOffset's own error code, so a refusal on a
                // curved wall can be told apart from a wall eating the body.
                static const char *const kOffsetErrors[] = {
                    "NoError", "UnknownError", "BadNormalsOnGeometry",
                    "C0Geometry", "NullOffset", "NotConnectedShell",
                    "CannotTrimEdges", "CannotFuseVertices", "CannotExtentEdge",
                    "UserBreak", "MixedConnectivity"};
                const char *name = (code >= 0 && code < 11) ? kOffsetErrors[code] : "?";
                OS3DSetStatus(status, OCCTOpCodeKernelRefused, code == -2
                    ? [NSString stringWithFormat:@"the wall thickness is out of range for this shape (OCCT offset threw after splitting its C0 faces%@)", retryNote]
                    : [NSString stringWithFormat:@"the wall thickness is out of range for this shape (OCCT offset: %s%@)", name, retryNote]);
                return nil;
            }
            built = made->Shape();
            if (made == &mkSplit) OS3DSetSameRangeOnNewEdges(built, input);
            // Harvest before the maker dies with this scope.
            if (history != nil) {
                if (made == &mkSplit) {
                    OS3DCollectMakerHistoryThrough(*made, input, splitHistory, histEdges);
                } else {
                    OS3DCollectMakerHistory(*made, {input}, histEdges);
                }
            }
        }

        int solidCount = 0;
        TopoDS_Shape result = OS3DExtractSingleSolid(built, solidCount);
        if (result.IsNull()) result = built;
        const TopoDS_Shape valid = OS3DHealAndValidate(result);
        if (valid.IsNull()) {
            OS3DSetStatus(status, OCCTOpCodeInvalidResult,
                          @"the shelled solid failed validity checking");
            return nil;
        }
        // A shell moves material by definition: INWARD removes it, OUTWARD
        // adds it. A "hollow" whose volume went nowhere — or the wrong way —
        // is the sealed-body failure mode wearing a valid topology; refuse
        // it (docs/FREECAD_PLAYBOOK.md B2).
        const double before = OS3DVolume(input);
        const double after = OS3DVolume(valid);
        if (before > 0) {
            const bool unchanged = fabs(after - before) <= before * 1e-9;
            const bool wrongWay = outward ? (after <= before) : (after >= before);
            if (unchanged || wrongWay) {
                OS3DSetStatus(status, OCCTOpCodeInvalidResult,
                              outward ? @"the shell added no material"
                                      : @"the shell removed no material");
                return nil;
            }
        }

        OS3DSetStatus(status, OCCTOpCodeOK, nil);
        // Same-face survival plus whatever the thick-solid maker reported;
        // the closed-hollow branch harvests nothing, so its OUTER faces
        // inherit via the survival pass and the new inner faces stay
        // honestly unnamed.
        if (history != nil) {
            OS3DFillHistory(history, histEdges, {input},
                            Handle(BRepTools_History)(), valid,
                            /*truncatedByHeal*/ !valid.IsSame(result));
        }
        OCCTShape *out = [OCCTShape new];
        out->_shape = valid;
        return out;
    } catch (Standard_Failure &e) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                      [NSString stringWithFormat:@"%s", e.GetMessageString()]);
        return nil;
    } catch (...) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"kernel exception");
        return nil;
    }
}

+ (double)volumeOfShape:(OCCTShape *)shape {
    if (shape == nil) return 0.0;
    return OS3DVolume(shape->_shape);
}

+ (double)maxToleranceOfShape:(OCCTShape *)shape {
    if (shape == nil || shape->_shape.IsNull()) return 0.0;
    try {
        ShapeAnalysis_ShapeTolerance analysis;
        // mode > 0 = the MAXIMAL tolerance any sub-shape carries.
        return analysis.Tolerance(shape->_shape, 1);
    } catch (...) {
        return 0.0;
    }
}

+ (BOOL)writeSTEPShapes:(NSArray<OCCTShape *> *)shapes toPath:(NSString *)path {
    if (shapes.count == 0 || path.length == 0) return NO;
    try {
        STEPControl_Writer writer;
        for (OCCTShape *s in shapes) {
            if (s == nil || s->_shape.IsNull()) continue;
            if (writer.Transfer(s->_shape, STEPControl_AsIs) != IFSelect_RetDone) return NO;
        }
        return writer.Write(path.fileSystemRepresentation) == IFSelect_RetDone;
    } catch (...) {
        return NO;
    }
}

+ (NSArray<OCCTShape *> *)readSTEPFromPath:(NSString *)path {
    NSMutableArray<OCCTShape *> *out = [NSMutableArray array];
    if (path.length == 0) return out;
    try {
        STEPControl_Reader reader;
        if (reader.ReadFile(path.fileSystemRepresentation) != IFSelect_RetDone) return out;
        reader.TransferRoots();
        // Imported geometry is a TRUST BOUNDARY: heal-and-validate each
        // solid on the way in (one ShapeFix pass — FreeCAD heals at import
        // too, docs/FREECAD_PLAYBOOK.md H1) and DROP what still doesn't
        // validate, so a dirty export can't seed a body every later op
        // chokes on.
        const auto append = [out](const TopoDS_Shape &candidate) {
            if (!OS3DFiniteBounds(candidate)) return;
            const TopoDS_Shape valid = OS3DHealAndValidate(candidate);
            if (valid.IsNull()) return;
            OCCTShape *w = [OCCTShape new];
            w->_shape = valid;
            [out addObject:w];
        };
        for (Standard_Integer i = 1; i <= reader.NbShapes(); ++i) {
            const TopoDS_Shape shape = reader.Shape(i);
            if (shape.IsNull()) continue;
            // A STEP root can be a compound; emit each solid separately so each
            // becomes its own body.
            TopExp_Explorer solids(shape, TopAbs_SOLID);
            if (solids.More()) {
                for (; solids.More(); solids.Next()) append(solids.Current());
            } else {
                append(shape);
            }
        }
    } catch (...) {
        return [NSMutableArray array];
    }
    return out;
}

// MARK: - Geometry health (docs/FREECAD_PLAYBOOK.md D1)

// Enumerator-derived name for a BRepCheck status. Written from the OCCT enum
// itself (BRepCheck_Status.hxx), so the strings track the kernel, not any
// other tool's UI copy.
static NSString *OS3DCheckStatusName(BRepCheck_Status status) {
    switch (status) {
        case BRepCheck_NoError: return @"noError";
        case BRepCheck_InvalidPointOnCurve: return @"invalidPointOnCurve";
        case BRepCheck_InvalidPointOnCurveOnSurface: return @"invalidPointOnCurveOnSurface";
        case BRepCheck_InvalidPointOnSurface: return @"invalidPointOnSurface";
        case BRepCheck_No3DCurve: return @"no3DCurve";
        case BRepCheck_Multiple3DCurve: return @"multiple3DCurve";
        case BRepCheck_Invalid3DCurve: return @"invalid3DCurve";
        case BRepCheck_NoCurveOnSurface: return @"noCurveOnSurface";
        case BRepCheck_InvalidCurveOnSurface: return @"invalidCurveOnSurface";
        case BRepCheck_InvalidCurveOnClosedSurface: return @"invalidCurveOnClosedSurface";
        case BRepCheck_InvalidSameRangeFlag: return @"invalidSameRangeFlag";
        case BRepCheck_InvalidSameParameterFlag: return @"invalidSameParameterFlag";
        case BRepCheck_InvalidDegeneratedFlag: return @"invalidDegeneratedFlag";
        case BRepCheck_FreeEdge: return @"freeEdge";
        case BRepCheck_InvalidMultiConnexity: return @"invalidMultiConnexity";
        case BRepCheck_InvalidRange: return @"invalidRange";
        case BRepCheck_EmptyWire: return @"emptyWire";
        case BRepCheck_RedundantEdge: return @"redundantEdge";
        case BRepCheck_SelfIntersectingWire: return @"selfIntersectingWire";
        case BRepCheck_NoSurface: return @"noSurface";
        case BRepCheck_InvalidWire: return @"invalidWire";
        case BRepCheck_RedundantWire: return @"redundantWire";
        case BRepCheck_IntersectingWires: return @"intersectingWires";
        case BRepCheck_InvalidImbricationOfWires: return @"invalidImbricationOfWires";
        case BRepCheck_EmptyShell: return @"emptyShell";
        case BRepCheck_RedundantFace: return @"redundantFace";
        case BRepCheck_InvalidImbricationOfShells: return @"invalidImbricationOfShells";
        case BRepCheck_UnorientableShape: return @"unorientableShape";
        case BRepCheck_NotClosed: return @"notClosed";
        case BRepCheck_NotConnected: return @"notConnected";
        case BRepCheck_SubshapeNotInShape: return @"subshapeNotInShape";
        case BRepCheck_BadOrientation: return @"badOrientation";
        case BRepCheck_BadOrientationOfSubshape: return @"badOrientationOfSubshape";
        case BRepCheck_InvalidPolygonOnTriangulation: return @"invalidPolygonOnTriangulation";
        case BRepCheck_InvalidToleranceValue: return @"invalidToleranceValue";
        case BRepCheck_EnclosedRegion: return @"enclosedRegion";
        case BRepCheck_CheckFail: return @"checkFail";
    }
    return @"unknownStatus";
}

static NSString *OS3DBOPStatusName(BOPAlgo_CheckStatus status) {
    switch (status) {
        case BOPAlgo_CheckUnknown: return @"unknown";
        case BOPAlgo_BadType: return @"badType";
        case BOPAlgo_SelfIntersect: return @"selfIntersect";
        case BOPAlgo_TooSmallEdge: return @"tooSmallEdge";
        case BOPAlgo_NonRecoverableFace: return @"nonRecoverableFace";
        case BOPAlgo_IncompatibilityOfVertex: return @"incompatibilityOfVertex";
        case BOPAlgo_IncompatibilityOfEdge: return @"incompatibilityOfEdge";
        case BOPAlgo_IncompatibilityOfFace: return @"incompatibilityOfFace";
        case BOPAlgo_OperationAborted: return @"operationAborted";
        case BOPAlgo_GeomAbs_C0: return @"c0Continuity";
        case BOPAlgo_InvalidCurveOnSurface: return @"invalidCurveOnSurface";
        case BOPAlgo_NotValid: return @"notValid";
    }
    return @"unknownStatus";
}

static NSString *OS3DShapeTypeWord(TopAbs_ShapeEnum type) {
    switch (type) {
        case TopAbs_COMPOUND: return @"Compound";
        case TopAbs_COMPSOLID: return @"CompSolid";
        case TopAbs_SOLID: return @"Solid";
        case TopAbs_SHELL: return @"Shell";
        case TopAbs_FACE: return @"Face";
        case TopAbs_WIRE: return @"Wire";
        case TopAbs_EDGE: return @"Edge";
        case TopAbs_VERTEX: return @"Vertex";
        case TopAbs_SHAPE: return @"Shape";
    }
    return @"Shape";
}

// Names a sub-shape "Face3"/"Edge17": the 1-based index into the ROOT shape's
// indexed map of that type. Stable for a given shape, and what lets a report
// reader (or a test) point at the exact offender. Maps are built lazily, one
// per type actually named.
class OS3DSubshapeNamer {
public:
    explicit OS3DSubshapeNamer(const TopoDS_Shape &root) : myRoot(root) {}
    NSString *name(const TopoDS_Shape &sub) {
        const TopAbs_ShapeEnum type = sub.ShapeType();
        NSString *word = OS3DShapeTypeWord(type);
        if (type == TopAbs_COMPOUND || type == TopAbs_COMPSOLID) return word;
        TopTools_IndexedMapOfShape &map = myMaps[type];
        if (map.IsEmpty()) TopExp::MapShapes(myRoot, type, map);
        const Standard_Integer index = map.FindIndex(sub);
        // Index 0 = not a sub-shape of the root (shouldn't happen; the type
        // word alone is still more useful than a crash).
        return index > 0 ? [NSString stringWithFormat:@"%@%d", word, (int)index] : word;
    }
private:
    TopoDS_Shape myRoot;
    std::map<TopAbs_ShapeEnum, TopTools_IndexedMapOfShape> myMaps;
};

// A pathological shape can carry thousands of faults; past this the report
// stops saying anything new and starts being the problem.
static const NSUInteger kOS3DMaxFindings = 200;

+ (NSDictionary<NSString *, id> *)healthReportForShape:(OCCTShape *)shape
                                           runBOPCheck:(BOOL)runBOPCheck {
    NSMutableDictionary<NSString *, id> *report = [NSMutableDictionary dictionary];
    report[@"bopCheckRan"] = @NO;
    if (shape == nil || shape->_shape.IsNull()) {
        report[@"valid"] = @NO;
        report[@"error"] = @"null shape";
        return report;
    }
    // The render mesh stored on the shape is not model data; report on the
    // geometry (see OS3DIsValid). The copy has the same sub-shape order, so
    // "Edge21" names the same edge either way.
    TopoDS_Shape bare;
    try {
        if (OS3DHasTriangulation(shape->_shape)) bare = OS3DWithoutMesh(shape->_shape);
    } catch (...) {
        bare.Nullify();
    }
    const TopoDS_Shape &root = bare.IsNull() ? shape->_shape : bare;
    try {
        // Cheap context first — these frame every finding (a 0-volume "solid"
        // or a 1e-2 max tolerance is often the whole diagnosis by itself).
        NSMutableDictionary *counts = [NSMutableDictionary dictionary];
        const struct { TopAbs_ShapeEnum type; NSString *key; } kinds[] = {
            {TopAbs_SOLID, @"solids"}, {TopAbs_SHELL, @"shells"},
            {TopAbs_FACE, @"faces"}, {TopAbs_WIRE, @"wires"},
            {TopAbs_EDGE, @"edges"}, {TopAbs_VERTEX, @"vertices"},
        };
        for (const auto &kind : kinds) {
            // MapShapes, not an explorer walk: the explorer visits a shared
            // sub-shape once PER PARENT (a box counts 24 edges), the indexed
            // map once — and once is what "12 edges" means to a reader.
            TopTools_IndexedMapOfShape map;
            TopExp::MapShapes(root, kind.type, map);
            counts[kind.key] = @((NSInteger)map.Extent());
        }
        report[@"counts"] = counts;
        report[@"volumeMM3"] = @(OS3DVolume(root));
        ShapeAnalysis_ShapeTolerance tolAnalysis;
        report[@"tolerance"] = @{
            @"min": @(tolAnalysis.Tolerance(root, -1)),
            @"avg": @(tolAnalysis.Tolerance(root, 0)),
            @"max": @(tolAnalysis.Tolerance(root, 1)),
        };

        // Free boundary wires: a healthy solid has none, and an open shell's
        // open wires ARE its holes — each one is one boundary loop.
        try {
            ShapeAnalysis_FreeBounds freeBounds(root);
            NSInteger open = 0, closed = 0;
            const TopoDS_Compound openWires = freeBounds.GetOpenWires();
            if (!openWires.IsNull()) {
                for (TopoDS_Iterator it(openWires); it.More(); it.Next()) ++open;
            }
            const TopoDS_Compound closedWires = freeBounds.GetClosedWires();
            if (!closedWires.IsNull()) {
                for (TopoDS_Iterator it(closedWires); it.More(); it.Next()) ++closed;
            }
            report[@"openFreeWires"] = @(open);
            report[@"closedFreeWires"] = @(closed);
        } catch (...) {
            // Advisory only; the validity check below still runs.
        }

        // One analyzer for the whole walk: it computes per-sub-shape results
        // at construction, so every query below is a lookup, not a re-check.
        BRepCheck_Analyzer analyzer(root);
        const bool valid = analyzer.IsValid() == Standard_True;
        report[@"valid"] = @(valid);

        NSMutableArray *findings = [NSMutableArray array];
        if (!valid) {
            OS3DSubshapeNamer namer(root);
            TopTools_MapOfShape visited;
            std::function<void(const TopoDS_Shape &)> walk =
                [&](const TopoDS_Shape &current) {
                if (findings.count >= kOS3DMaxFindings) return;
                // Shared sub-shapes (an edge under two faces) are reached
                // repeatedly by the recursion; report each once.
                if (!visited.Add(current)) return;

                // The status a shape carries IN ITSELF.
                const Handle(BRepCheck_Result) own = analyzer.Result(current);
                if (!own.IsNull()) {
                    for (BRepCheck_ListIteratorOfListOfStatus it(own->Status());
                         it.More(); it.Next()) {
                        if (it.Value() == BRepCheck_NoError) continue;
                        [findings addObject:@{
                            @"subshape": namer.name(current),
                            @"type": OS3DShapeTypeWord(current.ShapeType()),
                            @"status": OS3DCheckStatusName(it.Value()),
                        }];
                    }
                }

                // The status a sub-shape carries IN THIS PARENT. OCCT stores
                // these against the (sub, context) pair — a wire can be fine
                // alone and self-intersecting in its face — so they are only
                // reachable through the context iterator, filtered to the
                // parent being walked.
                std::vector<TopAbs_ShapeEnum> subTypes;
                switch (current.ShapeType()) {
                    case TopAbs_SOLID: subTypes = {TopAbs_SHELL}; break;
                    case TopAbs_FACE:
                        subTypes = {TopAbs_WIRE, TopAbs_EDGE, TopAbs_VERTEX};
                        break;
                    case TopAbs_EDGE: subTypes = {TopAbs_VERTEX}; break;
                    default: break;
                }
                for (TopAbs_ShapeEnum subType : subTypes) {
                    for (TopExp_Explorer ex(current, subType); ex.More(); ex.Next()) {
                        const Handle(BRepCheck_Result) sub = analyzer.Result(ex.Current());
                        if (sub.IsNull()) continue;
                        for (sub->InitContextIterator(); sub->MoreShapeInContext();
                             sub->NextShapeInContext()) {
                            if (!sub->ContextualShape().IsSame(current)) continue;
                            for (BRepCheck_ListIteratorOfListOfStatus it(sub->StatusOnShape());
                                 it.More(); it.Next()) {
                                if (it.Value() == BRepCheck_NoError) continue;
                                if (findings.count >= kOS3DMaxFindings) return;
                                [findings addObject:@{
                                    @"subshape": namer.name(ex.Current()),
                                    @"type": OS3DShapeTypeWord(ex.Current().ShapeType()),
                                    @"status": OS3DCheckStatusName(it.Value()),
                                    @"context": namer.name(current),
                                }];
                            }
                        }
                    }
                }

                for (TopoDS_Iterator it(current); it.More(); it.Next()) {
                    walk(it.Value());
                }
            };
            walk(root);
            if (findings.count >= kOS3DMaxFindings) {
                report[@"findingsTruncated"] = @YES;
            }
        }
        report[@"findings"] = findings;

        // The BOP check finds what BRepCheck cannot (self-intersections,
        // too-small edges) but is SLOW and advisory — run it only on request
        // and only on a shape BRepCheck already passed, under the kernel
        // deadline so a pathological case aborts instead of hanging.
        if (runBOPCheck && valid) {
            try {
                // The analyzer works on a copy: it may touch the shape's
                // shared internals, and this report must never mutate the
                // solid it is reporting on.
                const TopoDS_Shape copy = BRepBuilderAPI_Copy(root).Shape();
                BOPAlgo_ArgumentAnalyzer bop;
                bop.SetShape1(copy);
                bop.ArgumentTypeMode() = Standard_True;
                bop.SelfInterMode() = Standard_True;
                bop.SmallEdgeMode() = Standard_True;
                bop.RebuildFaceMode() = Standard_True;
                bop.ContinuityMode() = Standard_True;
                bop.TangentMode() = Standard_True;
                bop.MergeVertexMode() = Standard_True;
                bop.MergeEdgeMode() = Standard_True;
                bop.CurveOnSurfaceMode() = Standard_True;
                bop.SetRunParallel(Standard_True);
                OS3DDeadlineProgress *deadline =
                    new OS3DDeadlineProgress(kOS3DKernelDeadlineSeconds);
                Handle(Message_ProgressIndicator) progress(deadline);
                bop.Perform(progress->Start());
                if (deadline->Fired()) {
                    report[@"bopCheckError"] = @"deadline exceeded";
                } else {
                    report[@"bopCheckRan"] = @YES;
                    NSMutableArray *bopFindings = [NSMutableArray array];
                    if (bop.HasFaulty()) {
                        // Faulty shapes belong to the COPY — index against it,
                        // not the original, or FindIndex answers 0.
                        OS3DSubshapeNamer copyNamer(copy);
                        for (BOPAlgo_ListIteratorOfListOfCheckResult it(bop.GetCheckResult());
                             it.More(); it.Next()) {
                            NSString *status = OS3DBOPStatusName(it.Value().GetCheckStatus());
                            for (TopTools_ListIteratorOfListOfShape faulty(
                                     it.Value().GetFaultyShapes1());
                                 faulty.More(); faulty.Next()) {
                                if (bopFindings.count >= kOS3DMaxFindings) break;
                                [bopFindings addObject:@{
                                    @"subshape": copyNamer.name(faulty.Value()),
                                    @"type": OS3DShapeTypeWord(faulty.Value().ShapeType()),
                                    @"status": status,
                                }];
                            }
                        }
                    }
                    report[@"bopFindings"] = bopFindings;
                }
            } catch (const Standard_Failure &failure) {
                const char *message = failure.GetMessageString();
                report[@"bopCheckError"] = [NSString stringWithFormat:@"%s: %s",
                    failure.DynamicType()->Name(),
                    (message && message[0]) ? message : "no kernel message"];
            } catch (...) {
                report[@"bopCheckError"] = @"the BOP check threw";
            }
        }
    } catch (const Standard_Failure &failure) {
        report[@"valid"] = @NO;
        const char *message = failure.GetMessageString();
        report[@"error"] = [NSString stringWithFormat:@"%s: %s",
            failure.DynamicType()->Name(),
            (message && message[0]) ? message : "no kernel message"];
    } catch (...) {
        report[@"valid"] = @NO;
        report[@"error"] = @"the health check threw";
    }
    return report;
}

// Trust-boundary pre-check (fuzz family "count-*"): the ASCII brep format is
// full of declared counts — section headers ("Curve2ds 2147483647") AND
// per-record fields deep inside the data — and OCCT's readers loop or
// allocate on the DECLARED value without consulting the progress indicator,
// so the read deadline cannot fire: an inflated section count spins a 2KB
// blob for minutes, and an inflated in-record count crashes the process
// outright (both found by OCCTFuzzTests). Two tiers, both structural:
//
//  1. A NAMED section's count is the number of serialized records, each at
//     least a byte, so a count above the blob's byte length is impossible.
//  2. Any OTHER pure-integer token is an index, a per-record count, or a
//     flag — or a coordinate that happened to print without a fraction
//     ("5000" for a 5m part), which is why the strict length bound cannot
//     apply globally. The loose ceiling max(length, 10^7) is above any
//     legitimate coordinate/index this app can produce (10^7 mm = 10 km;
//     counts of 10^7 need 10^7 bytes, which raises the ceiling with them)
//     and below every crash/hang value the fuzz corpus found (>= 10^9).
//
// Floats never match either tier — their tokens carry '.' or an exponent.
// TShapes' signed refs ("-3") parse negative and pass; OCCT rejects those
// cheaply on its own. One pass, reject before OCCT parses.
static bool OS3DPlausibleSectionCounts(NSData *data) {
    static const char *const kSections[] = {
        "Locations", "Curve2ds", "Curves", "Polygon3D",
        "PolygonOnTriangulations", "Surfaces", "Triangulations", "TShapes",
    };
    const char *bytes = (const char *)data.bytes;
    const long long length = (long long)data.length;
    // NON-TEXT bytes: `BRepTools::Write` emits pure printable ASCII plus
    // whitespace, so any other byte is structurally impossible in a valid
    // blob — but istringstream passes it straight through, where a NUL splits
    // a numeric token mid-value and a high byte (0xFF) derails the tokenizer,
    // both into crashes (fuzz nul-at-*, flip-*=FF). Reject anything outside
    // {tab, LF, CR, 0x20–0x7E} in one pass, before OCCT sees a byte of it.
    for (long long k = 0; k < length; ++k) {
        const unsigned char ch = (unsigned char)bytes[k];
        if (ch == '\t' || ch == '\n' || ch == '\r') continue;
        if (ch < 0x20 || ch > 0x7E) return false;
    }
    const long long looseCeiling = length > 10'000'000 ? length : 10'000'000;
    long long i = 0;
    bool atLineStart = true;
    while (i < length) {
        if (isspace((unsigned char)bytes[i])) {
            atLineStart = (bytes[i] == '\n');
            ++i;
            continue;
        }
        const long long start = i;
        while (i < length && !isspace((unsigned char)bytes[i])) ++i;
        const long long tokenLen = i - start;

        // A section keyword at line start arms the strict bound for the
        // integer token that follows it on the same line.
        bool strict = false;
        if (atLineStart) {
            for (const char *section : kSections) {
                if (tokenLen == (long long)strlen(section)
                    && memcmp(bytes + start, section, (size_t)tokenLen) == 0) {
                    strict = true;
                    break;
                }
            }
        }
        atLineStart = false;
        if (strict) {
            // Peek the next token on this line; a non-integer just falls
            // through to the normal scan.
            long long j = i;
            while (j < length && (bytes[j] == ' ' || bytes[j] == '\t')) ++j;
            long long numStart = j;
            while (j < length && isdigit((unsigned char)bytes[j])) ++j;
            const long long numLen = j - numStart;
            if (numLen > 0 && numLen < 20
                && (j == length || isspace((unsigned char)bytes[j]))) {
                char buffer[24];
                memcpy(buffer, bytes + numStart, (size_t)numLen);
                buffer[numLen] = '\0';
                errno = 0;
                const long long count = strtoll(buffer, nullptr, 10);
                if (errno == ERANGE || count > length) return false;
                i = j;
                continue;
            }
            if (numLen >= 20) return false;  // absurd digit run
        }

        // TShapes references are an ORIENTATION MARKER ({*,+,-}) glued to a
        // table index: "+3", "-3", "*2". OCCT indexes the shape table with
        // that number UNCHECKED, so an out-of-range or NEGATIVE index is a
        // straight segfault (fuzz cases ref-*-huge, ref-+-big, ref-+-neg).
        // The index counts serialized records, so it is bounded by the blob's
        // byte length — the STRICT bound, tighter than the loose ceiling a
        // bare integer coordinate gets. Distinguish them by the marker: a
        // marked token is a ref (strict), a bare integer is a
        // count/coordinate (loose). A valid blob never doubles a sign/marker
        // ("+-5") nor uses a negative index, so both are rejected
        // structurally — magnitude alone can't catch index -5.
        long long p = start;
        const bool markedRef =
            (bytes[p] == '*' || bytes[p] == '+' || bytes[p] == '-');
        if (markedRef) ++p;
        bool negativeIndex = false;
        if (p < i && (bytes[p] == '+' || bytes[p] == '-')) {
            negativeIndex = (bytes[p] == '-');
            ++p;
        }
        if (p == i) continue;  // only markers/signs, no digits
        bool digitsOnly = true;
        for (long long j = p; j < i; ++j) {
            if (!isdigit((unsigned char)bytes[j])) { digitsOnly = false; break; }
        }
        if (!digitsOnly) {
            // Not a pure integer. Two narrow, unambiguous rejections; anything
            // else (keywords, well-formed finite floats, and OCCT's own glued
            // codes like "4CN" edge-continuity) is left for OCCT to read:
            //   - A "0x…" HEX prefix: strtod parses it as a hex float but
            //     OCCT's istream>> reads only the leading "0" and chokes on
            //     'x', desyncing the tokenizer into reading a count/index from
            //     garbage — a crash records later (fuzz numeric-hex). No valid
            //     BRep token is hex.
            //   - A token strtod consumes WHOLLY into a NON-FINITE double
            //     ("1e999" → inf, bare "inf"/"nan"): inf coordinates crash
            //     geometry reconstruction inside BRepTools::Read, before the
            //     finite-bounds guard sees the shape (fuzz numeric-1e999). A
            //     partial parse ("4CN" → 4, stops at 'C') is finite and kept.
            long long h = start;
            if (bytes[h] == '+' || bytes[h] == '-') ++h;
            if (h + 1 < i && bytes[h] == '0'
                && (bytes[h + 1] == 'x' || bytes[h + 1] == 'X')) {
                return false;
            }
            if (tokenLen < 64) {
                char fbuf[64];
                memcpy(fbuf, bytes + start, (size_t)tokenLen);
                fbuf[tokenLen] = '\0';
                char *fend = nullptr;
                const double d = strtod(fbuf, &fend);
                if (fend == fbuf + tokenLen && !isfinite(d)) return false;
            }
            continue;  // words, finite floats, OCCT glued codes
        }
        if (negativeIndex) return false;  // a negative index/ref is invalid
        const long long numLen = i - p;
        if (numLen >= 20) return false;   // > 19 digits: overflow by size
        char buffer[24];
        memcpy(buffer, bytes + p, (size_t)numLen);
        buffer[numLen] = '\0';
        errno = 0;
        const long long value = strtoll(buffer, nullptr, 10);
        const long long ceiling = markedRef ? length : looseCeiling;
        if (errno == ERANGE || value > ceiling) return false;
    }
    return true;
}

+ (nullable OCCTShape *)rawShapeFromSerialized:(NSData *)data {
    if (data.length == 0) return nil;
    if (!OS3DPlausibleSectionCounts(data)) return nil;
    try {
        std::istringstream is(std::string((const char *)data.bytes, data.length));
        TopoDS_Shape shape;
        BRep_Builder builder;
        // Same hang/NaN guards as shapeFromSerialized:, but NO heal — a
        // capture replay must hand the op exactly what the failing op saw.
        OS3DDeadlineProgress *deadline =
            new OS3DDeadlineProgress(kOS3DKernelDeadlineSeconds);
        Handle(Message_ProgressIndicator) progress(deadline);
        BRepTools::Read(shape, is, builder, progress->Start());
        if (deadline->Fired() || shape.IsNull()) return nil;
        if (!OS3DFiniteBounds(shape)) return nil;
        OCCTShape *out = [OCCTShape new];
        out->_shape = shape;
        return out;
    } catch (...) {
        return nil;
    }
}

#if DEBUG
+ (void)debugSetBooleanUnmergedFallbackEnabled:(BOOL)enabled {
    gOS3DBooleanUnmergedFallback = enabled;
}

+ (nullable OCCTShape *)debugInvalidOpenBoxWithSize:(double)size {
    if (size <= 0) return nil;
    try {
        BRepPrimAPI_MakeBox box(size, size, size);
        BRep_Builder builder;
        TopoDS_Shell shell;
        builder.MakeShell(shell);
        bool dropped = false;
        for (TopExp_Explorer ex(box.Shape(), TopAbs_FACE); ex.More(); ex.Next()) {
            if (!dropped) { dropped = true; continue; }  // leave one face out
            builder.Add(shell, ex.Current());
        }
        TopoDS_Solid solid;
        builder.MakeSolid(solid);
        builder.Add(solid, shell);
        OCCTShape *out = [OCCTShape new];
        out->_shape = solid;
        return out;
    } catch (...) {
        return nil;
    }
}
#endif

+ (nullable NSData *)serializedShape:(OCCTShape *)shape {
    if (shape == nil) return nil;
    try {
        // No triangulation in the blob (the mesh is derived state, re-built
        // on load — persisting it bloated every save), and the format
        // version PINNED so stored documents don't silently change format
        // when the linked OCCT is upgraded (review R4-O5,
        // docs/FREECAD_PLAYBOOK.md P1).
        std::ostringstream os;
        BRepTools::Write(shape->_shape, os,
                         /*withTriangles*/ Standard_False,
                         /*withNormals*/ Standard_False,
                         TopTools_FormatVersion_VERSION_2);
        const std::string s = os.str();
        if (s.empty()) return nil;
        return [NSData dataWithBytes:s.data() length:s.size()];
    } catch (...) {
        return nil;
    }
}

+ (nullable OCCTShape *)shapeFromSerialized:(NSData *)data {
    if (data.length == 0) return nil;
    // See OS3DPlausibleSectionCounts: inflated declared counts hang OCCT's
    // reader in loops the deadline cannot interrupt.
    if (!OS3DPlausibleSectionCounts(data)) return nil;
    try {
        std::istringstream is(std::string((const char *)data.bytes, data.length));
        TopoDS_Shape shape;
        BRep_Builder builder;
        // A stored blob is a TRUST BOUNDARY (docs/FREECAD_PLAYBOOK.md H1):
        // fuzzing proved a few flipped bytes can parse into a shape that
        // hangs the mesher or quietly carries invalid topology into every
        // downstream op. Deadline the read, then gate on finite bounds and
        // validity (with one heal attempt). A refused blob degrades to the
        // persisted render mesh — the documented fallback — not a crash.
        OS3DDeadlineProgress *deadline =
            new OS3DDeadlineProgress(kOS3DKernelDeadlineSeconds);
        Handle(Message_ProgressIndicator) progress(deadline);
        BRepTools::Read(shape, is, builder, progress->Start());
        if (deadline->Fired() || shape.IsNull()) return nil;
        if (!OS3DFiniteBounds(shape)) return nil;
        const TopoDS_Shape valid = OS3DHealAndValidate(shape);
        if (valid.IsNull()) return nil;
        OCCTShape *out = [OCCTShape new];
        out->_shape = valid;
        return out;
    } catch (...) {
        return nil;
    }
}

+ (OCCTRenderMesh *)renderMeshFromShape:(OCCTShape *)shape
                       angularDeflection:(double)angularDeflection
                        linearDeflection:(double)linearDeflection {
    return TessellateShape(shape->_shape, linearDeflection, angularDeflection);
}

@end
