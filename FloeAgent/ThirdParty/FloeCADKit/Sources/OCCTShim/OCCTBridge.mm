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
#include <tuple>
#include <limits>
#include <algorithm>
#include <csignal>
#include <memory>
#include <OSD.hxx>
#include <Standard_ErrorHandler.hxx>
#include <Standard_Failure.hxx>
#include <limits>
#include <set>
#include <map>
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
#include <TColgp_Array1OfPnt2d.hxx>
#include <gp_Pnt2d.hxx>
#include <BRepAlgoAPI_Defeaturing.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <TopTools_ListOfShape.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_LocalOperation.hxx>
#include <STEPControl_Writer.hxx>
#include <STEPControl_Reader.hxx>
#include <IGESControl_Reader.hxx>
#include <IGESControl_Writer.hxx>
#include <IGESControl_Controller.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <ShapeUpgrade_ShapeDivideContinuity.hxx>
#include <ShapeBuild_ReShape.hxx>
#include <BRepTools_History.hxx>
#include <BRepOffsetAPI_DraftAngle.hxx>
#include <BRepOffsetAPI_MakeOffsetShape.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <IntCurvesFace_ShapeIntersector.hxx>
#include <BRepAdaptor_Curve2d.hxx>
#include <GeomAbs_CurveType.hxx>
#include <BRepAlgoAPI_Section.hxx>
#include <HLRBRep_Algo.hxx>
#include <HLRBRep_HLRToShape.hxx>
#include <HLRAlgo_Projector.hxx>
#include <HLRBRep_TypeOfResultingEdge.hxx>
#include <GCPnts_UniformDeflection.hxx>
#include <GCPnts_AbscissaPoint.hxx>
#include <gp_Pln.hxx>
#include <Geom_Surface.hxx>
#include <BRepBuilderAPI_Sewing.hxx>
#include <BRepBuilderAPI_FindPlane.hxx>
#include <ShapeFix_Shell.hxx>
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <Geom_BSplineSurface.hxx>
#include <BSplCLib.hxx>
#include <BRepTools_WireExplorer.hxx>
#include <TColgp_Array2OfPnt.hxx>
#include <TColStd_Array2OfReal.hxx>
#include <Geom_SurfaceOfLinearExtrusion.hxx>
#include <Geom_SurfaceOfRevolution.hxx>
#include <Geom_RectangularTrimmedSurface.hxx>
#include <Geom2d_Curve.hxx>
#include <Geom2d_OffsetCurve.hxx>
#include <Geom2d_TrimmedCurve.hxx>
#include <Geom2dAdaptor_Curve.hxx>
#include <Geom2dLProp_Curve2dTool.hxx>
#include <Geom2dAPI_ProjectPointOnCurve.hxx>
#include <GeomAPI.hxx>
#include <Geom2dAPI_InterCurveCurve.hxx>
#include <Geom_Line.hxx>
#include <Geom_Circle.hxx>
#include <Geom_Ellipse.hxx>
#include <GeomAPI_ProjectPointOnCurve.hxx>
#include <Geom_Curve.hxx>
#include <TopExp.hxx>
#include <TopTools_IndexedMapOfShape.hxx>

#include <Standard_Version.hxx>

#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeHalfSpace.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepOffsetAPI_MakePipe.hxx>
#include <BRepOffsetAPI_MakePipeShell.hxx>
#include <GeomAPI_IntCS.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepFill_TypeOfContact.hxx>
#include <TopTools_DataMapOfShapeShape.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <Geom2d_Line.hxx>
#include <Geom2d_BSplineCurve.hxx>
#include <Geom2d_BezierCurve.hxx>
#include <BRepLib.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
#include <BRepClass_FaceClassifier.hxx>
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
#include <Geom_BezierCurve.hxx>
#include <GeomConvert_BSplineCurveToBezierCurve.hxx>
#include <Standard_ConstructionError.hxx>
#include <cstring>
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
#include <Geom_OffsetCurve.hxx>
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
#include <mutex>
#include <condition_variable>
#include <thread>
#include <memory>
#include <map>
#include <array>
#include <BRepCheck_Result.hxx>
#include <BRepCheck_ListIteratorOfListOfStatus.hxx>
#include <BRepCheck_Status.hxx>
#include <BOPAlgo_ArgumentAnalyzer.hxx>
#include <BOPAlgo_CheckResult.hxx>
#include <BOPAlgo_ListOfCheckResult.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <BRepOffset_MakeOffset.hxx>
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

@interface OCCTPrimitiveShape () {
@public
    OCCTShape *_shape;
    NSData *_boxFaceIndices;
}
@end
@implementation OCCTPrimitiveShape
@synthesize shape = _shape;
@synthesize boxFaceIndices = _boxFaceIndices;
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
    // Signal dispositions are process-wide, while OCCT error handlers are
    // thread-local. Keep one installation until the LAST concurrent scope
    // exits; never hold this mutex while a kernel operation is running.
    inline static std::mutex ownershipMutex;
    inline static unsigned owners = 0;
    inline static struct sigaction saved[count]{};
    OS3DSignalScope() {
        std::lock_guard<std::mutex> lock(ownershipMutex);
        if (owners == 0) {
            for (int i = 0; i < count; i++) sigaction(signals[i], nullptr, &saved[i]);
            OSD::SetSignal(OSD_SignalMode_Set, Standard_False);
        }
        ++owners;
    }
    OS3DSignalScope(const OS3DSignalScope&) = delete;
    OS3DSignalScope& operator=(const OS3DSignalScope&) = delete;
    ~OS3DSignalScope() {
        {
            std::lock_guard<std::mutex> lock(ownershipMutex);
            if (--owners == 0) {
                for (int i = 0; i < count; i++) sigaction(signals[i], &saved[i], nullptr);
            }
        }
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

// IGES keeps solids and surfaces apart (see OCCTBridge.h): the reader's
// output is not "a solid" the way STEP's is, and calling a shell a solid
// would let it into booleans/blends it is not valid for.
@interface OCCTIGESImport () {
@public
    NSArray<OCCTShape *> *_solids;
    NSArray<OCCTShape *> *_surfaces;
    NSArray<NSNumber *> *_solidFaceCounts;
    NSArray<NSNumber *> *_surfaceFaceCounts;
    BOOL _readSucceeded;
    NSInteger _rootCount;
}
@end

@implementation OCCTIGESImport
- (NSArray<OCCTShape *> *)solids { return _solids; }
- (NSArray<OCCTShape *> *)surfaces { return _surfaces; }
- (NSArray<NSNumber *> *)solidFaceCounts { return _solidFaceCounts; }
- (NSArray<NSNumber *> *)surfaceFaceCounts { return _surfaceFaceCounts; }
- (BOOL)readSucceeded { return _readSucceeded; }
- (NSInteger)rootCount { return _rootCount; }
@end

@implementation OCCTRenderMesh
- (NSInteger)vertexCount { return _vertexCount; }
- (NSInteger)triangleCount { return _triangleCount; }
- (NSData *)positions { return _positions; }
- (NSData *)normals { return _normals; }
- (NSData *)indices { return _indices; }
- (NSData *)faceIndices { return _faceIndices; }
@end

// Pack the six NAMED construction faces of a box into the result's 1-based
// TopExp face numbering. `builder` is the transform that produced `shape`, or
// null when the placement was identity; when present, each named face is
// followed through the builder's OWN ModifiedShape() history so every index
// refers to the SAME result handle. Nil means "this provenance is incomplete"
// — callers must refuse name-based association instead of pairing ordinals.
static NSData *OS3DBoxFaceIndices(
    const TopoDS_Shape &shape,
    const BRepBuilderAPI_Transform *builder,
    const TopoDS_Face &xMin, const TopoDS_Face &xMax,
    const TopoDS_Face &yMin, const TopoDS_Face &yMax,
    const TopoDS_Face &zMin, const TopoDS_Face &zMax) {
    TopoDS_Face faces[6] = {xMin, xMax, yMin, yMax, zMin, zMax};
    if (builder != nullptr) {
        for (int i = 0; i < 6; ++i) {
            if (faces[i].IsNull()) return nil;
            const TopoDS_Shape mapped = builder->ModifiedShape(faces[i]);
            if (mapped.IsNull() || mapped.ShapeType() != TopAbs_FACE) return nil;
            faces[i] = TopoDS::Face(mapped);
        }
    }
    TopTools_IndexedMapOfShape faceMap;
    TopExp::MapShapes(shape, TopAbs_FACE, faceMap);
    int32_t packed[6];
    for (int i = 0; i < 6; ++i) {
        const Standard_Integer index = faceMap.FindIndex(faces[i]);
        if (index <= 0) return nil;
        packed[i] = (int32_t)index;
    }
    return [NSData dataWithBytes:packed length:sizeof(packed)];
}

@interface OCCTBridge (FloeThreadInternal)
+ (nullable OCCTShape *)sweptShapeWithOuterLoop:(NSData *)outerLoop
                                     outerConic:(nullable NSData *)outerConic
                                          holes:(NSArray<NSData *> *)holes
                                     holeConics:(nullable NSData *)holeConics
                                  outerSegments:(nullable NSData *)outerSegments
                                   holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                          basis:(OCCTPlaneBasis *)basis
                                          spine:(NSData *)spine
                                          helix:(nullable NSData *)helix
                                        history:(nullable OCCTShapeHistory *)history
                                   axialSection:(BOOL)axialSection ;
@end

@implementation OCCTBridge

+ (NSDictionary<NSString *, id> *)signalGuardOverlapDiagnostics {
    struct sigaction original[OS3DSignalScope::count], installed[OS3DSignalScope::count];
    for (int i = 0; i < OS3DSignalScope::count; ++i)
        sigaction(OS3DSignalScope::signals[i], nullptr, &original[i]);
    auto first = std::make_unique<OS3DSignalScope>();
    for (int i = 0; i < OS3DSignalScope::count; ++i)
        sigaction(OS3DSignalScope::signals[i], nullptr, &installed[i]);
    std::mutex mutex;
    std::condition_variable condition;
    bool entered = false, release = false;
    std::thread worker([&] {
        OS3DSignalScope second;
        std::unique_lock<std::mutex> lock(mutex);
        entered = true; condition.notify_one();
        condition.wait(lock, [&] { return release; });
    });
    {
        std::unique_lock<std::mutex> lock(mutex);
        condition.wait(lock, [&] { return entered; });
    }
    auto sameHandler = [](const struct sigaction& lhs, const struct sigaction& rhs) {
        if ((lhs.sa_flags & SA_SIGINFO) != (rhs.sa_flags & SA_SIGINFO)) return false;
        return (lhs.sa_flags & SA_SIGINFO) ? lhs.sa_sigaction == rhs.sa_sigaction : lhs.sa_handler == rhs.sa_handler;
    };
    first.reset();
    bool retained = true;
    for (int i = 0; i < OS3DSignalScope::count; ++i) {
        struct sigaction active;
        sigaction(OS3DSignalScope::signals[i], nullptr, &active);
        retained = retained && sameHandler(active, installed[i]);
    }
    { std::lock_guard<std::mutex> lock(mutex); release = true; }
    condition.notify_one(); worker.join();
    bool restored = true;
    for (int i = 0; i < OS3DSignalScope::count; ++i) {
        struct sigaction active;
        sigaction(OS3DSignalScope::signals[i], nullptr, &active);
        restored = restored && sameHandler(active, original[i]);
    }
    return @{ @"guardAfterFirstExit": @(retained), @"restoredAfterLastExit": @(restored) };
}


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

// Exact polynomial continuation of the existing fitted Bezier-chain basis.
// Geom_BSplineCurve::Segment in pinned OCCT7.8.1 calls InsertKnots, which
// refuses knots beyond its current domain. Do not refit/extrapolate samples.
static Handle(Geom_BSplineCurve) OS3DExactSplineDomain(
    const Handle(Geom_BSplineCurve)& basis, double requestedFirst, double requestedLast) {
    const double first = std::min(basis->FirstParameter(), requestedFirst);
    const double last = std::max(basis->LastParameter(), requestedLast);
    if (first == basis->FirstParameter() && last == basis->LastParameter()) return basis;
    if (basis->IsPeriodic() || basis->IsRational() || basis->Degree() != 3
        || !std::isfinite(first) || !std::isfinite(last) || last <= first) {
        throw Standard_ConstructionError("Unsupported exact spline continuation");
    }
    // Exact knot insertion, not approximation. The source materializer can
    // have removed some C1 join knots; recover their Bezier spans exactly.
    GeomConvert_BSplineCurveToBezierCurve split(basis);
    const int spans = split.NbArcs();
    if (spans < 1 || spans > 512) throw Standard_ConstructionError("Spline span limit");
    TColStd_Array1OfReal knots(1, spans + 1);
    split.Knots(knots);
    TColStd_Array1OfInteger multiplicities(1, spans + 1);
    TColgp_Array1OfPnt poles(1, 3 * spans + 1);
    for (int span = 1; span <= spans; ++span) {
        Handle(Geom_BezierCurve) arc = split.Arc(span);
        if (arc.IsNull() || arc->IsRational() || arc->Degree() != 3) {
            throw Standard_ConstructionError("Unsupported fitted spline span");
        }
        const double width = knots(span + 1) - knots(span);
        if (!(width > 0)) throw Standard_ConstructionError("Empty fitted spline span");
        const double a = span == 1 ? (first - knots(span)) / width : 0;
        const double b = span == spans ? (last - knots(span)) / width : 1;
        // Blossoming on [a,b] preserves the exact polynomial, including a<0
        // and b>1. Original parameter values and inner geometry are unchanged.
        for (int j = 0; j <= 3; ++j) {
            gp_XYZ work[4] = {arc->Pole(1).XYZ(), arc->Pole(2).XYZ(),
                              arc->Pole(3).XYZ(), arc->Pole(4).XYZ()};
            for (int level = 1; level <= 3; ++level) {
                const double t = level <= 3 - j ? a : b;
                for (int k = 0; k <= 3 - level; ++k) {
                    work[k] = work[k] * (1 - t) + work[k + 1] * t;
                }
            }
            if (!std::isfinite(work[0].X()) || !std::isfinite(work[0].Y())
                || !std::isfinite(work[0].Z())
                || std::max({std::abs(work[0].X()), std::abs(work[0].Y()),
                             std::abs(work[0].Z())}) > 1e12) {
                throw Standard_ConstructionError("Spline continuation is outside the supported range");
            }
            poles.SetValue(3 * (span - 1) + j + 1, gp_Pnt(work[0]));
        }
        multiplicities.SetValue(span, span == 1 ? 4 : 3);
    }
    multiplicities.SetValue(spans + 1, 4);
    knots.SetValue(1, first); knots.SetValue(spans + 1, last);
    Handle(Geom_BSplineCurve) result = new Geom_BSplineCurve(poles, knots, multiplicities, 3);
    if (basis->NbKnots() != spans + 1) {
        throw Standard_ConstructionError("Unexpected fitted spline knot layout");
    }
    // Restore only continuity the original basis actually possessed. Exact
    // knot removal is not a fit; refusal never publishes a reshaped curve.
    for (int k = spans; k >= 2; --k) {
        const int originalMultiplicity = basis->Multiplicity(k);
        if (originalMultiplicity < 3 && !result->RemoveKnot(k, originalMultiplicity, 1e-9)) {
            throw Standard_ConstructionError("Exact spline continuation could not preserve a join");
        }
    }
    return result;
}

/// Records are walked by KIND (see `packSegments`): line/arc and legacy spline
/// bytes are unchanged; kind 4 carries one exact versioned curve record.
// Versioned exact curve record shared with SketchCurveDefinition. Domain
// conversion happens here once; no interpolated/tessellated boundary is used.
static double OS3DDefinitionParameter(NSData *record, double value, bool toNative, int depth = 0);

static Handle(Geom_Curve) OS3DSketchCurveDefinition(
    NSData *record, bool extend, bool applyInterval = true,
    double extensionLower = 0.0, double extensionUpper = 1.0, int depth = 0) {
    if (depth > 32 || record.length % sizeof(double) != 0
        || record.length < 9 * sizeof(double) || record.length > 131072 * sizeof(double)) {
        return Handle(Geom_Curve)();
    }
    const double *v = (const double *)record.bytes;
    const NSUInteger n = record.length / sizeof(double);
    for (NSUInteger i = 0; i < n; ++i) {
        if (!std::isfinite(v[i]) || std::abs(v[i]) > 1e12) return Handle(Geom_Curve)();
    }
    if ((v[0] != 1 && v[0] != 2) || v[3] - v[2] <= 1e-9
        || v[4] < 0 || v[4] > 3 || v[4] != std::floor(v[4])) return Handle(Geom_Curve)();
    Handle(Geom_Curve) curve;
    double first = v[2], last = v[3];
    if (v[0] == 1 && v[1] == 0 && n == 9) {
        if (v[4] != 0) return Handle(Geom_Curve)();
        const gp_Pnt a(v[5], v[6], 0), b(v[7], v[8], 0);
        const double length = a.Distance(b);
        if (length <= 1e-8) return Handle(Geom_Curve)();
        curve = new Geom_Line(a, gp_Dir(gp_Vec(a, b)));
        if (extend || !applyInterval) return curve;
        first *= length; last *= length;
    } else if (v[0] == 1 && v[1] == 1 && n == 10) {
        const double rx = v[7], ry = v[8], rotation = v[9];
        if (v[4] > 1 || rx <= 1e-8 || ry <= 1e-8 || last - first > 2 * M_PI + 1e-8) {
            return Handle(Geom_Curve)();
        }
        const bool circle = rx == ry;
        const bool xMajor = rx >= ry;
        const double angle = rotation + (!circle && !xMajor ? M_PI_2 : 0);
        const gp_Ax2 axis(gp_Pnt(v[5], v[6], 0), gp_Dir(0,0,1),
                          gp_Dir(cos(angle),sin(angle),0));
        if (circle) curve = new Geom_Circle(axis, rx);
        else {
            curve = new Geom_Ellipse(axis, std::max(rx,ry), std::min(rx,ry));
            if (!xMajor) { first -= M_PI_2; last -= M_PI_2; }
        }
        if (extend || !applyInterval || v[4] == 1) return curve;
    } else if (v[0] == 1 && v[1] == 2 && n >= 12) {
        if (v[5] != std::floor(v[5]) || v[5] < 3 || v[5] > 256
            || n != 6 + (NSUInteger)v[5] * 2) return Handle(Geom_Curve)();
        TopoDS_Edge edge;
        if (!OS3DSplineEdge(v + 6, (NSUInteger)v[5], (((int)v[4]) & 2) != 0, 0, edge)) {
            return Handle(Geom_Curve)();
        }
        Standard_Real begin = 0, end = 0;
        curve = BRep_Tool::Curve(edge, begin, end);
        if (curve.IsNull()) return Handle(Geom_Curve)();
        Handle(Geom_BSplineCurve) bs = Handle(Geom_BSplineCurve)::DownCast(curve->Copy());
        if (bs.IsNull() || !(end > begin)) return Handle(Geom_Curve)();
        const bool closedBasis = (((int)v[4]) & 2) != 0;
        if (closedBasis) {
            // A closed fit spline has a unit periodic parameter even though the
            // legacy edge builder stored a clamped, closed (non-periodic) basis.
            // SetPeriodic changes only the knot/pole representation, never shape.
            if (!bs->IsClosed()) return Handle(Geom_Curve)();
            if (!bs->IsPeriodic()) bs->SetPeriodic();
        }
        auto mapped = [&](double u) { return begin + (end - begin) * u; };
        double wantedFirst = begin, wantedLast = end;
        if (applyInterval) {
            wantedFirst = std::min(wantedFirst, mapped(v[2]));
            wantedLast = std::max(wantedLast, mapped(v[3]));
        }
        if (extend || !applyInterval) {
            wantedFirst = std::min(wantedFirst, mapped(extensionLower));
            wantedLast = std::max(wantedLast, mapped(extensionUpper));
        }
        if (!std::isfinite(wantedFirst) || !std::isfinite(wantedLast)
            || wantedLast - wantedFirst <= 1e-12) return Handle(Geom_Curve)();
        // Continue the original endpoint polynomials. Pinned OCCT Segment
        // refuses external knots, so retain the basis through exact Bezier
        // domain conversion rather than fitting any new points.
        if (!closedBasis && (wantedFirst < begin || wantedLast > end)) {
            bs = OS3DExactSplineDomain(bs, wantedFirst, wantedLast);
        }
        if (extend || !applyInterval || ((((int)v[4]) & 1) != 0 && v[2] == 0 && v[3] == 1)) return bs;
        first = mapped(v[2]); last = mapped(v[3]);
        curve = bs;
    } else if (v[0] == 2 && v[1] == 3 && n >= 17) {
        const double basisCount = v[7];
        if (v[4] > 1 || (v[5] != 0 && v[5] != 1) || !std::isfinite(v[6])
            || std::abs(v[6]) <= 1e-8 || basisCount != std::floor(basisCount)
            || basisCount < 9 || n != 8 + (NSUInteger)basisCount) return Handle(Geom_Curve)();
        NSData *base = [NSData dataWithBytes:v + 8 length:(NSUInteger)basisCount * sizeof(double)];
        Handle(Geom_Curve) basis = OS3DSketchCurveDefinition(
            base, extend, false, extensionLower, extensionUpper, depth + 1);
        if (basis.IsNull()) return Handle(Geom_Curve)();
        // Geom2d_OffsetCurve uses T^Z (right of travel). The product's public
        // line/spline convention is left; outward_conic is right for CCW.
        const double nativeOffset = v[5] == 0 ? -v[6] : v[6];
        // OCCT 7.8 GeomAPI::To3d -> GeomAdaptor::MakeCurve rejects OtherCurve,
        // including an offset. Construct the equivalent exact 3D offset from
        // the same basis/parameter instead; no approximation or refit.
        curve = new Geom_OffsetCurve(basis, nativeOffset, gp_Dir(0,0,1));
        if (curve.IsNull() || extend || !applyInterval || v[4] == 1) return curve;
        first = OS3DDefinitionParameter(record, v[2], true, depth);
        last = OS3DDefinitionParameter(record, v[3], true, depth);
    } else return Handle(Geom_Curve)();
    if (curve.IsNull() || !std::isfinite(first) || !std::isfinite(last) || last <= first) {
        return Handle(Geom_Curve)();
    }
    return new Geom_TrimmedCurve(curve, first, last, Standard_True, Standard_False);
}

/// Convert between the persisted normalized parameter and OCCT's native domain.
/// Offset curves inherit their basis parameter, so v2 recurses without changing it.
static double OS3DDefinitionParameter(NSData *record, double value, bool toNative, int depth) {
    if (depth > 32 || record.length % sizeof(double) != 0
        || record.length < 9 * sizeof(double)) return std::numeric_limits<double>::quiet_NaN();
    const double *v = (const double *)record.bytes;
    const NSUInteger n = record.length / sizeof(double);
    if (v[0] == 1 && v[1] == 0 && n == 9) {
        const double length = gp_Pnt(v[5],v[6],0).Distance(gp_Pnt(v[7],v[8],0));
        return length > 1e-8 ? (toNative ? value * length : value / length)
                             : std::numeric_limits<double>::quiet_NaN();
    }
    if (v[0] == 1 && v[1] == 1 && n == 10) {
        const bool shift = v[7] != v[8] && v[7] < v[8];
        return shift ? (toNative ? value - M_PI_2 : value + M_PI_2) : value;
    }
    if (v[0] == 1 && v[1] == 2 && n >= 12) {
        if (v[5] != std::floor(v[5]) || v[5] < 3 || v[5] > 256
            || n != 6 + (NSUInteger)v[5] * 2) return std::numeric_limits<double>::quiet_NaN();
        TopoDS_Edge edge;
        if (!OS3DSplineEdge(v + 6, (NSUInteger)v[5], (((int)v[4]) & 2) != 0, 0, edge)) {
            return std::numeric_limits<double>::quiet_NaN();
        }
        Standard_Real first = 0, last = 0;
        Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, first, last);
        if (curve.IsNull() || !(last > first)) return std::numeric_limits<double>::quiet_NaN();
        return toNative ? first + (last - first) * value : (value - first) / (last - first);
    }
    if (v[0] == 2 && v[1] == 3 && n >= 17) {
        NSData *base = [NSData dataWithBytes:v + 8 length:(NSUInteger)v[7] * sizeof(double)];
        return OS3DDefinitionParameter(base, value, toNative, depth + 1);
    }
    return std::numeric_limits<double>::quiet_NaN();
}

static Handle(Geom2d_Curve) OS3DSketchCurve2d(
    NSData *record, bool extend, double extensionLower = 0.0,
    double extensionUpper = 1.0, bool applyInterval = true, int depth = 0) {
    if (depth > 32 || record.length % sizeof(double) != 0
        || record.length < 9 * sizeof(double)) return Handle(Geom2d_Curve)();
    const double *v = (const double *)record.bytes;
    const NSUInteger n = record.length / sizeof(double);
    if (n >= 17 && v[0] == 2 && v[1] == 3) {
        const double basisCount = v[7];
        if (basisCount != std::floor(basisCount) || basisCount < 9
            || n != 8 + (NSUInteger)basisCount || (v[5] != 0 && v[5] != 1)
            || !std::isfinite(v[6]) || std::abs(v[6]) <= 1e-8) return Handle(Geom2d_Curve)();
        // Keep every nested derived offset in 2D from construction through
        // diagnostics; no 3D round trip or approximation is involved.
        NSData *base = [NSData dataWithBytes:v + 8 length:(NSUInteger)basisCount * sizeof(double)];
        Handle(Geom2d_Curve) basis2d = OS3DSketchCurve2d(
            base, extend, extensionLower, extensionUpper, false, depth + 1);
        if (basis2d.IsNull()) return Handle(Geom2d_Curve)();
        const double nativeOffset = v[5] == 0 ? -v[6] : v[6];
        Handle(Geom2d_OffsetCurve) offset = new Geom2d_OffsetCurve(basis2d, nativeOffset);
        if (extend || !applyInterval || v[4] == 1) return offset;
        const double first = OS3DDefinitionParameter(record, v[2], true);
        const double last = OS3DDefinitionParameter(record, v[3], true);
        if (!std::isfinite(first) || !std::isfinite(last) || last <= first) return Handle(Geom2d_Curve)();
        return new Geom2d_TrimmedCurve(offset, first, last, Standard_True, Standard_False);
    }
    Handle(Geom_Curve) curve = OS3DSketchCurveDefinition(
        record, extend, applyInterval, extensionLower, extensionUpper, depth);
    if (curve.IsNull()) return Handle(Geom2d_Curve)();
    return GeomAPI::To2d(curve, gp_Pln(gp_Pnt(0,0,0), gp_Dir(0,0,1)));
}

static bool OS3DRecordHasSpline(NSData *record, int depth = 0) {
    if (depth > 32 || record.length < 6 * sizeof(double)
        || record.length % sizeof(double) != 0) return false;
    const double *v = (const double *)record.bytes;
    if (v[0] == 1 && v[1] == 2) return true;
    if (v[0] == 2 && v[1] == 3 && record.length >= 8 * sizeof(double) && v[7] >= 9) {
        NSData *base = [NSData dataWithBytes:v + 8 length:(NSUInteger)v[7] * sizeof(double)];
        return OS3DRecordHasSpline(base, depth + 1);
    }
    return false;
}

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
        } else if (kind < 3.5) {
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
        } else if (kind < 4.5) {
            // kind 4: exact SketchCurveDefinition record. Flags are bit0
            // reversed traversal, bit1 closed single-edge profile.
            if (i + 3 > total) return TopoDS_Wire();
            const double rawCount = p[i + 1], flags = p[i + 2];
            if (rawCount != std::floor(rawCount) || rawCount < 9
                || flags != std::floor(flags) || flags < 0 || flags > 3) return TopoDS_Wire();
            const NSUInteger count = (NSUInteger)rawCount;
            if (i + 3 + count > total) return TopoDS_Wire();
            NSData *record = [NSData dataWithBytes:p + i + 3 length:count * sizeof(double)];
            Handle(Geom_Curve) curve = OS3DSketchCurveDefinition(record, false);
            if (curve.IsNull()) return TopoDS_Wire();
            BRepBuilderAPI_MakeEdge me(curve);
            if (!me.IsDone()) return TopoDS_Wire();
            TopoDS_Edge edge = me.Edge();
            if ((((int)flags) & 1) != 0) edge.Reverse();
            mw.Add(edge);
            if ((((int)flags) & 2) != 0) closedSpline = true;
            i += 3 + count;
        } else if (kind == 5) {
            if (i + 10 > total || p[i + 1] != 4) return TopoDS_Wire();
            TColgp_Array1OfPnt poles(1, 4);
            for (Standard_Integer k = 0; k < 4; ++k) {
                const double x = p[i + 2 + 2*k], y = p[i + 3 + 2*k];
                if (!std::isfinite(x) || !std::isfinite(y)) return TopoDS_Wire();
                poles.SetValue(k + 1, gp_Pnt(x, y, z));
            }
            Handle(Geom_BezierCurve) curve = new Geom_BezierCurve(poles);
            BRepBuilderAPI_MakeEdge edge(curve);
            if (!edge.IsDone()) return TopoDS_Wire();
            mw.Add(edge.Edge()); i += 10;
        } else return TopoDS_Wire();
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
    return [self primitiveShapeWithBoxFaceIndicesOfKind:kind
                                                      a:a
                                                      b:b
                                                      c:c
                                              transform:transform].shape;
}

+ (nullable OCCTPrimitiveShape *)primitiveShapeWithBoxFaceIndicesOfKind:(NSInteger)kind
                                                                      a:(double)a
                                                                      b:(double)b
                                                                      c:(double)c
                                                              transform:(nullable NSData *)transform {
    try {
        TopoDS_Shape shape;
        // The named construction faces EXIST only for a box. They are fetched
        // from the maker itself, never derived from face order.
        bool isBox = (kind == 0);
        TopoDS_Face xMin, xMax, yMin, yMax, zMin, zMax;
        switch (kind) {
            case 0: {  // box: Euclid centers x/z and puts the base on y=0
                if (a <= 0 || b <= 0 || c <= 0) return nil;
                BRepPrimAPI_MakeBox maker(gp_Pnt(-a / 2.0, 0.0, -b / 2.0), a, c, b);
                maker.Build();
                shape = maker.Shape();
                // Pinned OCCT 7.8.1 BRepPrimAPI_MakeBox accessor semantics:
                // Bottom=ZMin, Back=XMin, Front=XMax, Left=YMin, Right=YMax,
                // Top=ZMax. The maker is built with dx=a, dy=c, dz=b, so the
                // local construction axes are X=width, Y=height, Z=depth.
                xMin = maker.BackFace();
                xMax = maker.FrontFace();
                yMin = maker.LeftFace();
                yMax = maker.RightFace();
                zMin = maker.BottomFace();
                zMax = maker.TopFace();
                break;
            }
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

        NSData *boxFaceIndices = [NSData data];
        if (transform != nil && transform.length >= 12 * sizeof(double)) {
            const double *m = (const double *)transform.bytes;  // row-major 3x4
            gp_Trsf t;
            t.SetValues(m[0], m[1], m[2],  m[3],
                        m[4], m[5], m[6],  m[7],
                        m[8], m[9], m[10], m[11]);
            BRepBuilderAPI_Transform builder(shape, t, Standard_True);
            const TopoDS_Shape placed = builder.Shape();
            if (isBox) {
                // Follow each named construction face through the builder's
                // OWN history. An empty mapping is reported honestly rather
                // than pairing the transformed shape by ordinal position.
                try {
                    NSData *mapped = OS3DBoxFaceIndices(
                        placed, &builder, xMin, xMax, yMin, yMax, zMin, zMax);
                    if (mapped != nil) boxFaceIndices = mapped;
                } catch (...) {
                    boxFaceIndices = [NSData data];
                }
            }
            shape = placed;
        } else if (isBox) {
            try {
                NSData *mapped = OS3DBoxFaceIndices(
                    shape, nullptr, xMin, xMax, yMin, yMax, zMin, zMax);
                if (mapped != nil) boxFaceIndices = mapped;
            } catch (...) {
                boxFaceIndices = [NSData data];
            }
        }

        OCCTShape *handle = [OCCTShape new];
        handle->_shape = shape;
        OCCTPrimitiveShape *out = [OCCTPrimitiveShape new];
        out->_shape = handle;
        out->_boxFaceIndices = boxFaceIndices;
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
    OS3DSignalScope signalScope;
    try {
        OCC_CATCH_SIGNALS
        Handle(OS3DDeadlineProgress) deadline=new OS3DDeadlineProgress(kOS3DOpDeadlineSeconds);
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
            if (deadline->Fired()) return nil;
        }
        mk.Build(deadline->Start());
        if (deadline->Fired() || !mk.IsDone()) return nil;
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
    return [self sweptShapeWithOuterLoop:outerLoop outerConic:outerConic
        holes:holes holeConics:holeConics outerSegments:outerSegments holeSegments:holeSegments
        basis:basis spine:spine helix:helix history:history axialSection:NO];
}

+ (nullable OCCTShape *)threadSweepWithOuterLoop:(NSData *)outerLoop
                                       segments:(nullable NSData *)segments
                                          basis:(OCCTPlaneBasis *)basis
                                          helix:(NSData *)helix {
    // Exact helix supplies the actual start point/tangent; these two finite
    // points only satisfy the shared legacy transport's bounded spine count.
    const double seed[6] = {0, 0, 0, 0, 1, 0};
    NSData *spine = [NSData dataWithBytes:seed length:sizeof(seed)];
    return [self sweptShapeWithOuterLoop:outerLoop outerConic:nil holes:@[] holeConics:nil
        outerSegments:segments holeSegments:nil basis:basis spine:spine helix:helix
        history:nil axialSection:YES];
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
                                        history:(nullable OCCTShapeHistory *)history
                                   axialSection:(BOOL)axialSection {
    const NSUInteger points = spine.length / (3 * sizeof(double));
    if (points < 2) return nil;
    const double *s = (const double *)spine.bytes;
    const bool exactHelix = (helix != nil && helix.length >= 13 * sizeof(double));
    if (axialSection && !exactHelix) return nil;
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
        // M13 basic profiles are defined in the AXIAL plane. Rotating this
        // section normal to the spine would change their specified flank
        // angle and axial crest/root widths. Ordinary sweeps keep correction.
        if (!axialSection) {
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
        if (axialSection) mk.SetTolerance(1e-7, 1e-7, 1e-6);
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

// Preserve the exact selected face; rebuilding a polygon outline here would
// facet circular holes and turn an apparently successful pull into data loss.
+ (nullable OCCTShape *)pushedPlanarFaceOfShape:(OCCTShape *)shape
                                      atPointX:(double)x y:(double)y z:(double)z
                                      normalX:(double)nx normalY:(double)ny normalZ:(double)nz
                                      distance:(double)distance
                                     tolerance:(double)tolerance
                                        status:(nullable OCCTOpStatus *)status {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"invalid planar push/pull");
    if (shape == nil || !std::isfinite(distance) || fabs(distance) < 1e-9) return nil;
    try {
        TopTools_IndexedMapOfShape faces;
        TopExp::MapShapes(shape->_shape, TopAbs_FACE, faces);
        const double point[] = {x, y, z};
        const auto chosen = OS3DNearestFaces(faces, point, 1, tolerance);
        if (chosen.size() != 1) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched, @"no exact planar face at the pick");
            return nil;
        }
        const TopoDS_Face face = TopoDS::Face(faces(*chosen.begin()));
        BRepAdaptor_Surface surface(face);
        if (surface.GetType() != GeomAbs_Plane) return nil;
        gp_Dir normal = surface.Plane().Axis().Direction();
        if (face.Orientation() == TopAbs_REVERSED) normal.Reverse();
        const gp_Dir requested(nx, ny, nz);
        if (normal.Dot(requested) < 1.0 - 1e-6) return nil;
        // A private copy keeps snapshots/undo handles immutable, including
        // topology touched by OCCT's prism builder.
        const TopoDS_Face copied = TopoDS::Face(BRepBuilderAPI_Copy(face, Standard_True, Standard_False).Shape());
        BRepPrimAPI_MakePrism prism(copied, gp_Vec(normal) * distance, Standard_True);
        OS3D_GUARDED(status, "planar push/pull", prism.Build());
        if (!prism.IsDone() || prism.Shape().IsNull()) return nil;
        if (prism.Shape().ShapeType() != TopAbs_SOLID) return nil;
        TopoDS_Solid solid = TopoDS::Solid(prism.Shape());
        if (!BRepLib::OrientClosedSolid(solid)) return nil;
        OCCTShape *tool = [OCCTShape new];
        tool->_shape = solid;
        return [self booleanOfShape:shape withShape:tool op:(distance > 0 ? 0 : 1) status:status];
    } catch (Standard_Failure &e) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, [NSString stringWithUTF8String:e.GetMessageString()]);
        return nil;
    } catch (...) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"kernel exception");
        return nil;
    }
}

+ (nullable OCCTShape *)radiallyOffsetFaceOfShape:(OCCTShape *)shape
                                           index:(NSInteger)index
                                        distance:(double)distance
                                       tolerance:(double)tolerance
                                          status:(nullable OCCTOpStatus *)status
                                         history:(nullable OCCTShapeHistory *)history {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"invalid cylindrical offset");
    if (shape == nil || !std::isfinite(distance) || fabs(distance) < 1e-9
        || !std::isfinite(tolerance) || tolerance <= 0) return nil;
    try {
        if (!OS3DFiniteBounds(shape->_shape) || !BRepCheck_Analyzer(shape->_shape).IsValid()) return nil;
        TopTools_IndexedMapOfShape inputs;
        TopExp::MapShapes(shape->_shape, TopAbs_FACE, inputs);
        if (index < 1 || index > inputs.Extent()) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched, @"the selected kernel face no longer exists");
            return nil;
        }
        const TopoDS_Face selected = TopoDS::Face(inputs((Standard_Integer)index));
        BRepAdaptor_Surface surface(selected);
        if (surface.GetType() != GeomAbs_Cylinder) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched, @"the selected face is not cylindrical");
            return nil;
        }
        const gp_Cylinder cylinder = surface.Cylinder();
        const double radius = cylinder.Radius() + distance;
        if (!std::isfinite(radius) || radius <= std::max(1e-7, tolerance)) return nil;

        BRepBuilderAPI_Copy copy(shape->_shape, Standard_True, Standard_False);
        const TopoDS_Shape copied = copy.Shape();
        const TopoDS_Face face = TopoDS::Face(copy.ModifiedShape(selected));
        BRepOffset_MakeOffset offset;
        offset.Initialize(copied, 0.0, tolerance, BRepOffset_Skin,
            Standard_True, Standard_False, GeomAbs_Intersection, Standard_False, Standard_True);
        // An inner cylindrical face has the opposite solid orientation. The
        // product's value is radial, while OCCT's is along the solid normal.
        const double normalOffset = selected.Orientation() == TopAbs_REVERSED ? -distance : distance;
        offset.SetOffsetOnFace(face, normalOffset);
        OS3D_GUARDED(status, "cylindrical face offset", offset.MakeOffsetShape());
        if (!offset.IsDone() || offset.Shape().IsNull()) return nil;
        int solidCount = 0;
        TopoDS_Shape result = OS3DExtractSingleSolid(offset.Shape(), solidCount);
        if (solidCount != 1 || result.IsNull() || !OS3DFiniteBounds(result)
            || !BRepCheck_Analyzer(result).IsValid()) {
            OS3DSetStatus(status, OCCTOpCodeInvalidResult, @"the offset did not retain one valid closed solid");
            return nil;
        }
        // Verify the actual analytic result, independently of the request or
        // render buffers. Never accept a sign inversion or a vanished bore.
        TopTools_IndexedMapOfShape finalFaces;
        TopExp::MapShapes(result, TopAbs_FACE, finalFaces);
        std::set<Standard_Integer> matching;
        // Offset surfaces are reported as Generated by this OCCT API, while
        // trimmed neighbors can be Modified. Both are actual ancestry, not a
        // geometric search over unrelated result faces. Deduplicate images.
        for (int relation : {1, 2}) {
        const auto &images = relation == 1 ? offset.Modified(face) : offset.Generated(face);
        for (TopTools_ListIteratorOfListOfShape it(images); it.More(); it.Next()) {
            if (it.Value().ShapeType() != TopAbs_FACE || !finalFaces.Contains(it.Value())) continue;
            BRepAdaptor_Surface actual(TopoDS::Face(it.Value()));
            if (actual.GetType() != GeomAbs_Cylinder) continue;
            const auto value = actual.Cylinder();
            if (fabs(value.Radius() - radius) <= std::max(tolerance * 10, 1e-6)
                && fabs(value.Axis().Direction().Dot(cylinder.Axis().Direction())) > 1.0 - 1e-9
                && gp_Vec(cylinder.Location(), value.Location()).Crossed(gp_Vec(cylinder.Axis().Direction())).Magnitude()
                    <= std::max(tolerance * 10, 1e-6)) matching.insert(finalFaces.FindIndex(it.Value()));
        }
        }
        if (matching.size() != 1) {
            OS3DSetStatus(status, OCCTOpCodeInvalidResult, @"the selected cylinder did not retain the requested radius");
            return nil;
        }
        GProp_GProps before, after;
        BRepGProp::VolumeProperties(shape->_shape, before);
        BRepGProp::VolumeProperties(result, after);
        const double a = fabs(before.Mass()), b = fabs(after.Mass());
        const double volumeSign = selected.Orientation() == TopAbs_REVERSED ? -distance : distance;
        if (!(a > 0 && b > 0 && std::isfinite(a) && std::isfinite(b))
            || (b - a) * volumeSign <= 0) {
            OS3DSetStatus(status, OCCTOpCodeInvalidResult, @"the radial offset changed volume in the wrong direction");
            return nil;
        }
        if (history != nil) {
            std::vector<OS3DHistEdge> edges;
            for (Standard_Integer i = 1; i <= inputs.Extent(); ++i) {
                const TopoDS_Shape item = copy.ModifiedShape(inputs(i));
                if (finalFaces.Contains(item)) edges.push_back({item, 0, 0, (int32_t)i, 0});
                for (int32_t relation : {1, 2}) {
                    const auto &list = relation == 1 ? offset.Modified(item) : offset.Generated(item);
                    for (TopTools_ListIteratorOfListOfShape it(list); it.More(); it.Next())
                        edges.push_back({it.Value(), 0, 0, (int32_t)i, relation});
                }
            }
            OS3DFillHistory(history, edges, {shape->_shape}, Handle(BRepTools_History)(), result, NO);
        }
        OCCTShape *out = [OCCTShape new]; out->_shape = result;
        OS3DSetStatus(status, OCCTOpCodeOK, @"ok");
        return out;
    } catch (Standard_Failure &e) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, [NSString stringWithUTF8String:e.GetMessageString()]);
    } catch (...) { OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"kernel exception"); }
    return nil;
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

+ (nullable NSData *)sketchCurveIntersectionsForTarget:(NSData *)target
                                            boundary:(NSData *)boundary
                                  extensionDirection:(NSInteger)extensionDirection
                                           tolerance:(double)tolerance
                                              status:(nullable OCCTOpStatus *)status {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"invalid exact curve record");
    if (!std::isfinite(tolerance) || tolerance < 1e-10 || tolerance > 1e-4
        || extensionDirection < -1 || extensionDirection > 1
        || target.length < 4 * sizeof(double)) return nil;
    OS3DSignalScope signalScope;
    try {
        OCC_CATCH_SIGNALS
        Handle(Geom2d_Curve) bb = OS3DSketchCurve2d(boundary, false);
        if (bb.IsNull()) return nil;
        const double *header = (const double *)target.bytes;
        const double originalLower = header[2], originalUpper = header[3];
        const bool expanding = extensionDirection != 0 && OS3DRecordHasSpline(target);
        NSMutableData *latest = [NSMutableData data];
        double extension = 1.0;
        // Once the requested side has an intersection, a wider exact domain can
        // only add farther intersections. Twenty doublings avoid an unbounded
        // extrapolation/search on corrupt or unrelated geometry.
        for (int iteration = 0; iteration < (expanding ? 21 : 1); ++iteration) {
            const double lower = extensionDirection < 0 ? originalLower - extension : originalLower;
            const double upper = extensionDirection > 0 ? originalUpper + extension : originalUpper;
            Handle(Geom2d_Curve) aa = OS3DSketchCurve2d(
                target, extensionDirection != 0, lower, upper);
            if (aa.IsNull()) return nil;
            Geom2dAPI_InterCurveCurve intersection(aa, bb, tolerance);
            if (intersection.NbSegments() != 0 || intersection.NbPoints() > 1024) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                              @"overlapping or excessive curve intersections");
                return nil;
            }
            latest = [NSMutableData dataWithCapacity:intersection.NbPoints() * 3 * sizeof(double)];
            bool foundRequestedExtension = false;
            for (Standard_Integer i = 1; i <= intersection.NbPoints(); ++i) {
                // Use the parameter belonging to this intersection, not a
                // second closest-point solve that can choose another branch.
                const auto &hit = intersection.Intersector().Point(i);
                const gp_Pnt2d point = hit.Value();
                const double parameter = OS3DDefinitionParameter(
                    target, hit.ParamOnFirst(), false);
                const double row[3] = { point.X(), point.Y(), parameter };
                if (!std::isfinite(row[0]) || !std::isfinite(row[1]) || !std::isfinite(row[2])) {
                    return nil;
                }
                [latest appendBytes:row length:sizeof(row)];
                if ((extensionDirection < 0 && parameter < originalLower - tolerance)
                    || (extensionDirection > 0 && parameter > originalUpper + tolerance)) {
                    foundRequestedExtension = true;
                }
            }
            if (extensionDirection == 0 || foundRequestedExtension || !expanding) break;
            extension *= 2.0;
        }
        OS3DSetStatus(status, OCCTOpCodeOK, @"exact planar intersections with target parameters");
        return latest;
    } catch (Standard_Failure &failure) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                      OS3DCrashMessage("Sketch curve intersection", failure.GetMessageString()));
    } catch (...) { OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"curve intersection exception"); }
    return nil;
}

+ (nullable NSData *)sketchCurvePointsForDefinition:(NSData *)definition
                                         parameters:(NSData *)parameters
                                          tolerance:(double)tolerance
                                             status:(nullable OCCTOpStatus *)status {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"invalid exact curve evaluation");
    const NSUInteger count = parameters.length / sizeof(double);
    if (parameters.length != count * sizeof(double) || count == 0 || count > 4096
        || !std::isfinite(tolerance) || tolerance <= 0) return nil;
    OS3DSignalScope signalScope;
    try {
        OCC_CATCH_SIGNALS
        Handle(Geom2d_Curve) curve = OS3DSketchCurve2d(definition, false);
        if (curve.IsNull()) return nil;
        const double *v = (const double *)definition.bytes;
        const double *u = (const double *)parameters.bytes;
        NSMutableData *out = [NSMutableData dataWithCapacity:count * 2 * sizeof(double)];
        for (NSUInteger i = 0; i < count; ++i) {
            if (!std::isfinite(u[i]) || u[i] < v[2] - tolerance || u[i] > v[3] + tolerance) return nil;
            const double native = OS3DDefinitionParameter(definition, u[i], true);
            if (!std::isfinite(native)) return nil;
            const gp_Pnt2d point = curve->Value(native);
            const double xy[2] = { point.X(), point.Y() };
            if (!std::isfinite(xy[0]) || !std::isfinite(xy[1])
                || std::abs(xy[0]) > 1e12 || std::abs(xy[1]) > 1e12) return nil;
            [out appendBytes:xy length:sizeof(xy)];
        }
        OS3DSetStatus(status, OCCTOpCodeOK, @"exact curve evaluation");
        return out;
    } catch (Standard_Failure &failure) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                      OS3DCrashMessage("Sketch curve evaluation", failure.GetMessageString()));
    } catch (...) { OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"curve evaluation exception"); }
    return nil;
}

+ (nullable NSNumber *)sketchCurveParameterForPoint:(NSData *)point
                                         definition:(NSData *)definition
                                           extended:(BOOL)extended
                                          tolerance:(double)tolerance
                                             status:(nullable OCCTOpStatus *)status {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"invalid exact curve projection");
    if (point.length != 2 * sizeof(double) || definition.length < 4 * sizeof(double)
        || !std::isfinite(tolerance) || tolerance <= 0) return nil;
    OS3DSignalScope signalScope;
    try {
        OCC_CATCH_SIGNALS
        const double *xy = (const double *)point.bytes;
        if (!std::isfinite(xy[0]) || !std::isfinite(xy[1])) return nil;
        const gp_Pnt2d target(xy[0], xy[1]);
        const double *header = (const double *)definition.bytes;
        double bestParameter = 0, bestDistance = std::numeric_limits<double>::infinity();
        double extension = 0.0;
        const int iterations = extended && OS3DRecordHasSpline(definition) ? 21 : 1;
        for (int iteration = 0; iteration < iterations; ++iteration) {
            const double lower = extended ? std::min(header[2], 0.0) - extension : header[2];
            const double upper = extended ? std::max(header[3], 1.0) + extension : header[3];
            Handle(Geom2d_Curve) curve = OS3DSketchCurve2d(definition, extended, lower, upper);
            if (curve.IsNull()) return nil;
            Geom2dAPI_ProjectPointOnCurve projection(target, curve);
            if (projection.NbPoints() > 0) {
                const double distance = projection.LowerDistance();
                if (distance < bestDistance) {
                    bestDistance = distance;
                    bestParameter = OS3DDefinitionParameter(
                        definition, projection.LowerDistanceParameter(), false);
                }
            }
            if (bestDistance <= tolerance * 10) break;
            extension = iteration == 0 ? 1.0 : extension * 2.0;
        }
        // A cursor pick, or a point whose nearest parameter is requested for
        // measurement, need not lie on the curve. The exact intersection path
        // checks its own residual; projection returns the closest finite point.
        if (!std::isfinite(bestParameter) || !std::isfinite(bestDistance)) return nil;
        OS3DSetStatus(status, OCCTOpCodeOK, @"exact curve projection");
        return [NSNumber numberWithDouble:bestParameter];
    } catch (Standard_Failure &failure) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                      OS3DCrashMessage("Sketch curve projection", failure.GetMessageString()));
    } catch (...) { OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"curve projection exception"); }
    return nil;
}

+ (nullable NSData *)validateSketchNormalOffset:(NSData *)definition
                                      tolerance:(double)tolerance
                                         status:(nullable OCCTOpStatus *)status {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"invalid exact normal offset");
    if (definition.length < 17 * sizeof(double) || !std::isfinite(tolerance)
        || tolerance < 1e-10 || tolerance > 1e-4) return nil;
    OS3DSignalScope signalScope;
    try {
        OCC_CATCH_SIGNALS
        Handle(Geom2d_Curve) top = OS3DSketchCurve2d(definition, false);
        Handle(Geom2d_TrimmedCurve) trimmed = Handle(Geom2d_TrimmedCurve)::DownCast(top);
        if (!trimmed.IsNull()) top = trimmed->BasisCurve();
        Handle(Geom2d_OffsetCurve) offset = Handle(Geom2d_OffsetCurve)::DownCast(top);
        if (offset.IsNull()) return nil;
        Handle(Geom2d_Curve) basis = offset->BasisCurve();
        const double first = OS3DDefinitionParameter(
            definition, ((const double *)definition.bytes)[2], true);
        const double last = OS3DDefinitionParameter(
            definition, ((const double *)definition.bytes)[3], true);
        if (!std::isfinite(first) || !std::isfinite(last) || last <= first) return nil;
        Geom2dAdaptor_Curve adaptor(offset, first, last);
        const double length = GCPnts_AbscissaPoint::Length(adaptor, first, last, tolerance);
        if (!std::isfinite(length)) return nil;
        if (length <= tolerance) {
            OS3DSetStatus(status, OCCTOpCodeCurveOffsetCollapse, @"the exact offset has zero length");
            return nil;
        }
        const double signedOffset = offset->Offset();
        double maximumNormalError = 0.0, maximumTangentResidual = 0.0;
        double previousFactor = 0.0;
        bool hasPreviousFactor = false, cusp = false;
        const int samples = 1024;
        for (int i = 0; i <= samples; ++i) {
            const double u = first + (last - first) * (double)i / samples;
            gp_Pnt2d basePoint, offsetPoint;
            gp_Vec2d tangent, second;
            // D1 is also an explicit tangent-singularity check at every sample.
            Geom2dLProp_Curve2dTool::D1(basis, u, basePoint, tangent);
            offset->D0(u, offsetPoint);
            const double speed2 = tangent.SquareMagnitude();
            if (!(speed2 > 1e-24) || !std::isfinite(speed2)) {
                cusp = true; break;
            }
            const gp_Vec2d delta(basePoint, offsetPoint);
            const double distance = delta.Magnitude();
            if (!std::isfinite(distance)) return nil;
            maximumNormalError = std::max(maximumNormalError,
                                          std::abs(distance - std::abs(signedOffset)));
            maximumTangentResidual = std::max(maximumTangentResidual,
                                              std::abs(delta.Dot(tangent)) / std::sqrt(speed2));
            try {
                Geom2dLProp_Curve2dTool::D2(basis, u, basePoint, tangent, second);
                const double curvature = (tangent.X() * second.Y() - tangent.Y() * second.X())
                    / (speed2 * std::sqrt(speed2));
                // Right-normal offset: O'=(1 + offset*k)C'. Its zero/sign
                // reversal is a cusp, not a valid smooth offset segment.
                const double factor = 1.0 + signedOffset * curvature;
                if (std::abs(factor) <= 1e-10
                    || (hasPreviousFactor && ((previousFactor < 0 && factor > 0)
                                              || (previousFactor > 0 && factor < 0)))) {
                    cusp = true; break;
                }
                if (std::isfinite(factor) && std::abs(factor) > 1e-12) {
                    previousFactor = factor; hasPreviousFactor = true;
                }
            } catch (...) {
                // A C1 (not C2) spline knot has no curvature there. D1 and the
                // neighbouring curvature signs remain valid; do not invent one.
            }
        }
        const double allowed = std::max(tolerance * 100, 1e-6);
        if (maximumNormalError > allowed || maximumTangentResidual > allowed) {
            OS3DSetStatus(status, OCCTOpCodeInvalidResult,
                          @"the native offset failed its normal-distance verification");
            return nil;
        }
        if (cusp) {
            OS3DSetStatus(status, OCCTOpCodeCurveOffsetCusp,
                          @"the exact offset derivative vanishes or reverses");
            return nil;
        }
        // Ask OCCT's exact edge argument analyzer first, covering a loop wholly
        // inside one of the diagnostic ranges as well as cross-range contact.
        Handle(Geom_Curve) exact3d = OS3DSketchCurveDefinition(definition, false);
        if (exact3d.IsNull()) return nil;
        BRepBuilderAPI_MakeEdge edgeBuilder(exact3d, first, last);
        if (!edgeBuilder.IsDone()) return nil;
        BOPAlgo_ArgumentAnalyzer argumentAnalyzer;
        argumentAnalyzer.SetShape1(edgeBuilder.Edge());
        argumentAnalyzer.SelfInterMode() = Standard_True;
        argumentAnalyzer.StopOnFirstFaulty() = Standard_True;
        argumentAnalyzer.Perform();
        if (argumentAnalyzer.HasFaulty()) {
            OS3DSetStatus(status, OCCTOpCodeCurveOffsetSelfIntersection,
                          @"OCCT reports exact offset edge self-interference");
            return nil;
        }
        // Exact non-adjacent pieces are intersected directly. Sampling is not
        // used to decide self-intersection; overlaps are refused as well.
        const int pieces = 16;
        std::vector<Handle(Geom2d_Curve)> ranges;
        ranges.reserve(pieces);
        for (int i = 0; i < pieces; ++i) {
            const double a = first + (last - first) * (double)i / pieces;
            const double b = first + (last - first) * (double)(i + 1) / pieces;
            ranges.push_back(new Geom2d_TrimmedCurve(offset, a, b, Standard_True, Standard_False));
        }
        const bool periodic = ((((const double *)definition.bytes)[4]) != 0);
        for (int i = 0; i < pieces; ++i) {
            for (int j = i + 2; j < pieces; ++j) {
                if (periodic && i == 0 && j == pieces - 1) continue;
                Geom2dAPI_InterCurveCurve intersection(ranges[i], ranges[j], tolerance);
                if (intersection.NbPoints() > 0 || intersection.NbSegments() > 0) {
                    OS3DSetStatus(status, OCCTOpCodeCurveOffsetSelfIntersection,
                                  @"non-adjacent exact offset ranges intersect");
                    return nil;
                }
            }
        }
        const double diagnostics[3] = { length, maximumNormalError, maximumTangentResidual };
        OS3DSetStatus(status, OCCTOpCodeOK, @"validated exact normal offset");
        return [NSData dataWithBytes:diagnostics length:sizeof(diagnostics)];
    } catch (Standard_Failure &failure) {
        const char *reason = failure.GetMessageString();
        const bool undefinedNormal = reason && std::strstr(reason, "Offset on C0 curve");
        OS3DSetStatus(status, undefinedNormal ? OCCTOpCodeCurveOffsetCusp : OCCTOpCodeKernelRefused,
                      OS3DCrashMessage("Sketch normal offset", reason));
    } catch (...) { OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"normal offset exception"); }
    return nil;
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

// Strict operand admission shared by advanced dress-up operations. Unlike a
// picker filter, this may not discard even one explicitly requested edge.
static bool OS3DAdvancedBlendOperands(OCCTShape *shape, NSData *packed,
                                      TopTools_IndexedMapOfShape &edgeMap,
                                      std::set<Standard_Integer> &chosen,
                                      OCCTOpStatus *status) {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"invalid blend operands");
    if (shape == nil || packed.length == 0 || packed.length % sizeof(int32_t) != 0)
        return false;
    if (!OS3DFiniteBounds(shape->_shape)) return false;
    TopExp::MapShapes(shape->_shape, TopAbs_EDGE, edgeMap);
    const int32_t *indices = (const int32_t *)packed.bytes;
    const NSUInteger count = packed.length / sizeof(int32_t);
    for (NSUInteger i = 0; i < count; ++i) {
        if (indices[i] < 1 || indices[i] > edgeMap.Extent()) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched, @"an edge identity is missing");
            return false;
        }
        chosen.insert(indices[i]);
    }
    NSString *reason = nil;
    const auto qualified = OS3DBlendableEdges(shape->_shape, edgeMap, chosen, &reason);
    if (qualified != chosen) {
        OS3DSetStatus(status, OCCTOpCodeNoTargetMatched,
                      reason ?: @"at least one requested edge cannot be blended");
        if (status != nil) {
            status.requestedCount = (NSInteger)chosen.size();
            status.failedCount = (NSInteger)(chosen.size() - qualified.size());
        }
        return false;
    }
    return true;
}

+ (nullable OCCTShape *)advancedChamferedShape:(OCCTShape *)shape
                                  edgeIndices:(NSData *)edgeIndices
                         referenceFaceIndices:(NSData *)referenceFaceIndices
                                firstDistance:(double)firstDistance
                                 secondAmount:(double)secondAmount
                                distanceAngle:(BOOL)distanceAngle
                                       status:(nullable OCCTOpStatus *)status
                                      history:(nullable OCCTShapeHistory *)history {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"invalid chamfer dimensions");
    if (!std::isfinite(firstDistance) || !std::isfinite(secondAmount) ||
        firstDistance <= 0 || secondAmount <= 0 ||
        (distanceAngle && secondAmount >= M_PI_2)) return nil;
    try {
        TopTools_IndexedMapOfShape edgeMap, faceMap;
        std::set<Standard_Integer> chosen;
        if (!OS3DAdvancedBlendOperands(shape, edgeIndices, edgeMap, chosen, status)) return nil;
        if (referenceFaceIndices.length != edgeIndices.length) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched, @"each edge needs one support face");
            return nil;
        }
        TopExp::MapShapes(shape->_shape, TopAbs_FACE, faceMap);
        TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
        TopExp::MapShapesAndAncestors(shape->_shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
        const int32_t *edges = (const int32_t *)edgeIndices.bytes;
        const int32_t *faces = (const int32_t *)referenceFaceIndices.bytes;
        std::map<Standard_Integer, Standard_Integer> supports;
        for (NSUInteger i = 0; i < edgeIndices.length / sizeof(int32_t); ++i) {
            if (faces[i] < 1 || faces[i] > faceMap.Extent()) {
                OS3DSetStatus(status, OCCTOpCodeNoTargetMatched, @"a support face identity is missing");
                return nil;
            }
            const auto &adjacent = edgeFaces.FindFromKey(edgeMap(edges[i]));
            bool found = false;
            for (TopTools_ListIteratorOfListOfShape it(adjacent); it.More(); it.Next()) {
                if (it.Value().IsSame(faceMap(faces[i]))) found = true;
            }
            auto existing = supports.find(edges[i]);
            if (!found || (existing != supports.end() && existing->second != faces[i])) {
                OS3DSetStatus(status, OCCTOpCodeNoTargetMatched,
                              @"a support face is foreign, ambiguous or not adjacent to its edge");
                return nil;
            }
            supports[edges[i]] = faces[i];
        }
        BRepFilletAPI_MakeChamfer mk(shape->_shape);
        for (const auto &operand : supports) {
            const auto edge = TopoDS::Edge(edgeMap(operand.first));
            const auto face = TopoDS::Face(faceMap(operand.second));
            if (distanceAngle) mk.AddDA(firstDistance, secondAmount, edge, face);
            else mk.Add(firstDistance, secondAmount, edge, face);
        }
        // Distinct explicit rows on one propagated contour may disagree about
        // its reference side. Refuse rather than let the last Add silently win.
        std::set<Standard_Integer> contours;
        for (const auto &operand : supports) {
            const auto contour = mk.Contour(TopoDS::Edge(edgeMap(operand.first)));
            if (contour == 0 || !contours.insert(contour).second) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                              @"select one seed per tangent chamfer contour");
                return nil;
            }
        }
        OS3DDeadlineProgress *deadline = new OS3DDeadlineProgress(kOS3DOpDeadlineSeconds);
        Handle(Message_ProgressIndicator) progress(deadline);
        OS3D_GUARDED(status, "advancedChamfer", mk.Build(progress->Start()));
        if (deadline->Fired()) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"the operation exceeded the kernel deadline");
            return nil;
        }
        OCCTShape *out = OS3DFinishBlend(mk, edgeMap, chosen, -1, status);
        if (out != nil) OS3DFillModifierHistory(history, mk, shape->_shape, out->_shape);
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

+ (nullable OCCTShape *)variableFilletedShape:(OCCTShape *)shape
                                 edgeIndices:(NSData *)edgeIndices
                                   endRadius:(double)endRadius
                                middleRadius:(double)middleRadius
                                      status:(nullable OCCTOpStatus *)status
                                     history:(nullable OCCTShapeHistory *)history {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"invalid fillet radii");
    if (!std::isfinite(endRadius) || !std::isfinite(middleRadius) ||
        endRadius <= 0 || middleRadius <= 0) return nil;
    try {
        TopTools_IndexedMapOfShape edgeMap;
        std::set<Standard_Integer> chosen;
        if (!OS3DAdvancedBlendOperands(shape, edgeIndices, edgeMap, chosen, status)) return nil;
        // A closed curve has no stable endpoint/midpoint phase. Symmetry
        // removes reversal ambiguity, not an arbitrary circle seam. Refuse it
        // before building instead of persisting an apparent radius anchor.
        for (const auto index : chosen) {
            TopoDS_Vertex first, last;
            TopExp::Vertices(TopoDS::Edge(edgeMap(index)), first, last);
            if (first.IsNull() || last.IsNull() || first.IsSame(last)) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                              @"variable fillet requires an open edge with two endpoints");
                return nil;
            }
        }
        BRepFilletAPI_MakeFillet mk(shape->_shape);
        TColgp_Array1OfPnt2d law(1, 3);
        law(1) = gp_Pnt2d(0, endRadius);
        law(2) = gp_Pnt2d(0.5, middleRadius);
        law(3) = gp_Pnt2d(1, endRadius);
        for (const auto index : chosen) mk.Add(law, TopoDS::Edge(edgeMap(index)));
        for (const auto index : chosen) {
            const auto contour = mk.Contour(TopoDS::Edge(edgeMap(index)));
            if (contour == 0 || mk.NbEdges(contour) != 1) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                              @"variable fillet requires one original edge per contour");
                return nil;
            }
        }
        OS3DDeadlineProgress *deadline = new OS3DDeadlineProgress(kOS3DOpDeadlineSeconds);
        Handle(Message_ProgressIndicator) progress(deadline);
        OS3D_GUARDED(status, "variableFillet", mk.Build(progress->Start()));
        if (deadline->Fired()) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"the operation exceeded the kernel deadline");
            return nil;
        }
        OCCTShape *out = OS3DFinishBlend(mk, edgeMap, chosen,
                                        mk.IsDone() ? mk.NbFaultyContours() : -1, status);
        if (out != nil) OS3DFillModifierHistory(history, mk, shape->_shape, out->_shape);
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

// Samples the exact trimmed support. UV bounds alone can land in a hole;
// accept only an interior UV point, away from singular normals/boundaries.
static bool OS3DInteriorFaceSample(const TopoDS_Face &face, gp_Pnt &point, gp_Dir &normal) {
    Standard_Real u0, u1, v0, v1;
    BRepTools::UVBounds(face, u0, u1, v0, v1);
    if (!std::isfinite(u0) || !std::isfinite(u1) || !std::isfinite(v0) || !std::isfinite(v1)) return false;
    BRepAdaptor_Surface surface(face);
    for (int grid : {1, 7, 19}) for (int j = 0; j < grid; ++j) for (int i = 0; i < grid; ++i) {
        const double u = u0 + (u1 - u0) * (i + 0.5) / grid;
        const double v = v0 + (v1 - v0) * (j + 0.5) / grid;
        BRepClass_FaceClassifier classifier(face, gp_Pnt2d(u, v), Precision::Confusion());
        if (classifier.State() != TopAbs_IN) continue;
        gp_Vec du, dv; gp_Pnt at;
        try { surface.D1(u, v, at, du, dv); } catch (...) { continue; }
        gp_Vec cross = du.Crossed(dv);
        if (cross.Magnitude() <= 1e-12) continue;
        point = at; normal = gp_Dir(cross);
        if (face.Orientation() == TopAbs_REVERSED) normal.Reverse();
        return true;
    }
    return false;
}

+ (nullable NSData *)faceSampleOfShape:(OCCTShape *)shape index:(NSInteger)index {
    if (shape == nil) return nil;
    try {
        TopTools_IndexedMapOfShape faces; TopExp::MapShapes(shape->_shape, TopAbs_FACE, faces);
        if (index < 1 || index > faces.Extent()) return nil;
        gp_Pnt point; gp_Dir normal;
        if (!OS3DInteriorFaceSample(TopoDS::Face(faces((Standard_Integer)index)), point, normal)) return nil;
        const double row[3] = {point.X(), point.Y(), point.Z()};
        return [NSData dataWithBytes:row length:sizeof(row)];
    } catch (...) { return nil; }
}

+ (nullable NSData *)faceInfoOfShape:(OCCTShape *)shape {
    if (shape == nil || shape->_shape.IsNull()) return nil;
    try {
        TopTools_IndexedMapOfShape faceMap;
        TopExp::MapShapes(shape->_shape, TopAbs_FACE, faceMap);
        std::vector<double> rows;
        rows.reserve((size_t)faceMap.Extent() * 13);
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
            double kind = 2.0, extra = (double)surf.GetType();
            gp_Pnt axisPoint(0.0, 0.0, 0.0);
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
                // The cylinder's OWN axis line: direction AND a placement
                // point that lies on it exactly. A partial cylindrical face
                // has no other exact axis point — the centroid is off the
                // line, and a bbox centre is a different line entirely.
                normal = surf.Cylinder().Axis().Direction();
                axisPoint = surf.Cylinder().Axis().Location();
                extra = surf.Cylinder().Radius();
            } else {
                gp_Pnt at;
                // This normal fingerprints the exact support, never an axis
                // for assembly/datum purposes. Those consumers reject this kind.
                OS3DInteriorFaceSample(face, at, normal);
            }
            const double row[13] = {
                (double)i, kind,
                normal.X(), normal.Y(), normal.Z(),
                centroid.X(), centroid.Y(), centroid.Z(),
                area, extra,
                axisPoint.X(), axisPoint.Y(), axisPoint.Z(),
            };
            rows.insert(rows.end(), row, row + 13);
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
    OS3DSignalScope signalScope;
    try {
        OCC_CATCH_SIGNALS
        const double *p = (const double *)plane.bytes;
        for (int k = 0; k < 6; ++k) if (!std::isfinite(p[k])) return nil;
        BRepBuilderAPI_Copy copy(shape->_shape, Standard_True, Standard_False);
        if (!copy.IsDone() || !OS3DFiniteBounds(copy.Shape())) return nil;
        gp_Pln pln(gp_Pnt(p[0], p[1], p[2]), gp_Dir(p[3], p[4], p[5]));
        BRepAlgoAPI_Section section(copy.Shape(), pln, Standard_False);
        section.SetNonDestructive(Standard_True);
        section.ComputePCurveOn1(Standard_True);
        section.Approximation(Standard_True);
        OS3DDeadlineProgress *deadline = new OS3DDeadlineProgress(kOS3DOpDeadlineSeconds);
        Handle(Message_ProgressIndicator) progress(deadline);
        section.Build(progress->Start());
        if (deadline->Fired() || !section.IsDone()) return nil;
        if (!std::isfinite(deflection) || deflection <= 0) return nil;
        const double chord = deflection;
        std::vector<double> out;
        for (TopExp_Explorer ex(section.Shape(), TopAbs_EDGE); ex.More(); ex.Next()) {
            if (deadline->Fired()) return nil;
            const TopoDS_Edge edge = TopoDS::Edge(ex.Current());
            BRepAdaptor_Curve curve(edge);
            std::vector<gp_Pnt> pts;
            if (curve.GetType() == GeomAbs_Line) {
                pts.push_back(curve.Value(curve.FirstParameter()));
                pts.push_back(curve.Value(curve.LastParameter()));
            } else {
                GCPnts_UniformDeflection disc(curve, chord, curve.FirstParameter(), curve.LastParameter());
                if (disc.IsDone() && disc.NbPoints() >= 2 && disc.NbPoints() <= 100000) {
                    for (Standard_Integer i = 1; i <= disc.NbPoints(); ++i) pts.push_back(disc.Value(i));
                } else {
                    return nil; // a failed curved cut is NOT a straight chord
                }
            }
            if (out.size() + 1 + pts.size() * 3 > 3000000) return nil;
            for (const gp_Pnt &q : pts) {
                if (!std::isfinite(q.X()) || !std::isfinite(q.Y()) || !std::isfinite(q.Z())) return nil;
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


// HLR exposes topological source edges, not a unique set of drawing curves.
// Keep that full ledger while removing geometric containment within ONE
// visibility/category. This is the same product boundary as TechDraw's
// addGeomFromCompound/removeOverlapEdges, implemented with the bundled OCCT
// boolean API (no FreeCAD source is linked or copied).
struct OS3DHLRProjectedEdge {
    TopoDS_Edge edge;
    NSUInteger sourceIndex;
    bool hidden;
    int role;
    int nativeCurveType;
    std::vector<size_t> sourceEdges;
    Bnd_Box bounds;
    double xyz[6]{};
    double sizeSquared = 0;
    int curveType = 0;
    bool retained = true;
};

// A projected circle viewed edge-on can arrive from HLR as a degree-one
// B-spline. Only a full trimmed positive-weight control-hull proof permits
// replacing it by a line: every pole lies on AND between its endpoints.
// Continuity then proves that its image is exactly that segment, within
// OCCT's geometric confusion tolerance. No sampled-point line fitting.
static TopoDS_Edge OS3DHLRRankOneCurve(const TopoDS_Edge &edge) {
    BRepAdaptor_Curve curve(edge);
    if (curve.GetType() != GeomAbs_BSplineCurve && curve.GetType() != GeomAbs_BezierCurve)
        return edge;
    Handle(Geom_BSplineCurve) spline;
    if (curve.GetType() == GeomAbs_BSplineCurve)
        spline = Handle(Geom_BSplineCurve)::DownCast(curve.BSpline()->Copy());
    else
        spline = GeomConvert::CurveToBSplineCurve(curve.Bezier());
    if (spline.IsNull()) return edge;
    const double first = curve.FirstParameter(), last = curve.LastParameter();
    if (!std::isfinite(first) || !std::isfinite(last) || last <= first) return edge;
    spline->Segment(first, last);
    const gp_Pnt a = curve.Value(first), b = curve.Value(last);
    gp_Vec span(a, b);
    const double length = span.Magnitude(), tolerance = Precision::Confusion();
    if (!std::isfinite(length) || length <= tolerance) return edge;
    span /= length;
    for (int pole = 1; pole <= spline->NbPoles(); ++pole) {
        const double weight = spline->Weight(pole);
        const gp_Pnt p = spline->Pole(pole);
        if (!std::isfinite(weight) || weight <= 0 || !std::isfinite(p.X())
            || !std::isfinite(p.Y()) || !std::isfinite(p.Z())) return edge;
        const gp_Vec delta(a, p);
        const double t = delta.Dot(span);
        if (delta.Crossed(span).Magnitude() > tolerance || t < -tolerance
            || t > length + tolerance) return edge;
    }
    BRepBuilderAPI_MakeEdge line(a, b);
    if (!line.IsDone()) throw Standard_Failure("HLR rank-one edge construction failed");
    TopoDS_Edge result = line.Edge();
    result.Orientation(edge.Orientation());
    return result;
}

// Strict set containment of entire trimmed B-rep curves. Endpoint equality
// alone would incorrectly merge an arc and its chord, or two different
// splines. A common edge AND an empty edge difference are required. A mere
// intersection vertex, uncertain/failed boolean or budget expiry never
// authorizes deleting a curve. Partial overlaps are retained conservatively.
static bool OS3DHLRCoveredBy(const TopoDS_Edge &candidate, const TopoDS_Edge &cover,
                            OS3DDeadlineProgress *deadline,
                            const Handle(Message_ProgressIndicator) &progress) {
    TopTools_ListOfShape arguments, tools;
    arguments.Append(candidate); tools.Append(cover);
    BRepAlgoAPI_Common common;
    common.SetArguments(arguments); common.SetTools(tools);
    common.SetNonDestructive(Standard_True); common.SetRunParallel(Standard_False);
    common.SetFuzzyValue(0.0);
    common.Build(progress->Start());
    if (deadline->Fired() || !common.IsDone() || common.HasErrors() || common.HasWarnings())
        throw Standard_Failure("HLR curve common refused");
    if (common.Shape().IsNull() || !TopExp_Explorer(common.Shape(), TopAbs_EDGE).More()) return false;
    BRepAlgoAPI_Cut remainder;
    remainder.SetArguments(arguments); remainder.SetTools(tools);
    remainder.SetNonDestructive(Standard_True); remainder.SetRunParallel(Standard_False);
    remainder.SetFuzzyValue(0.0);
    remainder.Build(progress->Start());
    if (deadline->Fired() || !remainder.IsDone() || remainder.HasErrors() || remainder.HasWarnings())
        throw Standard_Failure("HLR curve difference refused");
    if (remainder.Shape().IsNull()) throw Standard_Failure("HLR null curve difference");
    return !TopExp_Explorer(remainder.Shape(), TopAbs_EDGE).More();
}

static void OS3DHLRNormalize(std::vector<OS3DHLRProjectedEdge> &edges,
                            OS3DDeadlineProgress *deadline,
                            const Handle(Message_ProgressIndicator) &progress) {
    // Bucket by actual HLR class, never merge sharp and Rg1 categories or
    // visible and hidden ink. Circle and trimmed circle use the same curve
    // type; differing supports are still decided by exact Common/Cut.
    std::map<std::tuple<bool, int, int>, std::vector<size_t>> buckets;
    for (size_t i = 0; i < edges.size(); ++i) {
        if (deadline->Fired()) throw Standard_Failure("HLR bounds deadline exceeded");
        auto &edge = edges[i];
        BRepBndLib::AddOptimal(edge.edge, edge.bounds, Standard_False, Standard_False);
        if (edge.bounds.IsVoid()) throw Standard_Failure("HLR empty projected bounds");
        edge.bounds.Get(edge.xyz[0], edge.xyz[1], edge.xyz[2],
                        edge.xyz[3], edge.xyz[4], edge.xyz[5]);
        for (double x : edge.xyz)
            if (!std::isfinite(x)) throw Standard_Failure("HLR infinite projected bounds");
        for (int k = 0; k < 3; ++k) {
            const double span = edge.xyz[k + 3] - edge.xyz[k];
            edge.sizeSquared += span * span;
        }
        if (!std::isfinite(edge.sizeSquared)) throw Standard_Failure("HLR projected bounds overflow");
        edge.curveType = (int)BRepAdaptor_Curve(edge.edge).GetType();
        buckets[{edge.hidden, edge.role, edge.curveType}].push_back(i);
    }
    size_t candidateChecks = 0, booleanPairs = 0;
    for (auto &bucket : buckets) {
        auto &indices = bucket.second;
        std::stable_sort(indices.begin(), indices.end(), [&](size_t a, size_t b) {
            return edges[a].sizeSquared > edges[b].sizeSquared;
        });
        std::vector<size_t> covers;
        for (size_t i : indices) {
            for (size_t j : covers) {
                if (deadline->Fired() || ++candidateChecks > 2000000)
                    throw Standard_Failure("HLR containment candidate budget exceeded");
                bool mayContain = true;
                for (int k = 0; k < 3; ++k) {
                    if (edges[i].xyz[k] < edges[j].xyz[k] - Precision::Confusion()
                        || edges[i].xyz[k + 3] > edges[j].xyz[k + 3] + Precision::Confusion())
                        mayContain = false;
                }
                if (!mayContain) continue;
                if (++booleanPairs > 25000)
                    throw Standard_Failure("HLR containment boolean budget exceeded");
                if (!OS3DHLRCoveredBy(edges[i].edge, edges[j].edge, deadline, progress)) continue;
                edges[j].sourceEdges.insert(edges[j].sourceEdges.end(),
                    edges[i].sourceEdges.begin(), edges[i].sourceEdges.end());
                edges[i].retained = false;
                break;
            }
            if (edges[i].retained) covers.push_back(i);
        }
    }
}


+ (nullable NSData *)hiddenLineProjectionOfShapes:(NSArray<OCCTShape *> *)shapes
                                           frame:(NSData *)frame
                                      deflection:(double)deflection {
    if (shapes.count == 0 || shapes.count > 64 || frame.length != 9 * sizeof(double)
        || !std::isfinite(deflection) || deflection <= 0) return nil;
    OS3DSignalScope signalScope;
    try {
        OCC_CATCH_SIGNALS
        const double *f = (const double *)frame.bytes;
        for (int k = 0; k < 9; ++k) if (!std::isfinite(f[k])) return nil;
        // OCCT 7.8.1 Update/Hide have NO progress/cancellation argument.
        // This deadline is checked BETWEEN native phases and is not a hard
        // timeout inside those phases. The service worker must join/discard a
        // cancelled generation after the active native phase returns.
        OS3DDeadlineProgress *deadline = new OS3DDeadlineProgress(kOS3DOpDeadlineSeconds);
        Handle(Message_ProgressIndicator) progress(deadline);
        Handle(HLRBRep_Algo) algo = new HLRBRep_Algo;
        std::vector<TopoDS_Shape> copies;
        size_t faceCount = 0, edgeCount = 0;
        for (OCCTShape *shape in shapes) {
            if (shape == nil || shape->_shape.IsNull() || deadline->Fired()) return nil;
            // Deep geometry + topology copy: HLR never shares curves/surfaces
            // or cached triangulation with a live body/undo snapshot.
            BRepBuilderAPI_Copy copy(shape->_shape, Standard_True, Standard_False);
            if (!copy.IsDone() || !OS3DFiniteBounds(copy.Shape())) return nil;
            TopTools_IndexedMapOfShape faces, edges;
            TopExp::MapShapes(copy.Shape(), TopAbs_FACE, faces);
            TopExp::MapShapes(copy.Shape(), TopAbs_EDGE, edges);
            faceCount += faces.Extent(); edgeCount += edges.Extent();
            if (faceCount > 1024 || edgeCount > 8192) return nil;
            copies.push_back(copy.Shape());
            algo->Add(copies.back(), 0);
        }
        algo->Projector(HLRAlgo_Projector(gp_Ax2(gp_Pnt(f[0], f[1], f[2]),
            gp_Dir(f[3], f[4], f[5]), gp_Dir(f[6], f[7], f[8]))));
        algo->Update();
        if (deadline->Fired()) return nil;
        algo->Hide();
        if (deadline->Fired()) return nil;
        HLRBRep_HLRToShape result(algo);
        std::vector<OS3DHLRProjectedEdge> projected;
        const HLRBRep_TypeOfResultingEdge kinds[] = {
            HLRBRep_Sharp, HLRBRep_OutLine, HLRBRep_Rg1Line
        };
        for (NSUInteger index = 0; index < shapes.count; ++index) {
            for (int hidden = 0; hidden < 2; ++hidden) {
                for (int role = 0; role < 3; ++role) {
                    if (deadline->Fired()) return nil;
                    TopoDS_Shape edges = result.CompoundOfEdges(copies[index],
                        kinds[role], hidden == 0, Standard_False);
                    if (edges.IsNull()) continue;
                    if (!BRepLib::BuildCurves3d(edges)) return nil;
                    for (TopExp_Explorer ex(edges, TopAbs_EDGE); ex.More(); ex.Next()) {
                        if (deadline->Fired() || projected.size() >= 50000) return nil;
                        const TopoDS_Edge edge = TopoDS::Edge(ex.Current());
                        const int nativeType = (int)BRepAdaptor_Curve(edge).GetType();
                        OS3DHLRProjectedEdge record;
                        record.edge = OS3DHLRRankOneCurve(edge);
                        record.sourceIndex = index; record.hidden = hidden != 0;
                        record.role = role; record.nativeCurveType = nativeType;
                        record.sourceEdges.push_back(projected.size());
                        projected.push_back(std::move(record));
                    }
                }
            }
        }
        size_t totalPoints = 0;
        const auto point = [](const gp_Pnt &q) -> NSArray * {
            if (!std::isfinite(q.X()) || !std::isfinite(q.Y()))
                throw Standard_Failure("non-finite projected curve");
            return @[@(q.X()), @(q.Y())];
        };
        const auto encode = [&](const OS3DHLRProjectedEdge &record) -> NSMutableDictionary * {
            if (deadline->Fired()) throw Standard_Failure("HLR serialization deadline exceeded");
            BRepAdaptor_Curve curve(record.edge);
            double first = curve.FirstParameter(), last = curve.LastParameter();
            if (!std::isfinite(first) || !std::isfinite(last)) throw Standard_Failure("HLR curve serialization refused");
            NSMutableDictionary *row = [@{
                @"sourceIndex": @(record.sourceIndex), @"hidden": @(record.hidden),
                @"nativeCurveType": @(record.nativeCurveType), @"edgeClass": @(record.role),
                @"role": record.role == 1 ? @"outline" : @"edges"
            } mutableCopy];
            if (curve.GetType() == GeomAbs_Line) {
                row[@"kind"] = @"line";
                row[@"points"] = @[point(curve.Value(first)), point(curve.Value(last))];
                totalPoints += 2;
            } else if (curve.GetType() == GeomAbs_Circle) {
                const gp_Circ circle = curve.Circle();
                const gp_Pnt center = circle.Location();
                row[@"center"] = point(center);
                row[@"radius"] = @(circle.Radius());
                const double tau = 2.0 * M_PI;
                if (std::abs(last - first) >= tau - 1e-8) {
                    row[@"kind"] = @"circle";
                } else {
                    auto angle = [&](double t) {
                        gp_Pnt q = curve.Value(t);
                        return std::atan2(q.Y() - center.Y(), q.X() - center.X());
                    };
                    auto positive = [&](double a) { a = std::fmod(a, tau); return a < 0 ? a + tau : a; };
                    double a = angle(first), b = angle(last), mid = angle((first + last) / 2);
                    if (positive(mid - a) > positive(b - a) + 1e-9) std::swap(a, b);
                    row[@"kind"] = @"arc";
                    row[@"angles"] = @[@(a), @(a + positive(b - a))];
                }
                totalPoints += 3;
            } else {
                GCPnts_UniformDeflection disc(curve, deflection, first, last);
                if (!disc.IsDone() || disc.NbPoints() < 2 || disc.NbPoints() > 100000) throw Standard_Failure("HLR curve serialization refused");
                NSMutableArray *points = [NSMutableArray arrayWithCapacity:disc.NbPoints()];
                for (Standard_Integer n = 1; n <= disc.NbPoints(); ++n) [points addObject:point(disc.Value(n))];
                row[@"kind"] = @"polyline";
                row[@"points"] = points;
                totalPoints += disc.NbPoints();
            }
            if (totalPoints > 1000000) throw Standard_Failure("HLR curve serialization refused");
            return row;
        };
        // sourceEdges is a lossless ownership ledger of every HLR record,
        // including curves absorbed into a longer drawing edge. Its curve is
        // the exact rank-one image when the control-hull proof succeeded.
        NSMutableArray *sourceEdges = [NSMutableArray arrayWithCapacity:projected.size()];
        for (const auto &edge : projected) [sourceEdges addObject:encode(edge)];
        OS3DHLRNormalize(projected, deadline, progress);
        NSMutableArray *rows = [NSMutableArray array];
        for (size_t index = 0; index < projected.size(); ++index) {
            auto &edge = projected[index];
            if (!edge.retained) continue;
            std::sort(edge.sourceEdges.begin(), edge.sourceEdges.end());
            NSMutableArray *indices = [NSMutableArray arrayWithCapacity:edge.sourceEdges.size()];
            for (size_t raw : edge.sourceEdges) [indices addObject:@(raw)];
            NSMutableDictionary *row = [sourceEdges[index] mutableCopy];
            row[@"sourceEdgeIndices"] = indices;
            [rows addObject:row];
        }
        return [NSJSONSerialization dataWithJSONObject:@{
            @"version": @2, @"method": @"occt-brep-hlr", @"curveDeflectionMM": @(deflection),
            @"normalization": @"occt-curve-containment-v1", @"sourceEdges": sourceEdges, @"edges": rows
        } options:0 error:nil];
    } catch (...) { return nil; }
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

+ (nullable NSData *)edgeCurveDataOfShape:(OCCTShape *)shape {
    if (shape == nil || shape->_shape.IsNull()) return nil;
    try {
        TopTools_IndexedMapOfShape edgeMap;
        TopExp::MapShapes(shape->_shape, TopAbs_EDGE, edgeMap);
        const double nan = std::numeric_limits<double>::quiet_NaN();
        // Per edge: [index, kind, ax, ay, az, bx, by, bz].
        std::vector<double> out((size_t)edgeMap.Extent() * 8, nan);
        for (Standard_Integer e = 1; e <= edgeMap.Extent(); ++e) {
            const TopoDS_Edge edge = TopoDS::Edge(edgeMap(e));
            const size_t base = (size_t)(e - 1) * 8;
            out[base] = (double)e;
            if (BRep_Tool::Degenerated(edge)) continue;
            try {
                BRepAdaptor_Curve curve(edge);
                const double first = curve.FirstParameter();
                const double last = curve.LastParameter();
                const bool isLine = curve.GetType() == GeomAbs_Line;
                out[base + 1] = isLine ? 0.0 : 1.0;
                const gp_Pnt a = curve.Value(first);
                const gp_Pnt b = curve.Value(last);
                out[base + 2] = a.X(); out[base + 3] = a.Y(); out[base + 4] = a.Z();
                out[base + 5] = b.X(); out[base + 6] = b.Y(); out[base + 7] = b.Z();
            } catch (Standard_Failure &) {
                // Leave this edge's kind/endpoints NaN: it exists but has no
                // evaluable curve, so it is not projectable.
                continue;
            }
        }
        return [NSData dataWithBytes:out.data() length:out.size() * sizeof(double)];
    } catch (...) {
        return nil;
    }
}

+ (nullable OCCTShape *)threadOrientedSolid:(OCCTShape *)shape {
    if (shape == nil || shape->_shape.IsNull()) return nil;
    try {
        TopTools_IndexedMapOfShape solids;
        TopExp::MapShapes(shape->_shape, TopAbs_SOLID, solids);
        if (solids.Extent() != 1) return nil;
        TopoDS_Solid solid = TopoDS::Solid(solids(1));
        if (!BRepLib::OrientClosedSolid(solid)) return nil;
        OCCTShape *result = [OCCTShape new];
        result->_shape = solid;
        return result;
    } catch (...) { return nil; }
}

+ (nullable NSData *)threadCylinderExtentOfShape:(OCCTShape *)shape faceIndex:(NSInteger)faceIndex {
    if (shape == nil || shape->_shape.IsNull() || faceIndex < 1) return nil;
    try {
        TopTools_IndexedMapOfShape faces;
        TopExp::MapShapes(shape->_shape, TopAbs_FACE, faces);
        if (faceIndex > faces.Extent()) return nil;
        TopoDS_Face face = TopoDS::Face(faces((Standard_Integer)faceIndex));
        BRepAdaptor_Surface surface(face, Standard_True);
        if (surface.GetType() != GeomAbs_Cylinder) return nil;
        Standard_Real u0, u1, v0, v1;
        BRepTools::UVBounds(face, u0, u1, v0, v1);
        // This bounded product supports complete, finite cylindrical stock.
        // Partial cylinders and trimmed non-rectangular bores are refused.
        if (!std::isfinite(u0) || !std::isfinite(u1) || !std::isfinite(v0) || !std::isfinite(v1)
            || std::fabs((u1-u0) - 2*M_PI) > 1e-7 || !(v1 > v0)) return nil;
        const gp_Cylinder c = surface.Cylinder();
        GProp_GProps areaProps;
        BRepGProp::SurfaceProperties(face, areaProps);
        const double expectedArea = 2*M_PI*c.Radius()*(v1-v0);
        if (!(expectedArea > 0) || std::fabs(std::fabs(areaProps.Mass())-expectedArea)
            > std::max(1e-7, expectedArea*1e-8)) return nil;
        const gp_Pnt o = c.Location();
        const gp_Dir n = c.Axis().Direction(), x = c.Position().XDirection();
        // A cylinder's parametric frame can be indirect, and an extrusion can
        // reverse the face. Orientation alone does not identify a bore. Ask
        // which radial side contains actual material in an oriented solid.
        TopTools_IndexedMapOfShape solids;
        TopExp::MapShapes(shape->_shape, TopAbs_SOLID, solids);
        if (solids.Extent() != 1) return nil;
        TopoDS_Solid solid = TopoDS::Solid(solids(1));
        if (!BRepLib::OrientClosedSolid(solid)) return nil;
        const gp_Pnt onSurface = surface.Value((u0 + u1) / 2, (v0 + v1) / 2);
        const gp_Pnt onAxis = o.Translated(gp_Vec(n).Multiplied((v0 + v1) / 2));
        gp_Vec radial(onAxis, onSurface);
        if (radial.Magnitude() <= Precision::Confusion()) return nil;
        radial.Normalize();
        const double step = std::max(1e-5, c.Radius() * 1e-5);
        BRepClass3d_SolidClassifier inward(solid, onSurface.Translated(radial.Multiplied(-step)), Precision::Confusion());
        BRepClass3d_SolidClassifier outward(solid, onSurface.Translated(radial.Multiplied(step)), Precision::Confusion());
        const bool external = inward.State() == TopAbs_IN && outward.State() == TopAbs_OUT;
        const bool internal = outward.State() == TopAbs_IN && inward.State() == TopAbs_OUT;
        if (!external && !internal) return nil;
        const double values[13] = {c.Radius(), o.X(), o.Y(), o.Z(), n.X(), n.Y(), n.Z(),
            x.X(), x.Y(), x.Z(), v0, v1, internal ? 1.0 : 0.0};
        for (double value : values) if (!std::isfinite(value)) return nil;
        return [NSData dataWithBytes:values length:sizeof(values)];
    } catch (...) { return nil; }
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

// Keep OCCT's existing knot-span Gauss-Kronrod path for spline/Bezier or
// unclassified geometry. Certified elementary surfaces with elementary 3D
// and parametric boundary curves can use OCCT's adaptive Gauss algorithm;
// this avoids nested Kronrod refinement on nearly cancelling plane terms.
// Both algorithms integrate the exact B-rep at Eps1e-7, not its mesh.
static bool OS3DIsElementaryVolumeCurve(GeomAbs_CurveType type) {
    switch (type) {
        case GeomAbs_Line:
        case GeomAbs_Circle:
        case GeomAbs_Ellipse:
        case GeomAbs_Hyperbola:
        case GeomAbs_Parabola:
            return true;
        default:
            return false;
    }
}

static bool OS3DHasElementaryVolumeGeometry(const TopoDS_Shape &shape) {
    bool sawFace = false;
    try {
        for (TopExp_Explorer faces(shape, TopAbs_FACE); faces.More(); faces.Next()) {
            const TopoDS_Face face = TopoDS::Face(faces.Current());
            sawFace = true;
            BRepAdaptor_Surface surface(face, Standard_False);
            switch (surface.GetType()) {
                case GeomAbs_Plane:
                case GeomAbs_Cylinder:
                case GeomAbs_Cone:
                case GeomAbs_Sphere:
                case GeomAbs_Torus:
                    break;
                default:
                    return false;
            }
            for (TopExp_Explorer edges(face, TopAbs_EDGE); edges.More(); edges.Next()) {
                const TopoDS_Edge edge = TopoDS::Edge(edges.Current());
                // Integration follows the face's pcurve. Analytic supporting
                // surfaces alone are insufficient for spline-trimmed faces.
                BRepAdaptor_Curve2d pcurve(edge, face);
                if (!OS3DIsElementaryVolumeCurve(pcurve.GetType())) return false;
                if (!BRep_Tool::Degenerated(edge)) {
                    BRepAdaptor_Curve curve(edge);
                    if (!OS3DIsElementaryVolumeCurve(curve.GetType())) return false;
                }
            }
        }
        return sawFace;
    } catch (...) {
        // Unknown geometry retains the original precision-preserving path.
        return false;
    }
}

enum class OS3DVolumeIntegration { AdaptiveGauss, SpanKronrod };

// Exact-geometry volume via existing OCCT algorithms;0 on any exception.
// The historical spline-profile pin needs GK(Eps1e-7,IsUseSpantrue): default
// fixed-order Gauss was0.4-1.3% high across knot spans. Do not remove that
// path or replace it with triangulation when repairing analytic performance.
static double OS3DVolume(const TopoDS_Shape &shape,
                         OS3DVolumeIntegration *integration = nullptr) {
    if (shape.IsNull()) return 0.0;
    try {
        GProp_GProps props;
        if (OS3DHasElementaryVolumeGeometry(shape)) {
            if (integration) *integration = OS3DVolumeIntegration::AdaptiveGauss;
            // OCCT7.8.1's Eps overload internally passes UseTriangulationfalse.
            // An explicit Standard_Real selects it, not the bool overload.
            BRepGProp::VolumeProperties(shape, props, Standard_Real(1e-7),
                                        /*OnlyClosed*/ Standard_False,
                                        /*SkipShared*/ Standard_False);
        } else {
            if (integration) *integration = OS3DVolumeIntegration::SpanKronrod;
            BRepGProp::VolumePropertiesGK(shape, props, /*Eps*/ 1e-7,
                                          /*OnlyClosed*/ Standard_False,
                                          /*IsUseSpan*/ Standard_True);
        }
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

// Offset makers may modify pcurves/SameParameter flags even when they fail.
// Every shell attempt owns its geometry. Translate its history back through
// BRepBuilderAPI_Copy's explicit source map, never copied face-map ordinals.
static void OS3DCollectShellHistory(BRepBuilderAPI_MakeShape *builder,
                                    const TopoDS_Shape &source,
                                    BRepBuilderAPI_Copy &copy,
                                    const Handle(BRepTools_History) &split,
                                    std::vector<OS3DHistEdge> &edges) {
    const struct { TopAbs_ShapeEnum type; int32_t kind; } kinds[] = {
        {TopAbs_FACE, 0}, {TopAbs_EDGE, 1}};
    for (const auto &kind : kinds) {
        TopTools_IndexedMapOfShape roots; TopExp::MapShapes(source, kind.type, roots);
        for (Standard_Integer i = 1; i <= roots.Extent(); ++i) {
            const TopoDS_Shape copied = copy.ModifiedShape(roots(i));
            if (copied.IsNull()) continue;
            for (const TopoDS_Shape &piece : OS3DImagesThrough(split, copied)) {
                // Includes genuine same-face survival through the owned copy;
                // OS3DFillHistory's final-shape gate discards removed faces.
                edges.push_back({piece, 0, kind.kind, (int32_t)i, 1});
                if (builder == nullptr) continue;
                for (int32_t relation : {1, 2}) {
                    try {
                        const TopTools_ListOfShape &list = relation == 1
                            ? builder->Modified(piece) : builder->Generated(piece);
                        for (TopTools_ListIteratorOfListOfShape it(list); it.More(); it.Next())
                            edges.push_back({it.Value(), 0, kind.kind, (int32_t)i, relation});
                    } catch (...) { /* this source produced no such relation */ }
                }
            }
        }
    }
}

// Exact bounded alternative to offsetting a curved closing surface:
// all surviving walls must be planar CONVEX SUPPORTS of the source solid.
// This is a source/halfspace boolean construction, not a generic surface offset.
static NSInteger OS3DSurfaceFreeEdges(const TopoDS_Shape &shape);
struct OS3DSupportFaceLineage {
    TopoDS_Shape face;
    std::set<int32_t> sourceFaces;
    bool generated = false;
};

// Real OCCT Modified/Generated plus same-TShape survival. No geometric/ordinal
// nearest match is used to identify a result face or an offset wall.
static std::vector<OS3DSupportFaceLineage> OS3DSupportBooleanLineage(
    BRepAlgoAPI_BooleanOperation &maker, const TopoDS_Shape &result,
    const std::vector<OS3DSupportFaceLineage> &inputs) {
    TopTools_IndexedMapOfShape faces; TopExp::MapShapes(result, TopAbs_FACE, faces);
    std::vector<OS3DSupportFaceLineage> out;
    for (Standard_Integer i = 1; i <= faces.Extent(); ++i) out.push_back({faces(i), {}, false});
    auto claim = [&](const TopoDS_Shape &image, const OS3DSupportFaceLineage &parent, bool generated) {
        if (image.IsNull()) return;
        auto one = [&](const TopoDS_Shape &face) {
            const Standard_Integer index = faces.FindIndex(face);
            if (index <= 0) return;
            auto &row = out[(size_t)index - 1];
            row.sourceFaces.insert(parent.sourceFaces.begin(), parent.sourceFaces.end());
            row.generated = row.generated || parent.generated || generated;
        };
        if (image.ShapeType() == TopAbs_FACE) one(image);
        else if (image.ShapeType() < TopAbs_FACE)
            for (TopExp_Explorer it(image, TopAbs_FACE); it.More(); it.Next()) one(it.Current());
    };
    for (const auto &parent : inputs) {
        claim(parent.face, parent, false);
        for (int relation : {1, 2}) {
            const TopTools_ListOfShape &images = relation == 1 ? maker.Modified(parent.face) : maker.Generated(parent.face);
            for (TopTools_ListIteratorOfListOfShape it(images); it.More(); it.Next()) claim(it.Value(), parent, relation == 2);
        }
    }
    for (const auto &row : out)
        if (row.sourceFaces.empty()) throw Standard_Failure("planar support boolean has an unproven face ancestry");
    return out;
}

static OCCTShape *OS3DPlanarSupportShell(const TopoDS_Shape &source,
                                        const TopTools_ListOfShape &openFaces,
                                        double thickness, OCCTOpStatus *status,
                                        OCCTShapeHistory *history) {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"planar-support shell is not applicable");
    if (!std::isfinite(thickness) || thickness <= 1e-6 || openFaces.IsEmpty()) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, [NSString stringWithFormat:@"support admission thickness=%.17g openings=%d", thickness, openFaces.Extent()]); return nil;
    }
    try {
        TopTools_IndexedMapOfShape sourceFaces; TopExp::MapShapes(source, TopAbs_FACE, sourceFaces);
        if (sourceFaces.Extent() < 2 || sourceFaces.Extent() > 64 || openFaces.Extent() > 16) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused, [NSString stringWithFormat:@"support face budget source=%d openings=%d", sourceFaces.Extent(), openFaces.Extent()]); return nil;
        }
        std::set<Standard_Integer> openings;
        for (TopTools_ListIteratorOfListOfShape it(openFaces); it.More(); it.Next()) {
            const Standard_Integer index = sourceFaces.FindIndex(it.Value());
            if (index <= 0 || !openings.insert(index).second
                || BRepAdaptor_Surface(TopoDS::Face(it.Value())).GetType() == GeomAbs_Plane) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused, [NSString stringWithFormat:@"support opening index=%d type=%d", index, (int)BRepAdaptor_Surface(TopoDS::Face(it.Value())).GetType()]); return nil;
            }
        }
        struct Support { int32_t sourceFace; gp_Pnt origin; gp_Dir outward; };
        std::vector<Support> supports;
        for (Standard_Integer i = 1; i <= sourceFaces.Extent(); ++i) {
            if (openings.count(i)) continue;
            const TopoDS_Face face = TopoDS::Face(sourceFaces(i));
            BRepAdaptor_Surface surface(face);
            if (surface.GetType() != GeomAbs_Plane
                || (face.Orientation() != TopAbs_FORWARD && face.Orientation() != TopAbs_REVERSED)) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused, [NSString stringWithFormat:@"support wall index=%d type=%d orientation=%d", i, (int)surface.GetType(), (int)face.Orientation()]); return nil;
            }
            const gp_Pln plane = surface.Plane();
            gp_Dir normal = plane.Axis().Direction();
            if (face.Orientation() == TopAbs_REVERSED) normal.Reverse();
            supports.push_back({(int32_t)i, plane.Location(), normal});
        }
        if (supports.empty() || supports.size() > 16) return nil;
        BRepBuilderAPI_Copy copy(source, Standard_True, Standard_False);
        if (!copy.IsDone() || copy.Shape().IsNull()) return nil;
        const TopoDS_Shape owned = copy.Shape();
        const double before = OS3DVolume(owned), inputTolerance = OS3DMaxTolerance(owned);
        if (!std::isfinite(before) || before <= 0 || !std::isfinite(inputTolerance)
            || inputTolerance > 1e-5 || !OS3DFiniteBounds(owned) || !BRepCheck_Analyzer(owned).IsValid()) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused, [NSString stringWithFormat:@"support input health volume=%.17g tolerance=%.17g finite=%d valid=%d", before, inputTolerance, (int)OS3DFiniteBounds(owned), (int)BRepCheck_Analyzer(owned).IsValid()]); return nil;
        }
        // Admit healthy source geometry within the same 1e-5 mm native
        // ceiling required of the result. Never multiply a valid input
        // tolerance into a looser output precision claim.
        const double allowedTolerance = std::min(1e-5, std::max(1e-6, inputTolerance * 10));
        const double volumeTolerance = std::max(1e-9, before * 1e-8);
        NSString *closedRefusal = @"";
        auto closedSingle = [&](const TopoDS_Shape &shape) -> TopoDS_Shape {
            int count = 0; TopoDS_Shape solid = OS3DExtractSingleSolid(shape, count);
            if (count != 1 || solid.IsNull()) {
                closedRefusal = [NSString stringWithFormat:@"expected one solid, got %d", count]; return TopoDS_Shape();
            }
            const double measuredTolerance = OS3DMaxTolerance(solid);
            if (!std::isfinite(measuredTolerance) || measuredTolerance < 0 || measuredTolerance > allowedTolerance) {
                closedRefusal = [NSString stringWithFormat:@"native tolerance %.17g exceeds %.17g mm", measuredTolerance, allowedTolerance];
                return TopoDS_Shape();
            }
            if (!OS3DFiniteBounds(solid) || !BRepCheck_Analyzer(solid).IsValid() || OS3DSurfaceFreeEdges(solid) != 0) {
                closedRefusal = @"native result is non-finite, invalid, or has free/nonmanifold edges"; return TopoDS_Shape();
            }
            closedRefusal = @""; return solid;
        };
        OS3DDeadlineProgress *deadline = new OS3DDeadlineProgress(kOS3DOpDeadlineSeconds);
        Handle(Message_ProgressIndicator) progress(deadline);
        auto configure = [](auto &maker, const TopoDS_Shape &argument, const TopoDS_Shape &tool) {
            TopTools_ListOfShape args, tools; args.Append(argument); tools.Append(tool);
            maker.SetArguments(args); maker.SetTools(tools);
            maker.SetNonDestructive(Standard_True); maker.SetRunParallel(Standard_False);
            maker.SetFuzzyValue(0.0); maker.SetToFillHistory(Standard_True);
        };
        auto halfspace = [&](const Support &support, double inset) -> TopoDS_Solid {
            const gp_Vec inward = gp_Vec(support.outward).Multiplied(-1);
            const gp_Pnt origin = support.origin.Translated(inward.Multiplied(inset));
            BRepBuilderAPI_MakeFace face(gp_Pln(origin, support.outward));
            if (!face.IsDone()) throw Standard_Failure("planar support face construction failed");
            BRepPrimAPI_MakeHalfSpace half(face.Face(), origin.Translated(inward.Multiplied(std::max(1.0, thickness))));
            if (!half.IsDone() || half.Solid().IsNull()) throw Standard_Failure("planar support halfspace construction failed");
            return half.Solid();
        };
        std::vector<TopoDS_Solid> inwardTools;
        // PROVE each orientation with real Common AND empty source-minus-halfspace.
        // A plane merely passing through a face does not prove convex support.
        for (const auto &support : supports) {
            if (deadline->Fired()) throw Standard_Failure("planar support proof deadline exceeded");
            TopoDS_Solid originalHalf;
            OS3D_GUARDED(status, "planar support halfspace", originalHalf = halfspace(support, 0));
            BRepAlgoAPI_Common proof; configure(proof, owned, originalHalf);
            OS3D_GUARDED(status, "planar support common proof", proof.Build(progress->Start()));
            if (deadline->Fired() || !proof.IsDone() || proof.HasErrors() || proof.HasWarnings())
                throw Standard_Failure("planar support common proof failed");
            const TopoDS_Shape contained = closedSingle(proof.Shape());
            const double commonVolume = contained.IsNull() ? 0 : OS3DVolume(contained);
            if (contained.IsNull() || !std::isfinite(commonVolume) || fabs(commonVolume - before) > volumeTolerance) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused, [NSString stringWithFormat:
                    @"planar support %d containment: source=%.17g common=%.17g budget=%.17g (%@)",
                    support.sourceFace, before, commonVolume, volumeTolerance, closedRefusal]); return nil;
            }
            BRepAlgoAPI_Cut outside; configure(outside, owned, originalHalf);
            OS3D_GUARDED(status, "planar support outside proof", outside.Build(progress->Start()));
            if (deadline->Fired() || !outside.IsDone() || outside.HasErrors() || outside.HasWarnings()
                || outside.Shape().IsNull() || TopExp_Explorer(outside.Shape(), TopAbs_SOLID).More())
                throw Standard_Failure("source has material outside an original planar support");
            TopoDS_Solid inwardHalf;
            OS3D_GUARDED(status, "inward planar support halfspace", inwardHalf = halfspace(support, thickness));
            inwardTools.push_back(inwardHalf);
        }
        std::vector<OS3DSupportFaceLineage> sourceLineage;
        for (Standard_Integer i = 1; i <= sourceFaces.Extent(); ++i) {
            const TopoDS_Shape face = copy.ModifiedShape(sourceFaces(i));
            if (face.IsNull()) throw Standard_Failure("planar support copy lost an original face");
            sourceLineage.push_back({face, {(int32_t)i}, false});
        }
        TopoDS_Shape cavity = owned;
        auto cavityLineage = sourceLineage;
        for (size_t i = 0; i < supports.size(); ++i) {
            BRepAlgoAPI_Common common; configure(common, cavity, inwardTools[i]);
            OS3D_GUARDED(status, "planar support cavity common", common.Build(progress->Start()));
            if (deadline->Fired() || !common.IsDone() || common.HasErrors() || common.HasWarnings())
                throw Standard_Failure("planar support cavity common failed");
            const TopoDS_Shape next = closedSingle(common.Shape());
            const double nextVolume = next.IsNull() ? 0 : OS3DVolume(next);
            if (next.IsNull() || !std::isfinite(nextVolume) || nextVolume <= volumeTolerance) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused, [NSString stringWithFormat:
                    @"planar support cavity %lu: volume=%.17g budget=%.17g (%@)",
                    (unsigned long)i, nextVolume, volumeTolerance, closedRefusal]); return nil;
            }
            auto ancestors = cavityLineage;
            for (TopExp_Explorer face(inwardTools[i], TopAbs_FACE); face.More(); face.Next())
                ancestors.push_back({face.Current(), {supports[i].sourceFace}, true});
            cavityLineage = OS3DSupportBooleanLineage(common, next, ancestors);
            cavity = next;
        }
        // Every retained wall must actually have its authored inward plane in
        // the final cavity; no redundant constraint is claimed as a measured wall.
        for (const auto &support : supports) {
            bool found = false;
            for (const auto &row : cavityLineage) {
                if (!row.generated || !row.sourceFaces.count(support.sourceFace)) continue;
                BRepAdaptor_Surface surface(TopoDS::Face(row.face));
                if (surface.GetType() != GeomAbs_Plane) continue;
                const gp_Pln plane = surface.Plane();
                const double distance = gp_Vec(support.origin, plane.Location()).Dot(gp_Vec(support.outward));
                if (fabs(plane.Axis().Direction().Dot(support.outward)) > 1 - 1e-12
                    && fabs(distance + thickness) <= allowedTolerance) { found = true; break; }
            }
            if (!found) throw Standard_Failure("planar support has no verified inward cavity face");
        }
        const double cavityVolume = OS3DVolume(cavity);
        if (!std::isfinite(cavityVolume) || cavityVolume <= volumeTolerance || cavityVolume >= before - volumeTolerance)
            throw Standard_Failure("planar support cavity did not remove a positive wall volume");
        BRepAlgoAPI_Cut cut; configure(cut, owned, cavity);
        OS3D_GUARDED(status, "planar support shell difference", cut.Build(progress->Start()));
        if (deadline->Fired() || !cut.IsDone() || cut.HasErrors() || cut.HasWarnings())
            throw Standard_Failure("planar support shell difference failed");
        const TopoDS_Shape result = closedSingle(cut.Shape());
        const double after = result.IsNull() ? 0 : OS3DVolume(result);
        if (result.IsNull() || !std::isfinite(after) || after <= volumeTolerance || after >= before - volumeTolerance
            || fabs((after + cavityVolume) - before) > volumeTolerance) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused, [NSString stringWithFormat:
                @"planar support shell: source=%.17g cavity=%.17g wall=%.17g balance=%.17g budget=%.17g (%@)",
                before, cavityVolume, after, after + cavityVolume - before, volumeTolerance, closedRefusal]); return nil;
        }
        auto ancestors = sourceLineage;
        for (auto row : cavityLineage) { row.generated = true; ancestors.push_back(row); }
        const auto lineage = OS3DSupportBooleanLineage(cut, result, ancestors);
        if (history != nil) {
            std::vector<OS3DHistEdge> rows;
            for (const auto &row : lineage)
                for (int32_t root : row.sourceFaces) rows.push_back({row.face, 0, 0, root, row.generated ? 2 : 1});
            if (rows.size() > kOS3DMaxHistoryRows) throw Standard_Failure("planar support shell history budget exceeded");
            OS3DFillHistory(history, rows, {source}, Handle(BRepTools_History)(), result, NO);
        }
        if (deadline->Fired()) throw Standard_Failure("planar support result deadline exceeded");
        OCCTShape *output = [OCCTShape new]; output->_shape = result;
        OS3DSetStatus(status, OCCTOpCodeOK, nil); return output;
    } catch (Standard_Failure &failure) {
        const char *message = failure.GetMessageString();
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
            message != nullptr && message[0] != 0 ? @(message) : @"planar-support shell native exception");
        return nil;
    } catch (...) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"planar-support shell exception"); return nil;
    }
}

+ (nullable OCCTShape *)regionShelledShape:(OCCTShape *)shape
                          openFaceIndices:(NSData *)openFaces
                                thickness:(double)thickness
                        regionFaceIndices:(NSData *)regionFaces
                        regionThicknesses:(NSData *)regionThicknesses
                                   status:(nullable OCCTOpStatus *)status
                                  history:(nullable OCCTShapeHistory *)history {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"invalid regional shell input");
    if (shape == nil || !std::isfinite(thickness) || fabs(thickness) <= 1e-6
        || openFaces.length % sizeof(int32_t) != 0 || regionFaces.length % sizeof(int32_t) != 0
        || regionThicknesses.length % sizeof(double) != 0) return nil;
    const size_t count = regionFaces.length / sizeof(int32_t);
    if (count > 128 || regionThicknesses.length / sizeof(double) != count
        || (count == 0 && openFaces.length == 0)) return nil;
    const auto *opens = (const int32_t *)openFaces.bytes;
    const auto *regions = (const int32_t *)regionFaces.bytes;
    const auto *walls = (const double *)regionThicknesses.bytes;
    try {
        int solids = 0;
        const TopoDS_Shape input = OS3DExtractSingleSolid(shape->_shape, solids);
        if (solids != 1 || input.IsNull() || !OS3DFiniteBounds(input)) return nil;
        TopTools_IndexedMapOfShape faces; TopExp::MapShapes(input, TopAbs_FACE, faces);
        std::set<int32_t> used;
        for (size_t i = 0; i < openFaces.length / sizeof(int32_t); ++i) {
            if (opens[i] < 1 || opens[i] > faces.Extent() || !used.insert(opens[i]).second) {
                OS3DSetStatus(status, OCCTOpCodeNoTargetMatched, @"an opening identity is missing or repeated"); return nil;
            }
        }
        for (size_t i = 0; i < count; ++i) {
            if (regions[i] < 1 || regions[i] > faces.Extent() || !used.insert(regions[i]).second
                || !std::isfinite(walls[i]) || fabs(walls[i]) <= 1e-6 || (walls[i] > 0) != (thickness > 0)) {
                OS3DSetStatus(status, OCCTOpCodeNoTargetMatched, @"a wall region is missing, repeated, open, or has an incompatible thickness"); return nil;
            }
        }
        int lastCode = -1;
        NSString *lastStage = @"no offset result";
        // Both joins use exact OCCT support surfaces. Each attempt owns a deep
        // topology+geometry copy; failed offset work cannot mutate undo/redo.
        for (GeomAbs_JoinType join : {GeomAbs_Intersection, GeomAbs_Arc}) {
            BRepBuilderAPI_Copy copy(input, Standard_True, Standard_False);
            if (!copy.IsDone() || copy.Shape().IsNull()) { lastStage = @"independent input copy"; continue; }
            lastStage = join == GeomAbs_Intersection ? @"OCCT intersection join" : @"OCCT arc join";
            BRepOffset_MakeOffset maker;
            maker.Initialize(copy.Shape(), -thickness, 1.0e-3, BRepOffset_Skin,
                count == 0 ? Standard_False : Standard_True, Standard_False, join, Standard_False, Standard_True);
            maker.AllowLinearization(Standard_False);
            for (size_t i = 0; i < openFaces.length / sizeof(int32_t); ++i)
                maker.AddFace(TopoDS::Face(copy.ModifiedShape(faces(opens[i]))));
            for (size_t i = 0; i < count; ++i)
                maker.SetOffsetOnFace(TopoDS::Face(copy.ModifiedShape(faces(regions[i]))), -walls[i]);
            TopoDS_Shape built;
            try {
                OS3DDeadlineProgress *deadline = new OS3DDeadlineProgress(kOS3DOpDeadlineSeconds);
                Handle(Message_ProgressIndicator) progress(deadline);
                if (openFaces.length > 0) {
                    OS3D_GUARDED(status, "regional shell", maker.MakeThickSolid(progress->Start()));
                } else {
                    OS3D_GUARDED(status, "regional shell offset", maker.MakeOffsetShape(progress->Start()));
                }
                if (deadline->Fired()) {
                    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"the regional shell exceeded the kernel deadline"); return nil;
                }
                lastCode = (int)maker.Error();
                if (!maker.IsDone() || maker.Shape().IsNull()) continue;
                built = maker.Shape();
            } catch (Standard_Failure &failure) {
                lastCode = -2;
                lastStage = [NSString stringWithFormat:@"%@ threw: %s", lastStage, failure.GetMessageString()];
                continue;
            }
            if (openFaces.length == 0) {
                // With no closing face MakeThickSolid can return the original.
                // Build an exact cavity with a non-destructive boolean instead.
                TopTools_ListOfShape args, tools;
                args.Append(thickness > 0 ? copy.Shape() : built);
                tools.Append(thickness > 0 ? built : copy.Shape());
                BRepAlgoAPI_Cut cut; cut.SetArguments(args); cut.SetTools(tools);
                cut.SetNonDestructive(Standard_True);
                OS3D_GUARDED(status, "regional shell cavity", cut.Build());
                if (!cut.IsDone() || cut.HasErrors()) { lastStage = @"OCCT cavity boolean"; continue; }
                built = cut.Shape();
            }
            int resultCount = 0;
            TopoDS_Shape result = OS3DExtractSingleSolid(built, resultCount);
            if (resultCount != 1 || result.IsNull()) { lastStage = @"result did not contain exactly one solid"; continue; }
            OS3DSetSameRangeOnNewEdges(result, copy.Shape());
            const double before = fabs(OS3DVolume(input)), after = fabs(OS3DVolume(result));
            if (!OS3DFiniteBounds(result) || !BRepCheck_Analyzer(result).IsValid()
                || !(before > 0 && after > 0 && std::isfinite(after))
                || (thickness > 0 && after >= before * (1 - 1e-9))) {
                lastStage = @"result validity, finite volume, or inward material-removal check"; continue;
            }
            if (history != nil) {
                std::vector<OS3DHistEdge> edges;
                TopTools_IndexedMapOfShape resultFaces; TopExp::MapShapes(result, TopAbs_FACE, resultFaces);
                for (Standard_Integer i = 1; i <= faces.Extent(); ++i) {
                    const TopoDS_Shape item = copy.ModifiedShape(faces(i));
                    // Offset history is on the owned copy. Rebind its genuine
                    // images to the original input identity before it dies.
                    if (resultFaces.Contains(item)) edges.push_back({item, 0, 0, (int32_t)i, 0});
                    if (openFaces.length == 0) continue; // cut ancestry is not guessed
                    for (int32_t relation : {1, 2}) {
                        const auto &list = relation == 1 ? maker.Modified(item) : maker.Generated(item);
                        for (TopTools_ListIteratorOfListOfShape it(list); it.More(); it.Next())
                            edges.push_back({it.Value(), 0, 0, (int32_t)i, relation});
                    }
                }
                OS3DFillHistory(history, edges, {input}, Handle(BRepTools_History)(), result, NO);
            }
            OCCTShape *out = [OCCTShape new]; out->_shape = result;
            OS3DSetStatus(status, OCCTOpCodeOK, nil); return out;
        }
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
            [NSString stringWithFormat:@"Regional shell failed at %@ (OCCT offset code %d); the original body was kept", lastStage, lastCode]);
        return nil;
    } catch (Standard_Failure &failure) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
            [NSString stringWithUTF8String:failure.GetMessageString()]); return nil;
    } catch (...) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"OCCT regional offset exception; the original body was kept"); return nil;
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
        TopoDS_Shape sourceInput = OS3DExtractSingleSolid(shape->_shape, inputSolids);
        if (sourceInput.IsNull()) sourceInput = shape->_shape;
        BRepBuilderAPI_Copy inputCopy(sourceInput, Standard_True, Standard_False);
        if (!inputCopy.IsDone() || inputCopy.Shape().IsNull()) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"shell could not obtain an independent input");
            return nil;
        }
        const TopoDS_Shape input = inputCopy.Shape();

        // Faces to open: those with a sample within tolerance of a picked point.
        // Empty selection => fully-enclosed hollow.
        TopTools_ListOfShape openFaces;
        TopTools_ListOfShape sourceOpenFaces;
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
            const auto chosen = OS3DNearestFaces(faceMap, pts, count, tolerance);
            for (Standard_Integer i : chosen) openFaces.Append(TopoDS::Face(faceMap(i)));
            TopTools_IndexedMapOfShape sourceFaces; TopExp::MapShapes(sourceInput, TopAbs_FACE, sourceFaces);
            for (Standard_Integer i = 1; i <= sourceFaces.Extent(); ++i) {
                const TopoDS_Shape copied = inputCopy.ModifiedShape(sourceFaces(i));
                if (chosen.count(faceMap.FindIndex(copied)) != 0) sourceOpenFaces.Append(sourceFaces(i));
            }
            if (sourceOpenFaces.Extent() != openFaces.Extent()) {
                OS3DSetStatus(status, OCCTOpCodeNoTargetMatched, @"shell opening lost its copied source identity");
                return nil;
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
        BOOL candidateWasHealed = NO;
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
            if (history != nil) OS3DCollectShellHistory(nullptr, sourceInput, inputCopy,
                Handle(BRepTools_History)(), histEdges);
        } else {
            TopoDS_Shape acceptedCandidate;
            NSString *candidateRefusal = @"no completed exact candidate";
            const double inputVolume = OS3DVolume(input);
            auto acceptCandidate = [&](BRepOffsetAPI_MakeThickSolid &maker) -> bool {
                try {
                    if (!maker.IsDone() || maker.Shape().IsNull()) {
                        candidateRefusal = @"OCCT did not complete the candidate"; return false;
                    }
                    int solids = 0;
                    const TopoDS_Shape single = OS3DExtractSingleSolid(maker.Shape(), solids);
                    if (solids != 1 || single.IsNull()) {
                        candidateRefusal = @"candidate is not one closed solid"; return false;
                    }
                    const TopoDS_Shape valid = OS3DHealAndValidate(single);
                    if (valid.IsNull()) {
                        candidateRefusal = @"candidate failed native validity"; return false;
                    }
                    const double volume = OS3DVolume(valid);
                    const bool unchanged = fabs(volume - inputVolume) <= inputVolume * 1e-9;
                    const bool wrongWay = outward ? volume <= inputVolume : volume >= inputVolume;
                    if (!std::isfinite(volume) || volume <= 0 || (inputVolume > 0 && (unchanged || wrongWay))) {
                        candidateRefusal = outward ? @"candidate added no material" : @"candidate removed no material";
                        return false;
                    }
                    acceptedCandidate = valid;
                    candidateWasHealed = !valid.IsSame(single);
                    return true;
                } catch (Standard_Failure &failure) {
                    const char *message = failure.GetMessageString();
                    candidateRefusal = message != nullptr && message[0] != 0 ? @(message) : @"candidate validation threw without a message";
                    return false;
                } catch (...) {
                    candidateRefusal = @"candidate validation threw"; return false;
                }
            };
            BRepOffsetAPI_MakeThickSolid mk;
            bool primaryThrew = false;
            NSString *primaryException = @"";
            try {
                mk.MakeThickSolidByJoin(input, openFaces, offset, 1.0e-3);
            } catch (Standard_Failure &failure) {
                primaryThrew = true;
                const char *message = failure.GetMessageString();
                primaryException = message != nullptr && message[0] != 0 ? @(message) : @"OCCT exception without a message";
            } catch (...) {
                primaryThrew = true; primaryException = @"native exception";
            }
            // Arc joins are OCCT's default and the robust choice on analytic
            // walls; a B-spline wall (a revolved traced profile) can fail
            // them and still offset with INTERSECTION joins. Try those
            // before refusing.
            BRepOffsetAPI_MakeThickSolid mkIntersection;
            BRepBuilderAPI_Copy intersectionCopy;
            // IsDone alone is insufficient: OCCT can return the original
            // solid for this opening. Reject it HERE so later joins still run.
            BRepOffsetAPI_MakeThickSolid *made = !primaryThrew && acceptCandidate(mk) ? &mk : nullptr;
            BRepBuilderAPI_Copy *madeCopy = &inputCopy;
            int code = -1;
            if (made == nullptr) {
                try { code = (int)mk.MakeOffset().Error(); } catch (...) {}
                if (primaryThrew && code == (int)BRepOffset_NoError) code = -2;
            }
            // A fillet's B-spline faces refuse every join (C0Geometry): split
            // the body where they are C0 and retry with arc joins. Intersection
            // joins on the split body did not heal (18.23, 2026-09-16).
            BRepOffsetAPI_MakeThickSolid mkSplit;
            TopoDS_Shape split;
            Handle(BRepTools_History) splitHistory;
            NSString *retryNote = primaryThrew ? [@", arc join: " stringByAppendingString:primaryException] : @"";
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
                        if (acceptCandidate(mkSplit)) {
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
            if (made == nullptr) {
                // A throwing first Arc join is still an unsuccessful attempt,
                // not permission to bypass the exact Intersection fallback.
                // Prefer OCCT's recommended adjacent-pair intersections, then
                // retain the previously supported all-parallels attempt.
                for (Standard_Boolean allParallels : {Standard_False, Standard_True}) {
                    try {
                        intersectionCopy.Perform(sourceInput, Standard_True, Standard_False);
                        if (!intersectionCopy.IsDone() || intersectionCopy.Shape().IsNull()) continue;
                        TopTools_ListOfShape copiedOpenFaces;
                        for (TopTools_ListIteratorOfListOfShape it(sourceOpenFaces); it.More(); it.Next())
                            copiedOpenFaces.Append(intersectionCopy.ModifiedShape(it.Value()));
                        mkIntersection.MakeThickSolidByJoin(
                            intersectionCopy.Shape(), copiedOpenFaces, offset, 1.0e-3, BRepOffset_Skin,
                            allParallels, Standard_False, GeomAbs_Intersection);
                        if (acceptCandidate(mkIntersection)) {
                            made = &mkIntersection; madeCopy = &intersectionCopy; break;
                        }
                        code = (int)mkIntersection.MakeOffset().Error();
                        retryNote = allParallels ? @", after all-parallels intersection join" : @", after adjacent intersection join";
                    } catch (Standard_Failure &failure) {
                        code = -2;
                        const char *message = failure.GetMessageString();
                        NSString *detail = message != nullptr && message[0] != 0 ? @(message) : @"OCCT exception without a message";
                        retryNote = [@", intersection join: " stringByAppendingString:detail];
                    } catch (...) {
                        code = -2; retryNote = @", intersection join: native exception";
                    }
                }
            }
            if (made == nullptr) {
                // Reuse the already checked indexed low-level OCCT builder.
                // Its RemoveIntEdges/linearization controls differ from the
                // legacy wrapper; an empty override list is a UNIFORM shell.
                TopTools_IndexedMapOfShape originalFaces;
                TopExp::MapShapes(sourceInput, TopAbs_FACE, originalFaces);
                std::vector<int32_t> openings;
                for (TopTools_ListIteratorOfListOfShape it(sourceOpenFaces); it.More(); it.Next()) {
                    const Standard_Integer index = originalFaces.FindIndex(it.Value());
                    if (index > 0) openings.push_back((int32_t)index);
                }
                OCCTOpStatus *indexedStatus = [OCCTOpStatus new];
                if (openings.size() == (size_t)sourceOpenFaces.Extent() && !openings.empty()) {
                    NSData *indices = [NSData dataWithBytes:openings.data() length:openings.size() * sizeof(int32_t)];
                    OCCTShape *indexed = [self regionShelledShape:shape openFaceIndices:indices
                        thickness:thickness regionFaceIndices:[NSData data] regionThicknesses:[NSData data]
                        status:indexedStatus history:history];
                    if (indexed != nil) {
                        const double indexedVolume = OS3DVolume(indexed->_shape);
                        const bool unchanged = fabs(indexedVolume - inputVolume) <= inputVolume * 1e-9;
                        const bool wrongWay = outward ? indexedVolume <= inputVolume : indexedVolume >= inputVolume;
                        if (std::isfinite(indexedVolume) && indexedVolume > 0
                            && !(inputVolume > 0 && (unchanged || wrongWay))) {
                            OS3DSetStatus(status, OCCTOpCodeOK, nil);
                            return indexed;
                        }
                        candidateRefusal = outward ? @"indexed candidate added no material" : @"indexed candidate removed no material";
                    }
                }
                if (indexedStatus.detail.length > 0)
                    retryNote = [retryNote stringByAppendingFormat:@"; indexed join: %@", indexedStatus.detail];
                // One proved special construction, after preserving every
                // existing successful offset/join path. No curved support is
                // offset here: only convex planar walls bound the cavity.
                OCCTOpStatus *supportStatus = [OCCTOpStatus new];
                OCCTShape *supported = OS3DPlanarSupportShell(sourceInput, sourceOpenFaces,
                    thickness, supportStatus, history);
                if (supported != nil) { OS3DSetStatus(status, OCCTOpCodeOK, nil); return supported; }
                if (supportStatus.detail.length > 0)
                    retryNote = [retryNote stringByAppendingFormat:@"; planar supports: %@", supportStatus.detail];
                retryNote = [retryNote stringByAppendingFormat:@"; last candidate: %@", candidateRefusal];
                // Say WHY: BRepOffset's own error code, so a refusal on a
                // curved wall can be told apart from a wall eating the body.
                static const char *const kOffsetErrors[] = {
                    "NoError", "UnknownError", "BadNormalsOnGeometry",
                    "C0Geometry", "NullOffset", "NotConnectedShell",
                    "CannotTrimEdges", "CannotFuseVertices", "CannotExtentEdge",
                    "UserBreak", "MixedConnectivity"};
                const char *name = (code >= 0 && code < 11) ? kOffsetErrors[code] : "?";
                OS3DSetStatus(status, OCCTOpCodeKernelRefused, code == -2
                    ? [NSString stringWithFormat:@"the wall thickness is out of range for this shape (OCCT offset exception%@)", retryNote]
                    : [NSString stringWithFormat:@"the wall thickness is out of range for this shape (OCCT offset: %s%@)", name, retryNote]);
                return nil;
            }
            built = acceptedCandidate;
            if (made == &mkSplit) OS3DSetSameRangeOnNewEdges(built, input);
            // Harvest before the maker dies with this scope.
            if (history != nil) {
                OS3DCollectShellHistory(made, sourceInput, *madeCopy,
                    made == &mkSplit ? splitHistory : Handle(BRepTools_History)(), histEdges);
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
            OS3DFillHistory(history, histEdges, {sourceInput},
                            Handle(BRepTools_History)(), valid,
                            /*truncatedByHeal*/ candidateWasHealed || !valid.IsSame(result));
        }
        OCCTShape *out = [OCCTShape new];
        out->_shape = valid;
        return out;
    } catch (Standard_Failure &e) {
        const char *message = e.GetMessageString();
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
            message != nullptr && message[0] != 0 ? @(message) : @"shell native exception without a message");
        return nil;
    } catch (...) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"kernel exception");
        return nil;
    }
}

+ (nullable NSData *)spurGearMeasurementsOfShape:(OCCTShape *)shape
                                    pitchRadius:(double)pitchRadius
                                         status:(nullable OCCTOpStatus *)status {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"invalid gear measurement input");
    if (shape == nil || !std::isfinite(pitchRadius) || pitchRadius <= 0) return nil;
    try {
        BRepBuilderAPI_Copy copy(shape->_shape, Standard_True, Standard_False);
        if (!copy.IsDone() || copy.Shape().IsNull()) return nil;
        const TopoDS_Shape owned = copy.Shape();
        if (!OS3DFiniteBounds(owned)) return nil;
        double lower = INFINITY, upper = -INFINITY, bore = 0;
        TopTools_IndexedMapOfShape faces, edges;
        TopExp::MapShapes(owned, TopAbs_FACE, faces); TopExp::MapShapes(owned, TopAbs_EDGE, edges);
        if (faces.Extent() > 4096 || edges.Extent() > 16384) return nil;
        for (Standard_Integer i = 1; i <= faces.Extent(); ++i) {
            const TopoDS_Face face = TopoDS::Face(faces(i)); BRepAdaptor_Surface surface(face);
            if (surface.GetType() == GeomAbs_Plane && fabs(surface.Plane().Axis().Direction().Z()) > 1-1e-10) {
                const double z = surface.Plane().Location().Z(); lower = std::min(lower,z); upper = std::max(upper,z);
            }
            if (surface.GetType() == GeomAbs_Cylinder) {
                const gp_Cylinder cylinder = surface.Cylinder(); const gp_Ax1 axis = cylinder.Axis();
                if (fabs(axis.Direction().Z()) < 1-1e-10 || hypot(axis.Location().X(),axis.Location().Y()) > 1e-6
                    || cylinder.Radius() >= pitchRadius) continue;
                gp_Pnt point; gp_Vec du,dv;
                surface.D1((surface.FirstUParameter()+surface.LastUParameter())/2,
                    (surface.FirstVParameter()+surface.LastVParameter())/2,point,du,dv);
                gp_Vec normal = du.Crossed(dv); if (face.Orientation()==TopAbs_REVERSED) normal.Reverse();
                if (normal.Dot(gp_Vec(point.X(),point.Y(),0)) < 0) bore = std::max(bore,cylinder.Radius());
            }
        }
        if (!std::isfinite(lower) || !std::isfinite(upper) || upper-lower <= 0) return nil;
        const double middle = (lower+upper)/2;
        OS3DDeadlineProgress *deadline = new OS3DDeadlineProgress(kOS3DOpDeadlineSeconds);
        Handle(Message_ProgressIndicator) progress(deadline);
        const TopoDS_Edge pitch = BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(gp_Pnt(0,0,middle),gp_Dir(0,0,1)),pitchRadius));
        TopTools_ListOfShape arguments, tools; arguments.Append(owned); tools.Append(pitch);
        BRepAlgoAPI_Common common; common.SetArguments(arguments); common.SetTools(tools);
        common.SetNonDestructive(Standard_True); common.SetRunParallel(Standard_False);
        common.SetFuzzyValue(0.0);
        OS3D_GUARDED(status,"gear pitch-circle intersection",common.Build(progress->Start()));
        if (deadline->Fired() || !common.IsDone() || common.HasErrors() || common.HasWarnings()) {
            OS3DSetStatus(status,OCCTOpCodeKernelRefused,@"gear pitch-circle common failed or exceeded its deadline");return nil;
        }
        TopTools_IndexedMapOfShape contactEdges, vertices;
        TopExp::MapShapes(common.Shape(),TopAbs_EDGE,contactEdges);
        if (contactEdges.Extent() < 1 || contactEdges.Extent() > 512) return nil;
        std::vector<int> parent((size_t)contactEdges.Extent()), owners;
        for (int i=0;i<(int)parent.size();++i) parent[(size_t)i]=i;
        auto root = [&](int i) { while(parent[(size_t)i]!=i) { parent[(size_t)i]=parent[(size_t)parent[(size_t)i]]; i=parent[(size_t)i]; } return i; };
        for (Standard_Integer i=1;i<=contactEdges.Extent();++i) {
            for(TopExp_Explorer v(contactEdges(i),TopAbs_VERTEX);v.More();v.Next()) {
                const int index=vertices.Add(v.Current());
                if((size_t)index>owners.size()) owners.push_back((int)i-1);
                else parent[(size_t)root((int)i-1)]=root(owners[(size_t)index-1]);
            }
        }
        // A closed circle can split at its parameter seam into distinct
        // native vertices at the SAME geometric endpoint. Join only within
        // the actual vertex tolerances; never merge by expected tooth count.
        for(Standard_Integer i=1;i<=vertices.Extent();++i) {
            const TopoDS_Vertex a=TopoDS::Vertex(vertices(i));const gp_Pnt point=BRep_Tool::Pnt(a);
            if(!std::isfinite(BRep_Tool::Tolerance(a)) || BRep_Tool::Tolerance(a)>1e-5) {
                OS3DSetStatus(status,OCCTOpCodeKernelRefused,@"gear contact intersection exceeded its native tolerance");return nil;
            }
            for(Standard_Integer j=1;j<i;++j) {
                const TopoDS_Vertex b=TopoDS::Vertex(vertices(j));
                const double tolerance=std::max({Precision::Confusion(),BRep_Tool::Tolerance(a),BRep_Tool::Tolerance(b)});
                if(point.Distance(BRep_Tool::Pnt(b))<=tolerance)
                    parent[(size_t)root(owners[(size_t)i-1])]=root(owners[(size_t)j-1]);
            }
        }
        std::map<int,double> contactLengths;
        for(Standard_Integer i=1;i<=contactEdges.Extent();++i) {
            BRepAdaptor_Curve curve(TopoDS::Edge(contactEdges(i)));
            if(curve.GetType()!=GeomAbs_Circle || fabs(curve.Circle().Radius()-pitchRadius)>1e-6) return nil;
            GProp_GProps length; BRepGProp::LinearProperties(contactEdges(i),length);
            if(!(length.Mass()>0)) return nil;
            contactLengths[root((int)i-1)]+=length.Mass();
        }
        double sum=0,minimum=INFINITY,maximum=0;
        for(const auto &entry:contactLengths) { sum+=entry.second;minimum=std::min(minimum,entry.second);maximum=std::max(maximum,entry.second); }
        const int teeth=(int)contactLengths.size();
        if(teeth<1) return nil;
        IntCurvesFace_ShapeIntersector ray;
        ray.Load(owned,Precision::Confusion());
        auto radiusAt = [&](double angle) {
            ray.Perform(gp_Lin(gp_Pnt(0,0,middle),gp_Dir(cos(angle),sin(angle),0)),0,pitchRadius*4);
            if(!ray.IsDone()) throw Standard_Failure("gear radial intersection failed");
            double radius=0;for(Standard_Integer i=1;i<=ray.NbPnt();++i) radius=std::max(radius,ray.WParameter(i));
            if(!(radius>0)) throw Standard_Failure("gear radial intersection has no material");return radius;
        };
        double tip=0,dedendum=0;
        OS3D_GUARDED(status,"gear tip ray intersection",tip=radiusAt(0));
        OS3D_GUARDED(status,"gear root ray intersection",dedendum=radiusAt(M_PI/(double)teeth));
        // Use an ACTUAL contact endpoint on a polynomial flank. The circle's
        // seam vertex can lie inside a tooth and must never be used as a flank.
        double pressure=-1;
        for(Standard_Integer v=1;v<=vertices.Extent() && pressure<0;++v) {
            const gp_Pnt point=BRep_Tool::Pnt(TopoDS::Vertex(vertices(v)));
            for(Standard_Integer f=1;f<=faces.Extent();++f) {
                if(deadline->Fired()) return nil;
                const TopoDS_Face face=TopoDS::Face(faces(f));BRepAdaptor_Surface adaptor(face);
                if(adaptor.GetType()!=GeomAbs_SurfaceOfExtrusion && adaptor.GetType()!=GeomAbs_BSplineSurface) continue;
                BRepExtrema_DistShapeShape distance(BRepBuilderAPI_MakeVertex(point).Vertex(),face);
                if(!distance.IsDone() || distance.NbSolution()==0 || distance.Value()>1e-6) continue;
                TopLoc_Location location;Handle(Geom_Surface) surface=BRep_Tool::Surface(face,location);
                GeomAPI_ProjectPointOnSurf projection(point.Transformed(location.Transformation().Inverted()),surface);
                if(projection.NbPoints()==0) continue;
                Standard_Real u=0,w=0;projection.LowerDistanceParameters(u,w);
                gp_Pnt actual;gp_Vec du,dv;adaptor.D1(u,w,actual,du,dv);
                const gp_Vec normal=du.Crossed(dv);gp_Vec tangent(-normal.Y(),normal.X(),0),radial(point.X(),point.Y(),0);
                if(tangent.SquareMagnitude()<1e-20 || radial.SquareMagnitude()<1e-20) continue;
                tangent.Normalize();radial.Normalize();
                pressure=acos(std::max(0.0,std::min(1.0,fabs(tangent.Dot(radial)))))*180/M_PI;break;
            }
        }
        int polynomialEdges=0;
        for(Standard_Integer i=1;i<=edges.Extent();++i) {
            BRepAdaptor_Curve curve(TopoDS::Edge(edges(i)));const double a=curve.FirstParameter(),b=curve.LastParameter();
            const gp_Pnt first=curve.Value(a),last=curve.Value(b);
            if(fabs(first.Z()-lower)>1e-7 || fabs(last.Z()-lower)>1e-7 || fabs(curve.Value((a+b)/2).Z()-lower)>1e-7) continue;
            if(curve.GetType()==GeomAbs_BezierCurve && curve.Bezier()->Degree()==3) ++polynomialEdges;
            else if(curve.GetType()==GeomAbs_BSplineCurve && curve.BSpline()->Degree()==3 && curve.BSpline()->NbKnots()==2) ++polynomialEdges;
        }
        if(pressure<0 || deadline->Fired()) {
            OS3DSetStatus(status,OCCTOpCodeKernelRefused,@"gear actual flank tangent was unavailable or exceeded its deadline");return nil;
        }
        const double values[12]={upper-lower,tip,dedendum,bore,(double)teeth,sum/teeth,minimum,maximum,
            pressure,OS3DVolume(owned),(double)polynomialEdges,OS3DMaxTolerance(owned)};
        for(double value:values) if(!std::isfinite(value)) return nil;
        OS3DSetStatus(status,OCCTOpCodeOK,nil);return [NSData dataWithBytes:values length:sizeof(values)];
    } catch(Standard_Failure &failure) {
        const char *message=failure.GetMessageString();OS3DSetStatus(status,OCCTOpCodeKernelRefused,
            message && message[0] ? @(message) : @"gear native measurement failed");return nil;
    } catch(...) { OS3DSetStatus(status,OCCTOpCodeKernelRefused,@"gear native measurement exception");return nil; }
}

+ (nullable NSData *)gearBoundaryDistancesOfShape:(OCCTShape *)shape
                                         points:(NSData *)points
                                    faceIndices:(NSData *)faceIndices
                                         status:(nullable OCCTOpStatus *)status {
    OS3DSetStatus(status,OCCTOpCodeKernelRefused,@"invalid gear witness input");
    if(shape==nil || points.length%(3*sizeof(double)) || faceIndices.length%sizeof(int32_t)) return nil;
    const size_t count=points.length/(3*sizeof(double)),facesCount=faceIndices.length/sizeof(int32_t);
    if(count<1 || count>256 || facesCount<1 || facesCount>128) return nil;
    const auto *coordinates=(const double *)points.bytes;const auto *indices=(const int32_t *)faceIndices.bytes;
    try {
        BRepBuilderAPI_Copy copy(shape->_shape,Standard_True,Standard_False);
        if(!copy.IsDone() || copy.Shape().IsNull()) return nil;
        TopTools_IndexedMapOfShape originals;TopExp::MapShapes(shape->_shape,TopAbs_FACE,originals);
        BRep_Builder builder;TopoDS_Compound boundary;builder.MakeCompound(boundary);
        std::set<int32_t> used;
        for(size_t i=0;i<facesCount;++i) {
            if(indices[i]<1 || indices[i]>originals.Extent() || !used.insert(indices[i]).second) return nil;
            const TopoDS_Shape face=copy.ModifiedShape(originals(indices[i]));if(face.IsNull()) return nil;builder.Add(boundary,face);
        }
        OS3DDeadlineProgress *deadline=new OS3DDeadlineProgress(kOS3DOpDeadlineSeconds);
        Handle(Message_ProgressIndicator) progress(deadline);
        std::vector<double> distances;
        for(size_t i=0;i<count;++i) {
            const double x=coordinates[3*i],y=coordinates[3*i+1],z=coordinates[3*i+2];
            if(!std::isfinite(x)||!std::isfinite(y)||!std::isfinite(z)||deadline->Fired()) return nil;
            BRepExtrema_DistShapeShape distance;
            distance.LoadS1(BRepBuilderAPI_MakeVertex(gp_Pnt(x,y,z)).Vertex());distance.LoadS2(boundary);
            OS3D_GUARDED(status,"gear native boundary witness",distance.Perform(progress->Start()));
            if(deadline->Fired()||!distance.IsDone()||distance.NbSolution()==0||!std::isfinite(distance.Value())) return nil;
            distances.push_back(distance.Value());
        }
        OS3DSetStatus(status,OCCTOpCodeOK,nil);return [NSData dataWithBytes:distances.data() length:distances.size()*sizeof(double)];
    } catch(Standard_Failure &failure) {
        const char *message=failure.GetMessageString();OS3DSetStatus(status,OCCTOpCodeKernelRefused,
            message&&message[0]?@(message):@"gear witness failed");return nil;
    } catch(...) { OS3DSetStatus(status,OCCTOpCodeKernelRefused,@"gear witness exception");return nil; }
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

+ (BOOL)shapeContainsSolid:(OCCTShape *)shape {
    if (shape == nil || shape->_shape.IsNull()) return NO;
    // The caller may be classifying a STORED handle (document load). The
    // bridge's reader/healer already refused unreadable blobs, but a topology
    // exception must still never escape into Swift/ObjC: contain it exactly
    // like the adjacent bridge queries and classify an unreadable shape as
    // "no solid" (the caller then keeps it as render-only/exact-surface rather
    // than crashing or trusting it as a solid).
    try {
        for (TopExp_Explorer ex(shape->_shape, TopAbs_SOLID); ex.More(); ex.Next()) {
            return YES;
        }
        return NO;
    } catch (...) {
        return NO;
    }
}

// Shared IGES writer for the product route and the DEBUG fixture route.
//
// BRep mode (1) keeps a closed solid an IGES BRep solid (ManifoldSolid) and
// writes an open shell/face as exact BRep surface geometry, so a read-back of
// either still carries the analytic geometry. Face mode (0) decomposes a
// solid into trimmed surfaces — used only to author surface-only fixtures.
// Units are millimetres, matching the document model.
static BOOL OS3DWriteIGES(NSArray<OCCTShape *> *shapes, NSString *path, BOOL brepMode) {
    if (shapes.count == 0 || path.length == 0) return NO;
    try {
        IGESControl_Writer writer("MM", brepMode ? 1 : 0);
        for (OCCTShape *s in shapes) {
            if (s == nil || s->_shape.IsNull()) continue;
            if (!writer.AddShape(s->_shape)) return NO;
        }
        return writer.Write(path.fileSystemRepresentation) ? YES : NO;
    } catch (...) {
        return NO;
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

// MARK: - IGES import (spec §12.1 / §12.2)

static NSInteger OS3DFaceCount(const TopoDS_Shape &shape) {
    NSInteger count = 0;
    for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) ++count;
    return count;
}

// The file has already been staged at `path`. Reads it through OCCT's IGES
// reader and fills the output arrays by classification:
//
// - A root containing at least one TopAbs_SOLID is emitted as its solids,
//   one handle each (the same per-root split `readSTEPFromPath:` does). Only
//   the solids are kept: the root's other children (if any) are faces OF
//   those solids and would duplicate their geometry.
// - Any other root — a shell, an isolated face, a compound of faces — is
//   emitted WHOLE to the surface list. IGES exports commonly carry surfaces
//   only, and a shell is not a solid: downstream boolean/blend/shell ops are
//   not valid for it, so it must not enter the solid list.
//
// Every candidate passes the same finite-bounds gate and one-heal
// (`ShapeFix_Shape`) validation the STEP import uses, so a corrupt root
// cannot seed a body. Returns NO when the reader refused the file; an empty
// model then reads as `readSucceeded` with `rootCount == 0`.
static BOOL OS3DReadIGES(const char *path,
                         NSMutableArray<OCCTShape *> *solids,
                         NSMutableArray<OCCTShape *> *surfaces,
                         NSMutableArray<NSNumber *> *solidFaceCounts,
                         NSMutableArray<NSNumber *> *surfaceFaceCounts,
                         NSInteger *rootCount) {
    // The reader's own constructor registers the IGES norm; the explicit
    // call documents the dependency and is a no-op after the first time.
    IGESControl_Controller::Init();
    IGESControl_Reader reader;
    if (reader.ReadFile(path) != IFSelect_RetDone) return NO;
    reader.TransferRoots();
    *rootCount = (NSInteger)reader.NbShapes();
    for (Standard_Integer i = 1; i <= reader.NbShapes(); ++i) {
        const TopoDS_Shape shape = reader.Shape(i);
        if (shape.IsNull() || !OS3DFiniteBounds(shape)) continue;
        TopExp_Explorer solidExplorer(shape, TopAbs_SOLID);
        if (solidExplorer.More()) {
            for (; solidExplorer.More(); solidExplorer.Next()) {
                const TopoDS_Shape valid = OS3DHealAndValidate(solidExplorer.Current());
                if (valid.IsNull()) continue;
                OCCTShape *w = [OCCTShape new];
                w->_shape = valid;
                [solids addObject:w];
                [solidFaceCounts addObject:@(OS3DFaceCount(valid))];
            }
        } else {
            const TopoDS_Shape valid = OS3DHealAndValidate(shape);
            if (valid.IsNull()) continue;
            OCCTShape *w = [OCCTShape new];
            w->_shape = valid;
            [surfaces addObject:w];
            [surfaceFaceCounts addObject:@(OS3DFaceCount(valid))];
        }
    }
    return YES;
}

+ (nullable OCCTIGESImport *)readIGESFromData:(NSData *)data {
    if (data.length == 0) return nil;
    // The IGES work library implements ReadFile only (its inherited
    // ReadStream is the default "unsupported" stub), so the caller's bytes
    // are staged in the system temporary directory for the read and removed
    // again on every path out. STEP import does the same staging on the
    // Swift side; keeping it here lets Swift hand over the original bytes.
    NSString *name = [NSString stringWithFormat:@"floe-iges-%@.igs",
                      [NSUUID UUID].UUIDString];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    if (![data writeToFile:path atomically:YES]) return nil;

    NSMutableArray<OCCTShape *> *solids = [NSMutableArray array];
    NSMutableArray<OCCTShape *> *surfaces = [NSMutableArray array];
    NSMutableArray<NSNumber *> *solidFaceCounts = [NSMutableArray array];
    NSMutableArray<NSNumber *> *surfaceFaceCounts = [NSMutableArray array];
    NSInteger rootCount = 0;
    BOOL readOK = NO;
    BOOL threw = NO;
    try {
        readOK = OS3DReadIGES(path.fileSystemRepresentation, solids, surfaces,
                              solidFaceCounts, surfaceFaceCounts, &rootCount);
    } catch (...) {
        threw = YES;
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    if (threw) return nil;

    OCCTIGESImport *result = [OCCTIGESImport new];
    result->_solids = solids;
    result->_surfaces = surfaces;
    result->_solidFaceCounts = solidFaceCounts;
    result->_surfaceFaceCounts = surfaceFaceCounts;
    result->_readSucceeded = readOK;
    result->_rootCount = readOK ? rootCount : 0;
    return result;
}

+ (BOOL)writeIGESShapes:(NSArray<OCCTShape *> *)shapes toPath:(NSString *)path {
    // Product IGES interchange: exact B-rep only, never a mesh substitute.
    // The caller (IGESKit) has already selected bodies with an exact B-rep
    // solid or open surface; this bridge function deliberately does not
    // triangulate or "repair" that decision. Millimetres and BRep mode match
    // the document model and keep a round-trip analytic.
    return OS3DWriteIGES(shapes, path, YES);
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
        OS3DVolumeIntegration volumeIntegration = OS3DVolumeIntegration::SpanKronrod;
        report[@"volumeMM3"] = @(OS3DVolume(root, &volumeIntegration));
        report[@"volumeIntegration"] = volumeIntegration == OS3DVolumeIntegration::AdaptiveGauss
            ? @"occt-adaptive-gauss" : @"occt-kronrod-spans";
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
// An orientation prefix is a reference only in a TShapes reference list;
// signed curve parameters/vertex coordinates are ordinary numbers.
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
    bool inTShapes = false;
    bool referenceLine = false;
    while (i < length) {
        if (isspace((unsigned char)bytes[i])) {
            if (bytes[i] == '\n' || bytes[i] == '\r') {
                atLineStart = true;
                referenceLine = false;
            }
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
            // The pinned ASCII writer ends every subshape-reference list
            // with '*'. Other TShapes lines also contain signed coordinates.
            long long lineEnd = i;
            while (lineEnd < length && bytes[lineEnd] != '\n' && bytes[lineEnd] != '\r') ++lineEnd;
            while (lineEnd > start && isspace((unsigned char)bytes[lineEnd - 1])) --lineEnd;
            referenceLine = inTShapes && lineEnd > start && bytes[lineEnd - 1] == '*';
            for (const char *section : kSections) {
                if (tokenLen == (long long)strlen(section)
                    && memcmp(bytes + start, section, (size_t)tokenLen) == 0) {
                    strict = true;
                    inTShapes = strcmp(section, "TShapes") == 0;
                    referenceLine = false;
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
        const bool markedRef = bytes[p] == '*' || bytes[p] == '+'
            || (referenceLine && bytes[p] == '-');
        // Trimmed curves produced by a real radial edit contain the valid
        // parameter range "8 -10000000 10000000". Its negative bound must
        // use the coordinate ceiling, never the blob-length reference bound.
        if (markedRef || bytes[p] == '-') ++p;
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

+ (BOOL)debugWriteIGESShapes:(NSArray<OCCTShape *> *)shapes
                      toPath:(NSString *)path
                    brepMode:(BOOL)brepMode {
    return OS3DWriteIGES(shapes, path, brepMode);
}

+ (nullable OCCTShape *)debugStandaloneFaceFrom:(OCCTShape *)shape {
    if (shape == nil || shape->_shape.IsNull()) return nil;
    try {
        TopExp_Explorer ex(shape->_shape, TopAbs_FACE);
        if (!ex.More()) return nil;
        OCCTShape *out = [OCCTShape new];
        out->_shape = ex.Current();
        return out;
    } catch (...) {
        return nil;
    }
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

+ (nullable OCCTShape *)independentCopyForSerialization:(OCCTShape *)shape {
    if (shape == nil) return nil;
    try {
        // copyGeom Standard_True: the copy owns its curves/surfaces too, so
        // NOTHING is shared with the live handle — the snapshot stays valid
        // no matter what the main-actor kernel does to the original next
        // (tessellation writes the shared TShape; undo snapshots and identity
        // transforms alias handles). copyMesh
        // Standard_False: triangulation is render cache and is never
        // persisted (serializedShape: writes withTriangles = Standard_False),
        // so copying it would be pure cost.
        BRepBuilderAPI_Copy copy(shape->_shape,
                                 /*copyGeom*/ Standard_True,
                                 /*copyMesh*/ Standard_False);
        if (!copy.IsDone() || copy.Shape().IsNull()) return nil;
        OCCTShape *out = [OCCTShape new];
        out->_shape = copy.Shape();
        return out;
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

+ (OCCTRenderMesh *)snapshotRenderMeshFromShape:(OCCTShape *)shape
                       angularDeflection:(double)angularDeflection
                        linearDeflection:(double)linearDeflection {
    if (shape == nil) return EmptyRenderMesh();
    try {
        // Even a cached second mesh marks live wires Checked. That flag is
        // serialized, so a naming query must not run the mesher on an undo
        // snapshot. Own the geometry and use the copier's actual ancestry;
        // copied and live face ordinals are never assumed to be equal.
        BRepBuilderAPI_Copy copy(shape->_shape, Standard_True, Standard_False);
        if (!copy.IsDone() || copy.Shape().IsNull()) return EmptyRenderMesh();
        TopTools_IndexedMapOfShape originalFaces, copiedFaces;
        TopExp::MapShapes(shape->_shape, TopAbs_FACE, originalFaces);
        TopExp::MapShapes(copy.Shape(), TopAbs_FACE, copiedFaces);
        if (originalFaces.IsEmpty() || originalFaces.Extent() != copiedFaces.Extent())
            return EmptyRenderMesh();
        std::vector<uint32_t> originals(copiedFaces.Extent() + 1, 0);
        for (Standard_Integer index = 1; index <= originalFaces.Extent(); ++index) {
            const TopoDS_Shape mapped = copy.ModifiedShape(originalFaces(index));
            const Standard_Integer copied = copiedFaces.FindIndex(mapped);
            if (copied <= 0 || originals[copied] != 0) return EmptyRenderMesh();
            originals[copied] = static_cast<uint32_t>(index);
        }
        OCCTRenderMesh *mesh = TessellateShape(copy.Shape(), linearDeflection, angularDeflection);
        const NSUInteger count = mesh.faceIndices.length / sizeof(uint32_t);
        if (count != mesh.triangleCount) return EmptyRenderMesh();
        const uint32_t *channel = static_cast<const uint32_t *>(mesh.faceIndices.bytes);
        std::vector<uint32_t> translated;
        translated.reserve(count);
        for (NSUInteger index = 0; index < count; ++index) {
            const uint32_t copied = channel[index];
            if (copied == 0 || copied >= originals.size() || originals[copied] == 0)
                return EmptyRenderMesh();
            translated.push_back(originals[copied]);
        }
        mesh->_faceIndices = [NSData dataWithBytes:translated.data()
                                           length:translated.size() * sizeof(uint32_t)];
        return mesh;
    } catch (...) {
        return EmptyRenderMesh();
    }
}


// M17: surface construction never uses rendering meshes. Shape diagnostics
// count real one-sided edges; a failed closure inspection cannot default to 0.
static NSInteger OS3DSurfaceFreeEdges(const TopoDS_Shape &shape) {
    TopTools_IndexedDataMapOfShapeListOfShape ancestors;
    TopExp::MapShapesAndAncestors(shape, TopAbs_EDGE, TopAbs_FACE, ancestors);
    NSInteger free = 0;
    for (Standard_Integer i = 1; i <= ancestors.Extent(); ++i) {
        const TopoDS_Edge edge = TopoDS::Edge(ancestors.FindKey(i));
        if (BRep_Tool::Degenerated(edge)) continue;
        TopTools_IndexedMapOfShape distinct;
        for (TopTools_ListIteratorOfListOfShape it(ancestors.FindFromIndex(i)); it.More(); it.Next())
            distinct.Add(it.Value());
        if (distinct.Extent() == 1 && !BRep_Tool::IsClosed(edge, TopoDS::Face(distinct(1)))) ++free;
        else if (distinct.Extent() != 2 && distinct.Extent() != 1) return -1;
    }
    return free;
}
static NSInteger OS3DSurfaceCount(const TopoDS_Shape &shape, TopAbs_ShapeEnum kind) {
    TopTools_IndexedMapOfShape map;
    TopExp::MapShapes(shape, kind, map);
    return map.Extent();
}
// Shared exact trim admission, used by execution and native UI discovery.
static bool OS3DSurfaceTrimDomain(const TopoDS_Face &face,double &u0,double &u1,double &v0,double &v1) {
    for (TopExp_Explorer edge(face,TopAbs_EDGE);edge.More();edge.Next()) {
        Standard_Real first,last;
        Handle(Geom2d_Curve) curve=BRep_Tool::CurveOnSurface(TopoDS::Edge(edge.Current()),face,first,last);
        Handle(Geom2d_TrimmedCurve) trim=Handle(Geom2d_TrimmedCurve)::DownCast(curve);
        if (!trim.IsNull()) curve=trim->BasisCurve();
        bool certified=!Handle(Geom2d_Line)::DownCast(curve).IsNull();
        auto isoPoles=[&](const auto &spline) {
            if (spline.IsNull()) return false;
            const gp_Pnt2d first=spline->Pole(1);bool sameU=true,sameV=true;
            for (Standard_Integer i=2;i<=spline->NbPoles();++i) {
                sameU=sameU && std::abs(spline->Pole(i).X()-first.X()) < 1e-12;
                sameV=sameV && std::abs(spline->Pole(i).Y()-first.Y()) < 1e-12;
            }
            return sameU || sameV;
        };
        certified=certified || isoPoles(Handle(Geom2d_BSplineCurve)::DownCast(curve))
            || isoPoles(Handle(Geom2d_BezierCurve)::DownCast(curve));
        if (!certified) return false;
    }
    return OS3DIsoRectangularDomain(face,u0,u1,v0,v1);
}

static OCCTShape *OS3DSurfaceResult(const TopoDS_Shape &shape, bool solid,
                                   double tolerance, OCCTOpStatus *status) {
    if (shape.IsNull()) {
        OS3DSetStatus(status,OCCTOpCodeInvalidResult,@"The surface builder returned an empty shape.");return nil;
    }
    const bool valid=OS3DIsValid(shape);
    const NSInteger faceCount=OS3DFaceCount(shape);
    const double maxTolerance=OS3DMaxTolerance(shape);
    const double allowed = tolerance * 10;
    // Offset/repair and decimal-to-binary multiplication can round at the
    // same engineering bound. Account only for four relative machine
    // epsilons (not a larger mm tolerance); validity/closure stay unchanged.
    const double arithmeticSlack = 4.0 * std::numeric_limits<double>::epsilon() * std::abs(allowed);
    const double roundedAllowed = allowed + arithmeticSlack;
    if (!valid || faceCount == 0 || !std::isfinite(maxTolerance) || maxTolerance > roundedAllowed) {
        OS3DSetStatus(status,OCCTOpCodeInvalidResult,[NSString stringWithFormat:
            @"Surface validation failed: valid=%d, faces=%ld, max_tolerance=%.17g mm, allowed=%.17g mm.",
            valid,(long)faceCount,maxTolerance,allowed]);
        return nil;
    }
    // BRep bounds must be finite. Do not allow the underlying infinite support
    // surface of a face to become the stored, unbounded result.
    Bnd_Box box; BRepBndLib::Add(shape, box);
    if (box.IsVoid() || box.IsOpen()) return nil;
    Standard_Real x0,y0,z0,x1,y1,z1; box.Get(x0,y0,z0,x1,y1,z1);
    for (double value : {x0,y0,z0,x1,y1,z1}) if (!std::isfinite(value)) return nil;
    if (OS3DSurfaceFreeEdges(shape) < 0) return nil;
    const NSInteger solids = OS3DSurfaceCount(shape, TopAbs_SOLID);
    if ((solid && (solids != 1 || OS3DSurfaceFreeEdges(shape) != 0)) || (!solid && solids != 0)) {
        OS3DSetStatus(status, OCCTOpCodeInvalidResult, @"The exact result has the wrong solid or closure topology.");
        return nil;
    }
    if (!solid && OS3DSurfaceFreeEdges(shape) == 0) {
        if (OS3DSurfaceCount(shape,TopAbs_SHELL) != 1) return nil;
        TopExp_Explorer shells(shape,TopAbs_SHELL);
        BRepBuilderAPI_MakeSolid mk(TopoDS::Shell(shells.Current()));
        if (!mk.IsDone()) return nil;
        TopoDS_Solid closed=mk.Solid();
        if (!BRepLib::OrientClosedSolid(closed) || !OS3DIsValid(closed)) return nil;
        GProp_GProps check; BRepGProp::VolumeProperties(closed,check);
        if (!std::isfinite(check.Mass()) || check.Mass() <= tolerance*tolerance*tolerance) return nil;
    }
    if (solid) {
        GProp_GProps props; BRepGProp::VolumeProperties(shape, props);
        if (!std::isfinite(props.Mass()) || props.Mass() <= tolerance*tolerance*tolerance) return nil;
    }
    OCCTShape *out = [OCCTShape new]; out->_shape = shape;
    OS3DSetStatus(status, OCCTOpCodeOK, @"Exact geometry validated.");
    return out;
}

+ (nullable OCCTShape *)surfaceLoftWithCurves:(NSArray<NSArray<NSData *> *> *)curves
                                  reversed:(NSArray<NSArray<NSNumber *> *> *)reversed
                                     bases:(NSArray<OCCTPlaneBasis *> *)bases
                                     ruled:(BOOL)ruled tolerance:(double)tolerance
                                    status:(OCCTOpStatus *)status {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"The open sections could not form a surface.");
    if (!std::isfinite(tolerance) || tolerance < 1e-7 || tolerance > 1e-3
        || curves.count < 2 || curves.count > 64 || bases.count != curves.count
        || reversed.count != curves.count) return nil;
    OS3DSignalScope signalScope;
    try {
        OCC_CATCH_SIGNALS
        Handle(OS3DDeadlineProgress) deadline=new OS3DDeadlineProgress(kOS3DOpDeadlineSeconds);
        BRepOffsetAPI_ThruSections mk(Standard_False, ruled, tolerance);
        // Input correspondence is authored, never re-guessed after an edit.
        mk.CheckCompatibility(Standard_False);
        NSUInteger total = 0;
        for (NSUInteger i=0; i<curves.count; ++i) {
            if (curves[i].count == 0 || curves[i].count > 256 || curves[i].count != curves[0].count
                || reversed[i].count != curves[i].count || (total += curves[i].count) > 2048) return nil;
            BRepBuilderAPI_MakeWire wire;
            gp_Pnt previous, firstPoint; bool hasPrevious = false;
            for (NSUInteger j=0; j<curves[i].count; ++j) {
                Handle(Geom_Curve) c = OS3DSketchCurveDefinition(curves[i][j], false);
                if (c.IsNull()) return nil;
                BRepBuilderAPI_MakeEdge me(c); if (!me.IsDone()) return nil;
                TopoDS_Edge edge = me.Edge();
                if (reversed[i][j].boolValue) edge.Reverse();
                TopoDS_Vertex a,b; TopExp::Vertices(edge,a,b,Standard_True);
                if (a.IsNull() || b.IsNull()) return nil;
                const gp_Pnt pa = BRep_Tool::Pnt(a), pb = BRep_Tool::Pnt(b);
                if (hasPrevious && previous.Distance(pa) > tolerance) {
                    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"The authored open-section edge order no longer connects."); return nil;
                }
                if (!hasPrevious) firstPoint = pa;
                previous = pb; hasPrevious = true;
                wire.Add(edge); if (!wire.IsDone() || deadline->Fired()) return nil;
            }
            if (firstPoint.Distance(previous) <= tolerance) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"The section is closed; use solid loft for a closed profile."); return nil;
            }
            TopoDS_Shape placed = BRepBuilderAPI_Transform(wire.Wire(), OS3DBasisTransform(bases[i]), Standard_True).Shape();
            mk.AddWire(TopoDS::Wire(placed));
        }
        OS3D_GUARDED(status,"surface loft",mk.Build(deadline->Start()));
        if (!mk.IsDone() || deadline->Fired()) return nil;
        return OS3DSurfaceResult(mk.Shape(), false, tolerance, status);
    } catch (Standard_Failure &failure) {
        OS3DSetStatus(status,OCCTOpCodeKernelRefused,OS3DCrashMessage("surface loft",failure.GetMessageString()));return nil;
    } catch (...) { return nil; }
}

+ (NSDictionary<NSString *, id> *)surfaceDiagnostics:(OCCTShape *)shape {
    OS3DSignalScope signalScope;
    try {
        OCC_CATCH_SIGNALS
        if (shape->_shape.IsNull()) return @{@"error":@"Null surface."};
        const auto &s = shape->_shape;
        Handle(OS3DDeadlineProgress) deadline=new OS3DDeadlineProgress(kOS3DKernelDeadlineSeconds);
        if (OS3DSurfaceCount(s,TopAbs_FACE) > 8192 || OS3DSurfaceCount(s,TopAbs_EDGE) > 32768)
            return @{@"error":@"Surface inspection exceeds the bounded topology budget."};
        const NSInteger free = OS3DSurfaceFreeEdges(s);
        TopTools_IndexedMapOfShape faces; TopExp::MapShapes(s,TopAbs_FACE,faces);
        NSMutableArray *domains=[NSMutableArray array];
        for (Standard_Integer index=1;index<=faces.Extent();++index) {
            Standard_Real u0,u1,v0,v1; BRepTools::UVBounds(TopoDS::Face(faces(index)),u0,u1,v0,v1);
            for (double value:{u0,u1,v0,v1}) if (!std::isfinite(value)) return @{@"error":@"The face has an unbounded parameter domain."};
            if (deadline->Fired()) return @{@"error":@"Surface inspection exceeded its deadline."};
            [domains addObject:@{@"face_index":@(index),@"u_min":@(u0),@"u_max":@(u1),@"v_min":@(v0),@"v_max":@(v1)}];
        }
        bool canTrim=false,canPatch=false;
        try {
            if (faces.Extent() == 1) {
                double u0,u1,v0,v1;
                canTrim=OS3DSurfaceTrimDomain(TopoDS::Face(faces(1)),u0,u1,v0,v1);
            }
        } catch (...) { canTrim=false; }
        try {
        if (free > 0 && (faces.Extent() != 1 || BRepAdaptor_Surface(TopoDS::Face(faces(1))).GetType() != GeomAbs_Plane)) {
            const double tolerance=std::max(1e-6,OS3DMaxTolerance(s));
            ShapeAnalysis_FreeBounds bounds(s,tolerance,Standard_False,Standard_False);
            bool any=false,all=true;
            for (TopExp_Explorer open(bounds.GetOpenWires(),TopAbs_WIRE);open.More();open.Next()) all=false;
            for (TopExp_Explorer wire(bounds.GetClosedWires(),TopAbs_WIRE);wire.More();wire.Next()) {
                any=true;BRepBuilderAPI_FindPlane plane(wire.Current(),tolerance);
                if (!plane.Found()) { all=false;break; }
            }
            canPatch=any && all;
        }
        } catch (...) { canPatch=false; }
        if (deadline->Fired()) return @{@"error":@"Surface inspection exceeded its deadline."};
        return @{@"trim_supported":@(canTrim),@"planar_patch_supported":@(canPatch),@"face_domains":domains,@"faces":@(OS3DSurfaceCount(s,TopAbs_FACE)), @"shells":@(OS3DSurfaceCount(s,TopAbs_SHELL)),
                 @"solids":@(OS3DSurfaceCount(s,TopAbs_SOLID)), @"free_edges":@(free),
                 @"closed":@(free == 0 && OS3DFaceCount(s) > 0), @"valid":@(OS3DIsValid(s))};
    } catch (Standard_Failure &failure) {
        return @{@"error":OS3DCrashMessage("surface inspection",failure.GetMessageString())};
    } catch (...) { return @{@"error":@"Surface inspection failed."}; }
}

+ (nullable OCCTShape *)surfaceOperation:(NSString *)operation shapes:(NSArray<OCCTShape *> *)shapes
                            parameters:(NSData *)parameters tolerance:(double)tolerance
                         requireClosed:(BOOL)requireClosed status:(OCCTOpStatus *)status {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"This surface operation could not be completed.");
    if (shapes.count == 0 || shapes.count > 64 || !std::isfinite(tolerance)
        || tolerance < 1e-7 || tolerance > 1e-3 || parameters.length % sizeof(double)) return nil;
    OS3DSignalScope signalScope;
    try {
        OCC_CATCH_SIGNALS
        Handle(OS3DDeadlineProgress) deadline=new OS3DDeadlineProgress(kOS3DOpDeadlineSeconds);
        NSInteger totalFaces=0,totalEdges=0;
        for (OCCTShape *shape in shapes) {
            totalFaces += OS3DSurfaceCount(shape->_shape,TopAbs_FACE);
            totalEdges += OS3DSurfaceCount(shape->_shape,TopAbs_EDGE);
        }
        if (totalFaces > 8192 || totalEdges > 32768) {
            OS3DSetStatus(status,OCCTOpCodeKernelRefused,@"The surfaces exceed the bounded operation complexity. Use fewer sources.");return nil;
        }
        for (OCCTShape *shape in shapes) if (shape->_shape.IsNull() || !OS3DIsValid(shape->_shape)
            || OS3DSurfaceCount(shape->_shape,TopAbs_SOLID) != 0) return nil;
        const double *p = static_cast<const double *>(parameters.bytes);
        const NSUInteger count = parameters.length / sizeof(double);
        for (NSUInteger i=0;i<count;++i) if (!std::isfinite(p[i])) return nil;
        TopoDS_Shape result;
        bool solidResult = false;
        const TopoDS_Shape &source = shapes[0]->_shape;
        if ([operation isEqualToString:@"trim"]) {
            if (shapes.count != 1 || count != 4 || OS3DFaceCount(source) != 1) return nil;
            TopExp_Explorer faces(source,TopAbs_FACE); const TopoDS_Face face=TopoDS::Face(faces.Current());
            double u0,u1,v0,v1;
            if (!OS3DSurfaceTrimDomain(face,u0,u1,v0,v1) || p[0] < u0 || p[1] > u1 || p[2] < v0 || p[3] > v1
                || p[1]-p[0] <= 1e-9 || p[3]-p[2] <= 1e-9) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"Trim requires one rectangular UV face and bounds inside its actual domain."); return nil;
            }
            TopLoc_Location loc; Handle(Geom_Surface) surf = BRep_Tool::Surface(face,loc);
            BRepBuilderAPI_MakeFace maker(surf,p[0],p[1],p[2],p[3],tolerance);
            if (!maker.IsDone()) return nil;
            TopoDS_Face trimmed = maker.Face(); trimmed.Location(loc); trimmed.Orientation(face.Orientation()); result=trimmed;
        } else if ([operation isEqualToString:@"patch"] || [operation isEqualToString:@"sew"]) {
            const bool patch = [operation isEqualToString:@"patch"];
            if (count != 0 || (patch ? shapes.count != 1 : shapes.count < 2)) return nil;
            BRepBuilderAPI_Sewing sewing(tolerance,Standard_True,Standard_True,Standard_True,Standard_False);
            for (OCCTShape *shape in shapes) sewing.Add(shape->_shape);
            if (patch) {
                ShapeAnalysis_FreeBounds bounds(source,tolerance,Standard_False,Standard_False);
                for (TopExp_Explorer open(bounds.GetOpenWires(),TopAbs_WIRE);open.More();open.Next()) {
                    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"A patch needs closed free-boundary wires."); return nil;
                }
                NSUInteger patched=0;
                for (TopExp_Explorer wire(bounds.GetClosedWires(),TopAbs_WIRE);wire.More();wire.Next()) {
                    // Explicit planar-only mode; never fit an arbitrary surface
                    // through boundary samples and call it exact.
                    TopoDS_Wire boundary=TopoDS::Wire(wire.Current()); boundary.Reverse();
                    BRepBuilderAPI_MakeFace fill(boundary,Standard_True);
                    if (!fill.IsDone()) {
                        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"This boundary is not planar; planar patch cannot fill it."); return nil;
                    }
                    sewing.Add(fill.Face()); if (++patched > 128 || deadline->Fired()) return nil;
                }
                if (patched == 0) return nil;
            }
            OS3D_GUARDED(status,"surface sewing",sewing.Perform(deadline->Start())); if (deadline->Fired()) return nil;
            result=sewing.SewedShape();
            // One coherent shell is required; a compound of unjoined sheets is
            // not a successful sewing result even when each sheet is valid.
            if (result.IsNull() || OS3DSurfaceCount(result,TopAbs_SHELL) != 1 || sewing.NbMultipleEdges() > 0
                || ((requireClosed || patch) && (sewing.NbFreeEdges() != 0 || OS3DSurfaceFreeEdges(result) != 0))) {
                OS3DSetStatus(status, OCCTOpCodeInvalidResult, @"The surfaces do not form the requested connected, closed shell."); return nil;
            }
            TopExp_Explorer onlyShell(result,TopAbs_SHELL);
            if (OS3DFaceCount(onlyShell.Current()) != OS3DFaceCount(result)) return nil;
            const NSInteger faceCount=OS3DFaceCount(result);
            ShapeFix_Shell orient(TopoDS::Shell(onlyShell.Current()));
            orient.FixFaceOrientation(TopoDS::Shell(onlyShell.Current()),Standard_True,Standard_False);
            const TopoDS_Shape oriented=orient.Shape();
            // Orientation repair may not discard the non-orientable subset.
            if (oriented.IsNull() || OS3DSurfaceCount(oriented,TopAbs_SHELL) != 1 || OS3DFaceCount(oriented) != faceCount) return nil;
            result=oriented;
        } else if ([operation isEqualToString:@"thicken"]) {
            if (shapes.count != 1 || count != 1 || std::abs(p[0]) < 1e-5 || std::abs(p[0]) > 10000) return nil;
            const NSInteger free = OS3DSurfaceFreeEdges(source);
            if (free < 0) return nil;
            TopoDS_Shape built;
            double expectedWallVolume=-1;
            if (free == 0) {
                if (OS3DSurfaceCount(source,TopAbs_SHELL) != 1) return nil;
                TopExp_Explorer shells(source,TopAbs_SHELL);
                BRepBuilderAPI_MakeSolid makeSolid(TopoDS::Shell(shells.Current()));
                if (!makeSolid.IsDone()) return nil;
                TopoDS_Solid base=makeSolid.Solid();
                if (!BRepLib::OrientClosedSolid(base) || !OS3DIsValid(base)) return nil;
                // Reuse the established fully-enclosed shell construction:
                // offset then non-destructive cut. ByJoin with no closing
                // faces is not accepted as proof that a wall was created.
                Message_ProgressScope phases(deadline->Start(),"Closed surface thickness",3);
                BRepOffsetAPI_MakeOffsetShape offset;
                OS3D_GUARDED(status,"closed surface offset",offset.PerformByJoin(base,p[0],tolerance,
                    BRepOffset_Skin,Standard_False,Standard_False,GeomAbs_Arc,Standard_False,phases.Next()));
                if (deadline->Fired() || !offset.IsDone()) return nil;
                int offsetCount=0;TopoDS_Shape parallel=OS3DExtractSingleSolid(offset.Shape(),offsetCount);
                if (parallel.IsNull() || OS3DFaceCount(parallel) != OS3DFaceCount(offset.Shape()) || !OS3DIsValid(parallel)) return nil;
                TopoDS_Solid parallelSolid=TopoDS::Solid(parallel);
                if (!BRepLib::OrientClosedSolid(parallelSolid)) return nil;
                parallel=parallelSolid;
                const double before=OS3DVolume(base),after=OS3DVolume(parallel);
                if (!std::isfinite(before) || !std::isfinite(after) || before <= 0 || after <= 0
                    || (p[0] > 0 ? after <= before : after >= before)) {
                    OS3DSetStatus(status,OCCTOpCodeInvalidResult,@"The requested thickness did not form a distinct parallel boundary.");return nil;
                }
                expectedWallVolume=std::abs(after-before);
                TopTools_ListOfShape arguments,tools;
                arguments.Append(p[0] > 0 ? parallel : base);
                tools.Append(p[0] > 0 ? base : parallel);
                BRepAlgoAPI_Cut cut;cut.SetArguments(arguments);cut.SetTools(tools);cut.SetNonDestructive(Standard_True);cut.SetRunParallel(Standard_False);
                OS3D_GUARDED(status,"closed surface wall",cut.Build(phases.Next()));
                if (deadline->Fired() || !cut.IsDone() || cut.HasErrors()) return nil;
                built=cut.Shape();
                if (!OS3DIsValid(built)) {
                    // The mature boolean path performs a validity repair before
                    // accepting native Cut output. Do the same on an OWNED copy
                    // here, with a strict budget tied to the authored tolerance.
                    // This never raises the result acceptance threshold or
                    // clamps a bad edge tolerance down to hide its residual.
                    BRepBuilderAPI_Copy copy(built,Standard_True,Standard_False);
                    if (!copy.IsDone() || copy.Shape().IsNull()) return nil;
                    Handle(ShapeFix_Shape) fixer=new ShapeFix_Shape(copy.Shape());
                    fixer->SetPrecision(tolerance);
                    fixer->SetMinTolerance(Precision::Confusion());
                    fixer->SetMaxTolerance(tolerance*10);
                    OS3D_GUARDED(status,"closed surface wall validity repair",fixer->Perform(phases.Next()));
                    if (deadline->Fired() || fixer->Shape().IsNull()) return nil;
                    built=fixer->Shape();
                }
            } else {
                // The public Simple method has no progress range. The same
                // shipped OCCT engine offers explicit Thickening on its
                // progress-aware offset builder, including side walls.
                BRepOffset_MakeOffset offset;
                offset.Initialize(source,p[0],tolerance,BRepOffset_Skin,Standard_False,Standard_False,
                    GeomAbs_Arc,Standard_True /*thickening*/,Standard_False);
                offset.AllowLinearization(Standard_False);
                OS3D_GUARDED(status,"open surface thickness",offset.MakeOffsetShape(deadline->Start()));
                if (deadline->Fired() || !offset.IsDone()) return nil;
                built=offset.Shape();
            }
            int solidCount=0;result=OS3DExtractSingleSolid(built,solidCount);
            if (result.IsNull() || OS3DFaceCount(result) != OS3DFaceCount(built)) return nil;
            TopoDS_Solid solid=TopoDS::Solid(result);
            if (!BRepLib::OrientClosedSolid(solid)) return nil;
            result=solid;solidResult=true;
            if (expectedWallVolume > 0) {
                const double actual=OS3DVolume(result);
                if (!std::isfinite(actual) || std::abs(actual-expectedWallVolume) > std::max(1e-5,expectedWallVolume*1e-6)) {
                    OS3DSetStatus(status,OCCTOpCodeInvalidResult,@"The closed shell did not retain the requested material wall.");return nil;
                }
            }
        } else return nil;
        if (deadline->Fired()) return nil;
        OCCTShape *out=OS3DSurfaceResult(result,solidResult,tolerance,status);
        if (out == nil && status.detail.length) {
            status.detail=[NSString stringWithFormat:@"surface %@: %@",operation,status.detail];
        }
        return out;
    } catch (Standard_Failure &failure) {
        OS3DSetStatus(status,OCCTOpCodeKernelRefused,OS3DCrashMessage("surface operation",failure.GetMessageString()));return nil;
    } catch (...) { return nil; }
}


+ (nullable NSData *)surfaceDifferential:(OCCTShape *)shape faceIndex:(NSInteger)faceIndex
                                      u:(double)u v:(double)v {
    if (!std::isfinite(u) || !std::isfinite(v) || faceIndex <= 0) return nil;
    OS3DSignalScope signalScope;
    try {
        OCC_CATCH_SIGNALS
        TopTools_IndexedMapOfShape faces; TopExp::MapShapes(shape->_shape,TopAbs_FACE,faces);
        if (faceIndex > faces.Extent()) return nil;
        const TopoDS_Face face=TopoDS::Face(faces((Standard_Integer)faceIndex));
        BRepClass_FaceClassifier classifier(face,gp_Pnt2d(u,v),Precision::Confusion());
        if (classifier.State() != TopAbs_IN && classifier.State() != TopAbs_ON) return nil;
        BRepAdaptor_Surface surface(face,Standard_False);
        gp_Pnt point; gp_Vec du,dv,duu,dvv,duv;
        surface.D2(u,v,point,du,dv,duu,dvv,duv);
        const double values[]={point.X(),point.Y(),point.Z(),du.X(),du.Y(),du.Z(),dv.X(),dv.Y(),dv.Z(),
            duu.X(),duu.Y(),duu.Z(),duv.X(),duv.Y(),duv.Z(),dvv.X(),dvv.Y(),dvv.Z()};
        for (double value:values) if (!std::isfinite(value)) return nil;
        return [NSData dataWithBytes:values length:sizeof(values)];
    } catch (Standard_Failure &) { return nil; }
    catch (...) { return nil; }
}


// No shared TShape enters this path. All sections and guide curves are built
// from the immutable numeric snapshot; signal state is restored by the scope.
+ (nullable OCCTShape *)guidedLoftWithOuterLoops:(NSArray<NSData *> *)loops
                                    outerConics:(NSArray<NSData *> *)conics
                                  outerSegments:(NSArray<NSData *> *)segments
                                          bases:(NSArray<OCCTPlaneBasis *> *)bases
                                    guideCurves:(NSArray<NSData *> *)guideCurves
                                     guideBases:(NSArray<OCCTPlaneBasis *> *)guideBases
                                  guideReversed:(NSArray<NSNumber *> *)reversed
                                        history:(OCCTShapeHistory *)history
                                        metrics:(NSMutableDictionary<NSString *,id> *)metrics
                                         status:(OCCTOpStatus *)status {
    OS3DSetStatus(status,OCCTOpCodeKernelRefused,@"The sections and auxiliary guide could not form a solid.");
    auto refusal = [&](int line) -> OCCTShape * {
#if DEBUG
        NSLog(@"Guided loft refused at native line %d: %@", line, status.detail ?: @"native builder returned no result");
#endif
        return nil;
    };
    if (NSThread.isMainThread || loops.count < 2 || loops.count > 8 || bases.count != loops.count
        || conics.count != loops.count || segments.count != loops.count || guideCurves.count < 1
        || guideCurves.count > 8 || guideBases.count != guideCurves.count || reversed.count != guideCurves.count) return refusal(__LINE__);
    OS3DSignalScope signalScope;
    try {
        OCC_CATCH_SIGNALS
        const double tol=1e-5;
        const gp_Pnt origin(bases[0]->_o[0],bases[0]->_o[1],bases[0]->_o[2]);
        const gp_Pnt last(bases.lastObject->_o[0],bases.lastObject->_o[1],bases.lastObject->_o[2]);
        const gp_Vec along(origin,last);const double length=along.Magnitude();
        if (!std::isfinite(length) || length <= tol || length > 1000000) return refusal(__LINE__);
        const gp_Dir direction(along);double prior=-1;
        BRepBuilderAPI_MakePolygon primary;
        std::vector<gp_Pnt> centers;
        std::vector<TopoDS_Wire> wires;
        std::vector<TopoDS_Face> localFaces;
        for (NSUInteger i=0;i<loops.count;++i) {
            const gp_Pnt center(bases[i]->_o[0],bases[i]->_o[1],bases[i]->_o[2]);
            const gp_Vec offset(origin,center),normal(bases[i]->_n[0],bases[i]->_n[1],bases[i]->_n[2]);
            const double station=offset.Dot(gp_Vec(direction));
            if (station <= prior+tol || offset.Crossed(gp_Vec(direction)).Magnitude() > tol
                || normal.Magnitude() < 1e-9 || std::abs(gp_Dir(normal).Dot(direction)) < 1-1e-9) {
                OS3DSetStatus(status,OCCTOpCodeKernelRefused,@"Guided sections must be ordered on one straight main spine through their origins, with parallel section planes normal to that spine.");return refusal(__LINE__);
            }
            prior=station;centers.push_back(center);primary.Add(center);
            TopoDS_Wire wire;
            if (conics[i].length >= 5*sizeof(double)) wire=ConicWire((const double *)conics[i].bytes,0);
            if (wire.IsNull() && segments[i].length) wire=SegWire(segments[i],0);
            if (wire.IsNull()) wire=PolyWire(loops[i],0);
            if (wire.IsNull() || OS3DSurfaceCount(wire,TopAbs_EDGE) > 64) return refusal(__LINE__);
            BRepBuilderAPI_MakeFace face(wire,Standard_True);if (!face.IsDone()) return refusal(__LINE__);
            localFaces.push_back(face.Face());
            wires.push_back(TopoDS::Wire(BRepBuilderAPI_Transform(wire,OS3DBasisTransform(bases[i]),Standard_True).Shape()));
        }
        if (!primary.IsDone()) return refusal(__LINE__);const TopoDS_Wire spine=primary.Wire();
        BRepBuilderAPI_MakeWire railMaker;std::vector<Handle(Geom_Curve)> railCurves;
        gp_Pnt firstRail,previousRail;bool hasPrevious=false;
        for (NSUInteger i=0;i<guideCurves.count;++i) {
            Handle(Geom_Curve) curve=OS3DSketchCurveDefinition(guideCurves[i],false);
            if (curve.IsNull()) return refusal(__LINE__);
            curve=Handle(Geom_Curve)::DownCast(curve->Transformed(OS3DBasisTransform(guideBases[i])));
            BRepBuilderAPI_MakeEdge edgeMaker(curve);if (!edgeMaker.IsDone()) return refusal(__LINE__);
            TopoDS_Edge edge=edgeMaker.Edge();if (reversed[i].boolValue) edge.Reverse();
            TopoDS_Vertex a,b;TopExp::Vertices(edge,a,b,Standard_True);if(a.IsNull() || b.IsNull()) return refusal(__LINE__);
            const gp_Pnt pa=BRep_Tool::Pnt(a),pb=BRep_Tool::Pnt(b);
            if (hasPrevious && previousRail.Distance(pa) > tol) {
                OS3DSetStatus(status,OCCTOpCodeKernelRefused,@"The stored guide order/reversal no longer connects.");return refusal(__LINE__);
            }
            if (!hasPrevious) firstRail=pa;previousRail=pb;hasPrevious=true;
            railMaker.Add(edge);if (!railMaker.IsDone()) return refusal(__LINE__);railCurves.push_back(curve);
        }
        if (firstRail.Distance(previousRail) <= tol) return refusal(__LINE__);
        auto pointDistance=[](const gp_Pnt &point,const TopoDS_Shape &shape) {
            BRepExtrema_DistShapeShape distance(BRepBuilderAPI_MakeVertex(point).Vertex(),shape);
            return distance.IsDone() ? distance.Value() : std::numeric_limits<double>::infinity();
        };
        if (pointDistance(firstRail,wires.front()) > tol || pointDistance(previousRail,wires.back()) > tol) {
            OS3DSetStatus(status,OCCTOpCodeKernelRefused,@"The ordered guide endpoints must meet the first and last section boundaries.");return refusal(__LINE__);
        }
        // The plane-intersection mode has a single, unambiguous authored rail
        // point at EVERY supplied section. Do not replace a missed section.
        for (NSUInteger index=0;index<centers.size();++index) {
            Handle(Geom_Plane) plane=new Geom_Plane(centers[index],direction);
            std::vector<gp_Pnt> hits;
            for (auto &curve:railCurves) {
                GeomAPI_IntCS intersection(curve,plane);
                if (!intersection.IsDone() || intersection.NbSegments() != 0) return refusal(__LINE__);
                for (int k=1;k<=intersection.NbPoints();++k) {
                    const gp_Pnt point=intersection.Point(k);bool duplicate=false;
                    for (const auto &priorPoint:hits) if (point.Distance(priorPoint) <= tol) duplicate=true;
                    if (!duplicate) hits.push_back(point);
                }
            }
            if (hits.size() != 1 || pointDistance(hits[0],wires[index]) > tol) {
                OS3DSetStatus(status,OCCTOpCodeKernelRefused,@"The guide must meet every supplied section boundary once.");return refusal(__LINE__);
            }
        }
        BRepOffsetAPI_MakePipeShell maker(spine);
        // ContactOnBorder's automatic law CLEARS earlier Add profiles in 7.8.1.
        // Contact retains all sections and imposes actual rail contact.
        maker.SetMode(railMaker.Wire(),Standard_False,BRepFill_Contact);
        maker.SetTolerance(tol,tol,1e-5);maker.SetMaxDegree(8);maker.SetMaxSegments(64);
        maker.SetForceApproxC1(Standard_False);
        TopTools_IndexedMapOfShape spineVertices;TopExp::MapShapes(spine,TopAbs_VERTEX,spineVertices);
        for (NSUInteger i=0;i<wires.size();++i) {
            TopoDS_Vertex location;
            for (int j=1;j<=spineVertices.Extent();++j) {
                const TopoDS_Vertex vertex=TopoDS::Vertex(spineVertices(j));
                if (BRep_Tool::Pnt(vertex).Distance(centers[i]) <= tol) { location=vertex;break; }
            }
            if (location.IsNull()) return refusal(__LINE__);
            maker.Add(wires[i],location,Standard_False,Standard_False);
        }
        TopTools_ListOfShape retainedProfiles;maker.Profiles(retainedProfiles);
        if (retainedProfiles.Extent() != (int)wires.size()) return refusal(__LINE__);
        // Deliberately NOT a deadline claim: the pinned Build ignores range.
        // The Swift serial worker joins this bounded operation then fences it.
        OS3D_GUARDED(status,"guided loft",maker.Build());
        if (!maker.IsDone()) return refusal(__LINE__);
        const double approximation=maker.ErrorOnSurface();
        if (!std::isfinite(approximation) || approximation > tol || !maker.MakeSolid()) return refusal(__LINE__);
        const TopoDS_Shape solid=maker.Shape();
        if (solid.IsNull() || OS3DSurfaceCount(solid,TopAbs_FACE) > 1024) return refusal(__LINE__);
        OCCTShape *validated=OS3DSurfaceResult(solid,true,tol,status);if (!validated) return refusal(__LINE__);
        // Independent actual-face distance samples. Sampling is labelled in
        // the report, never promoted to a full-curve exactness certificate.
        BRep_Builder builder;TopoDS_Compound boundary;builder.MakeCompound(boundary);
        for (TopExp_Explorer face(solid,TopAbs_FACE);face.More();face.Next()) builder.Add(boundary,face.Current());
        double guideResidual=0,sectionResidual=0;int guideSamples=0,sectionSamples=0;
        auto sample=[&](const Handle(Geom_Curve)& curve,double first,double last,int count,double &maximum,int &samples) {
            if (!std::isfinite(first) || !std::isfinite(last)) return false;
            for (int k=0;k<count;++k) {
                const double distance=pointDistance(curve->Value(first+(last-first)*k/(count-1)),boundary);
                if (!std::isfinite(distance) || distance > 2*tol) return false;
                maximum=std::max(maximum,distance);++samples;
            }
            return true;
        };
        for (const auto &curve:railCurves) if (!sample(curve,curve->FirstParameter(),curve->LastParameter(),33,guideResidual,guideSamples)) {
            OS3DSetStatus(status,OCCTOpCodeInvalidResult,@"The built surface does not meet the authored guide within tolerance.");return refusal(__LINE__);
        }
        for (const auto &wire:wires) for (TopExp_Explorer e(wire,TopAbs_EDGE);e.More();e.Next()) {
            Standard_Real first,last;TopLoc_Location location;
            Handle(Geom_Curve) curve=BRep_Tool::Curve(TopoDS::Edge(e.Current()),location,first,last);
            if (curve.IsNull()) return refusal(__LINE__);
            curve=Handle(Geom_Curve)::DownCast(curve->Transformed(location.Transformation()));
            if (!sample(curve,first,last,9,sectionResidual,sectionSamples)) {
                OS3DSetStatus(status,OCCTOpCodeInvalidResult,@"The built surface does not preserve an authored section within tolerance.");return refusal(__LINE__);
            }
        }
        // Ask native history on the exact wire/edges consumed by Add.
        // Result-map containment gates every row; unknown faces stay unknown.
        TopTools_IndexedMapOfShape finalFaces;TopExp::MapShapes(solid,TopAbs_FACE,finalFaces);
        std::set<std::array<int32_t,5>> rows;
        auto emit=[&](const TopoDS_Shape &shape,int32_t kind,int32_t sub,int32_t relation) {
            for (TopExp_Explorer faces(shape,TopAbs_FACE);faces.More();faces.Next()) {
                const int face=finalFaces.FindIndex(faces.Current());
                if (face > 0) rows.insert({(int32_t)face,0,kind,sub,relation});
            }
        };
        TopTools_IndexedMapOfShape inputEdges;TopExp::MapShapes(wires.front(),TopAbs_EDGE,inputEdges);
        for(int j=1;j<=inputEdges.Extent();++j) {
            const auto &generated=maker.Generated(inputEdges(j));
            for(TopTools_ListIteratorOfListOfShape it(generated);it.More();it.Next()) emit(it.Value(),1,j,2);
        }
        const TopoDS_Shape firstCap=OS3DCapFace(solid,maker.FirstShape()),lastCap=OS3DCapFace(solid,maker.LastShape());
        if (!firstCap.IsNull()) { const int face=finalFaces.FindIndex(firstCap);if(face > 0) rows.insert({(int32_t)face,0,0,1,1}); }
        if (!lastCap.IsNull()) { const int face=finalFaces.FindIndex(lastCap);if(face > 0) rows.insert({(int32_t)face,0,0,2,1}); }
        std::vector<int32_t> packed;for(const auto &row:rows) packed.insert(packed.end(),row.begin(),row.end());
        history.rows=[NSData dataWithBytes:packed.data() length:packed.size()*sizeof(int32_t)];history.rowCount=rows.size();history.truncatedByHeal=NO;
        metrics[@"native_surface_error"]=@(approximation);metrics[@"guide_sample_deviation"]=@(guideResidual);
        metrics[@"section_sample_deviation"]=@(sectionResidual);metrics[@"guide_sample_count"]=@(guideSamples);
        metrics[@"section_sample_count"]=@(sectionSamples);metrics[@"volume"]=@(OS3DVolume(solid));
        metrics[@"faces"]=@(OS3DFaceCount(solid));metrics[@"profile_count"]=@(retainedProfiles.Extent());
        return validated;
    } catch (Standard_Failure &failure) {
        OS3DSetStatus(status,OCCTOpCodeKernelRefused,OS3DCrashMessage("guided loft",failure.GetMessageString()));return refusal(__LINE__);
    } catch (...) { return refusal(__LINE__); }
}


// Exact tensor interpolation of native section control polygons. ContactOrder
// 1/2 rows are prescribed derivatives consumed by OCCT's interpolation solver;
// they are not global continuity settings and are not post-hoc D2 filters.
+ (OCCTShape *)endpointLoftWithOuterLoops:(NSArray<NSData *> *)loops
    outerConics:(NSArray<NSData *> *)conics outerSegments:(NSArray<NSData *> *)segments
    bases:(NSArray<OCCTPlaneBasis *> *)bases startBoundary:(NSData *)start endBoundary:(NSData *)end
    history:(OCCTShapeHistory *)history metrics:(NSMutableDictionary *)metrics status:(OCCTOpStatus *)status {
    OS3DSetStatus(status,OCCTOpCodeOK,@"");
    OS3DSignalScope signals;
    try {
        OCC_CATCH_SIGNALS
        const double tol=1e-6;
        auto finite=[](const gp_XYZ &v) {return std::isfinite(v.X()) && std::isfinite(v.Y()) && std::isfinite(v.Z());};
        const NSUInteger count=loops.count;
        if (count < 2 || count > 4 || conics.count != count || segments.count != count || bases.count != count
            || (!start.length && !end.length)) return nil;
        const gp_Pnt origin(bases[0]->_o[0],bases[0]->_o[1],bases[0]->_o[2]);
        const gp_Pnt finish(bases.lastObject->_o[0],bases.lastObject->_o[1],bases.lastObject->_o[2]);
        const gp_Vec axis(origin,finish);const double span=axis.Magnitude();
        if (!std::isfinite(span) || span < 1e-3 || span > 10000) return nil;
        const gp_Vec direction=axis/span;
        struct Boundary { int order=0;gp_Vec tangent,curvature;double angular=0,curvatureTol=0; };
        auto decode=[&](NSData *data,Boundary &b) {
            if (!data.length) return true;
            if (data.length != 10*sizeof(double)) return false;
            const double *p=(const double *)data.bytes;
            for(int i=0;i<10;i++) if(!std::isfinite(p[i])) return false;
            b.order=(int)p[0];b.tangent=gp_Vec(p[1],p[2],p[3]);b.curvature=gp_Vec(p[4],p[5],p[6]);
            b.angular=p[7];b.curvatureTol=p[8];
            if ((b.order!=1 && b.order!=2) || b.tangent.Magnitude() < 1e-9 || b.angular<=0 || b.angular>0.1 || b.curvatureTol<=0) return false;
            b.tangent.Normalize();
            return b.tangent.Dot(direction)>0.1 && b.curvature.Magnitude()<=4/span
                && (b.order!=2 || std::abs(b.tangent.Dot(b.curvature))<=1e-10*std::max(1.0,b.curvature.Magnitude()));
        };
        Boundary boundaries[2];if(!decode(start,boundaries[0]) || !decode(end,boundaries[1])) return nil;
        const int rows=(int)count+boundaries[0].order+boundaries[1].order,degree=rows-1;
        if(degree<2 || degree>7) return nil;
        // End derivative rows precede end D0. This ordering avoids a zero
        // diagonal in OCCT's documented no-pivot band interpolation routine.
        TColStd_Array1OfReal parameters(1,rows),flatKnots(1,2*rows),vKnots(1,2);
        TColStd_Array1OfInteger contact(1,rows),vMults(1,2);
        int row=1;
        parameters(row)=0;contact(row++)=0;
        for(int d=1;d<=boundaries[0].order;d++) {parameters(row)=0;contact(row++)=d;}
        for(NSUInteger i=1;i+1<count;i++) {parameters(row)=(double)i/(count-1);contact(row++)=0;}
        for(int d=boundaries[1].order;d>=0;d--) {parameters(row)=1;contact(row++)=d;}
        for(int i=1;i<=2*rows;i++) flatKnots(i)=i<=rows ? 0 : 1;
        vKnots(1)=0;vKnots(2)=1;vMults(1)=rows;vMults(2)=rows;
        std::vector<TopoDS_Wire> wires;std::vector<std::vector<TopoDS_Edge>> edges;
        for(NSUInteger i=0;i<count;i++) {
            const gp_Pnt center(bases[i]->_o[0],bases[i]->_o[1],bases[i]->_o[2]);
            const gp_Vec normal(bases[i]->_n[0],bases[i]->_n[1],bases[i]->_n[2]);
            const gp_Pnt expected=origin.Translated(axis*((double)i/(count-1)));
            if(center.Distance(expected)>tol || normal.Magnitude()<1e-9 || std::abs(gp_Dir(normal).Dot(gp_Dir(axis)))<1-1e-10) {
                OS3DSetStatus(status,OCCTOpCodeKernelRefused,@"Endpoint sections require equally spaced, parallel normal planes on their origin axis.");return nil;
            }
            TopoDS_Wire local;
            if(conics[i].length!=5*sizeof(double) || loops[i].length%(2*sizeof(double)) || segments[i].length%sizeof(double)) return nil;
            const double *conic=(const double *)conics[i].bytes;
            const bool isConic=conic[2]>0 && conic[3]>0;
            for(int c=0;c<5;c++) if(!std::isfinite(conic[c])) return nil;
            if(isConic) {
                if(conic[2]!=conic[3] && std::abs(conic[2]-conic[3])<=1e-9*std::max(conic[2],conic[3])) return nil;
                local=ConicWire(conic,0);
            }
            else if(segments[i].length) {
                // Legacy SegWire can flatten an invalid arc to a line. New
                // endpoint intent must refuse such an arc before that fallback.
                const double *data=(const double *)segments[i].bytes;
                const NSUInteger total=segments[i].length/sizeof(double);
                for(NSUInteger j=0;j<total;) {
                    const double kind=data[j];
                    if(kind<1.5) {
                        if(j+7>total) return nil;
                        if(kind>0.5) {
                            GC_MakeArcOfCircle arc(gp_Pnt(data[j+1],data[j+2],0),gp_Pnt(data[j+5],data[j+6],0),gp_Pnt(data[j+3],data[j+4],0));
                            if(!arc.IsDone()) return nil;
                        }
                        j+=7;
                    } else if(kind==4 && j+3<=total) {
                        const double rawCount=data[j+1];
                        if(!std::isfinite(rawCount) || rawCount<9 || rawCount>total || rawCount!=std::floor(rawCount)) return nil;
                        const NSUInteger length=(NSUInteger)rawCount;
                        if(j+3+length>total) return nil;j+=3+length;
                    } else return nil;
                }
                local=SegWire(segments[i],0);
            } else local=PolyWire(loops[i],0);
            if(local.IsNull()) return nil;
            const TopoDS_Wire wire=TopoDS::Wire(BRepBuilderAPI_Transform(local,OS3DBasisTransform(bases[i]),Standard_True).Shape());
            std::vector<TopoDS_Edge> ordered;
            for(BRepTools_WireExplorer ex(wire);ex.More();ex.Next()) ordered.push_back(ex.Current());
            if(ordered.empty() || ordered.size()>16 || (i && ordered.size()!=edges.front().size())) return nil;
            wires.push_back(wire);edges.push_back(ordered);
        }
        std::vector<TopoDS_Face> walls;
        double sectionResidual=0,poleD1Residual=0,poleD2Residual=0,angleResidual=0,curvatureResidual=0;
        int poleCount=0,jetSamples=0;
        BRepBuilderAPI_Sewing sewing(tol,Standard_True,Standard_True,Standard_True,Standard_False);
        for(NSUInteger edgeIndex=0;edgeIndex<edges.front().size();edgeIndex++) {
            std::vector<Handle(Geom_BSplineCurve)> exactCurves;
            for(NSUInteger i=0;i<count;i++) {
                Standard_Real first,last;TopLoc_Location location;
                Handle(Geom_Curve) curve=BRep_Tool::Curve(edges[i][edgeIndex],location,first,last);
                if(curve.IsNull() || !std::isfinite(first) || !std::isfinite(last) || last-first<1e-12) return nil;
                curve=Handle(Geom_Curve)::DownCast(curve->Transformed(location.Transformation()));
                Handle(Geom_TrimmedCurve) trimmed=new Geom_TrimmedCurve(curve,first,last);
                if(edges[i][edgeIndex].Orientation()==TopAbs_REVERSED) trimmed->Reverse();
                // Do not feed conics to GeomFill_Profiler: pinned 7.8.1 may
                // approximate them. The exact conversion below uses native
                // rational representations and never fits sampled points.
                Handle(Geom_BSplineCurve) exact=GeomConvert::CurveToBSplineCurve(trimmed);
                if(exact.IsNull() || exact->IsPeriodic()) return nil;
                TColStd_Array1OfReal knots(1,exact->NbKnots());exact->Knots(knots);
                BSplCLib::Reparametrize(0,1,knots);exact->SetKnots(knots);
                exactCurves.push_back(exact);
            }
            const auto &basis=exactCurves.front();
            const int np=basis->NbPoles(),nk=basis->NbKnots(),ud=basis->Degree();
            if(np<2 || np>64 || ud<1 || ud>8 || (poleCount+=np)>256) return nil;
            TColStd_Array1OfReal uKnots(1,nk),weights(1,np);TColStd_Array1OfInteger uMults(1,nk);
            basis->Knots(uKnots);basis->Multiplicities(uMults);basis->Weights(weights);
            std::vector<TColgp_Array1OfPnt> inputPoles;
            for(NSUInteger i=0;i<count;i++) {
                TColgp_Array1OfPnt poles(1,np);TColStd_Array1OfReal otherWeights(1,np);
                const auto &exact=exactCurves[i];
                if(exact->Degree()!=ud || exact->NbPoles()!=np || exact->NbKnots()!=nk) return nil;
                for(int knot=1;knot<=nk;knot++) if(exact->Multiplicity(knot)!=uMults(knot) || exact->Knot(knot)!=uKnots(knot)) return nil;
                exact->Poles(poles);exact->Weights(otherWeights);
                for(int p=1;p<=np;p++) for(int c=1;c<=3;c++) if(!std::isfinite(poles(p).Coord(c)) || std::abs(poles(p).Coord(c))>1e6) return nil;
                // A common positive U weight field, constant along V, is
                // essential: it makes constant pole jets constant surface jets.
                const double ratio=otherWeights(1)/weights(1);
                if(!std::isfinite(ratio) || ratio<=0) return nil;
                for(int p=1;p<=np;p++) if(weights(p)<=0 || otherWeights(p)/ratio!=weights(p)) {
                    OS3DSetStatus(status,OCCTOpCodeKernelRefused,@"Endpoint sections need compatible rational weights; no section was fitted or replaced.");return nil;
                }
                inputPoles.push_back(poles);
            }
            TColgp_Array2OfPnt net(1,np,1,rows);TColStd_Array2OfReal netWeights(1,np,1,rows);
            for(int p=1;p<=np;p++) {
                TColgp_Array1OfPnt data(1,rows);int r=1;
                data(r++)=inputPoles.front()(p);
                for(int d=1;d<=boundaries[0].order;d++) data(r++)=gp_Pnt((d==1 ? boundaries[0].tangent*span : boundaries[0].curvature*(span*span)).XYZ());
                for(NSUInteger i=1;i+1<count;i++) data(r++)=inputPoles[i](p);
                for(int d=boundaries[1].order;d>=0;d--) data(r++)=d==0 ? inputPoles.back()(p)
                    : gp_Pnt((d==1 ? boundaries[1].tangent*span : boundaries[1].curvature*(span*span)).XYZ());
                int inversion=0;
                BSplCLib::Interpolate(degree,flatKnots,parameters,contact,data,inversion);
                if(inversion) {OS3DSetStatus(status,OCCTOpCodeKernelRefused,@"The endpoint derivative interpolation matrix is singular.");return nil;}
                for(int k=1;k<=rows;k++) if(!finite(data(k).XYZ()) || data(k).XYZ().Modulus()>1e7) return nil;
                Handle(Geom_BSplineCurve) trajectory=new Geom_BSplineCurve(data,vKnots,vMults,degree);
                for(NSUInteger i=0;i<count;i++) sectionResidual=std::max(sectionResidual,trajectory->Value((double)i/(count-1)).Distance(inputPoles[i](p)));
                for(int side=0;side<2;side++) if(boundaries[side].order) {
                    gp_Pnt point;gp_Vec d1,d2;trajectory->D2(side,point,d1,d2);
                    if(!finite(point.XYZ()) || !finite(d1.XYZ()) || !finite(d2.XYZ())) return nil;
                    poleD1Residual=std::max(poleD1Residual,(d1-boundaries[side].tangent*span).Magnitude());
                    if(boundaries[side].order==2) {
                        poleD2Residual=std::max(poleD2Residual,(d2-boundaries[side].curvature*(span*span)).Magnitude());
                    }
                }
                for(int v=1;v<=rows;v++) {net(p,v)=data(v);netWeights(p,v)=weights(p);}
            }
            if(sectionResidual>tol || poleD1Residual>tol || poleD2Residual>tol) return nil;
            Handle(Geom_BSplineSurface) surface=new Geom_BSplineSurface(net,netWeights,uKnots,vKnots,uMults,vMults,ud,degree);
            // Independent checks on the actual constructed surface; not on a
            // display mesh or on the requested input vectors.
            for(int side=0;side<2;side++) if(boundaries[side].order) for(int sample=0;sample<=32;sample++) {
                const double u=uKnots(1)+(uKnots(nk)-uKnots(1))*sample/32;
                gp_Pnt point;gp_Vec du,dv,duu,dvv,duv;surface->D2(u,side,point,du,dv,duu,dvv,duv);
                if(!finite(point.XYZ()) || !finite(du.XYZ()) || !finite(dv.XYZ()) || !finite(dvv.XYZ())
                    || dv.Magnitude()<1e-9 || du.Crossed(dv).Magnitude()<1e-9) return nil;
                const double angle=dv.Angle(boundaries[side].tangent);
                const gp_Vec curvature=(dvv-dv*(dv.Dot(dvv)/dv.SquareMagnitude()))/dv.SquareMagnitude();
                angleResidual=std::max(angleResidual,angle);
                if(!std::isfinite(angle) || angle>boundaries[side].angular) return nil;
                if(boundaries[side].order==2) {
                    const double error=(curvature-boundaries[side].curvature).Magnitude();curvatureResidual=std::max(curvatureResidual,error);
                    if(error>boundaries[side].curvatureTol) return nil;
                }
                ++jetSamples;
            }
            BRepBuilderAPI_MakeFace face(surface,tol);if(!face.IsDone()) return nil;
            walls.push_back(face.Face());sewing.Add(face.Face());
        }
        // Whole-boundary certificates: positive common U weights make
        // position/D1/D2 error convex combinations of the checked pole errors.
        // Conservative propagation through K=P_perp(D1)D2/|D1|² bounds every U,
        // so finite sample agreement is never the only boundary proof.
        const double lowerSpeed=span-poleD1Residual;
        if(lowerSpeed<=0) return nil;
        const double wholeAngle=std::asin(std::min(1.0,poleD1Residual/lowerSpeed));
        double wholeCurvature=0;
        for(int side=0;side<2;side++) if(boundaries[side].order) {
            if(wholeAngle>boundaries[side].angular) return nil;
            if(boundaries[side].order==2) {
                const double acceleration=boundaries[side].curvature.Magnitude()*span*span;
                const double bound=(poleD2Residual+4*acceleration*poleD1Residual/lowerSpeed)/(lowerSpeed*lowerSpeed)
                    +acceleration*std::abs(1/(lowerSpeed*lowerSpeed)-1/(span*span));
                wholeCurvature=std::max(wholeCurvature,bound);
                if(!std::isfinite(bound) || bound>boundaries[side].curvatureTol) return nil;
            }
        }
        BRepBuilderAPI_MakeFace firstCap(wires.front(),Standard_True),lastCap(wires.back(),Standard_True);
        if(!firstCap.IsDone() || !lastCap.IsDone()) return nil;
        sewing.Add(firstCap.Face());sewing.Add(lastCap.Face());
        OS3D_GUARDED(status,"endpoint loft sewing",sewing.Perform());
        const TopoDS_Shape sewed=sewing.SewedShape();
        if(sewed.IsNull() || OS3DSurfaceCount(sewed,TopAbs_SHELL)!=1 || OS3DSurfaceCount(sewed,TopAbs_FACE)!=(NSInteger)walls.size()+2) return nil;
        TopoDS_Shell shell;
        if(sewed.ShapeType()==TopAbs_SHELL) shell=TopoDS::Shell(sewed);
        else {TopExp_Explorer ex(sewed,TopAbs_SHELL);if(ex.More()) shell=TopoDS::Shell(ex.Current());}
        if(shell.IsNull()) return nil;
        // Correct only orientation; never heal away failed derivative/section
        // constraints or relax the original topology/closure assertions.
        ShapeFix_Shell orient(shell);orient.FixFaceOrientation(shell);
        BRepBuilderAPI_MakeSolid maker(orient.Shell());if(!maker.IsDone()) return nil;
        TopoDS_Solid solid=maker.Solid();
        if(OS3DSurfaceCount(solid,TopAbs_FACE)!=(NSInteger)walls.size()+2 || !BRepLib::OrientClosedSolid(solid)) return nil;
        OCCTShape *validated=OS3DSurfaceResult(solid,true,tol,status);if(!validated) return nil;
        TopTools_IndexedMapOfShape finalFaces;TopExp::MapShapes(solid,TopAbs_FACE,finalFaces);
        std::set<std::array<int32_t,5>> ancestry;
        auto emit=[&](const TopoDS_Face &input,int kind,int sub) {
            const TopoDS_Shape &changed=sewing.ModifiedSubShape(input);
            const TopoDS_Shape candidate=changed.IsNull() ? TopoDS_Shape(input) : changed;
            // Sewing may copy topology; match the actual retained surface
            // handle and exact location, never a nearest face/ordinal guess.
            for(int i=1;i<=finalFaces.Extent();i++) {
                TopLoc_Location a,b;
                if(BRep_Tool::Surface(input,a)==BRep_Tool::Surface(TopoDS::Face(finalFaces(i)),b) && a.IsEqual(b))
                    ancestry.insert({i,0,kind,sub,kind==0 ? 1 : 2});
                else if(finalFaces(i).IsSame(candidate)) ancestry.insert({i,0,kind,sub,kind==0 ? 1 : 2});
            }
        };
        TopTools_IndexedMapOfShape firstEdges;TopExp::MapShapes(wires.front(),TopAbs_EDGE,firstEdges);
        for(NSUInteger i=0;i<walls.size();i++) emit(walls[i],1,firstEdges.FindIndex(edges.front()[i]));
        emit(firstCap.Face(),0,1);emit(lastCap.Face(),0,2);
        // Every delivered face must retain an explicitly measured native
        // surface/identity; orientation repair may not discard a wall.
        if(ancestry.size()!=walls.size()+2) return nil;
        std::vector<int32_t> packed;for(const auto &r:ancestry) packed.insert(packed.end(),r.begin(),r.end());
        history.rows=[NSData dataWithBytes:packed.data() length:packed.size()*sizeof(int32_t)];history.rowCount=ancestry.size();history.truncatedByHeal=NO;
        metrics[@"section_pole_residual_mm"]=@(sectionResidual);metrics[@"endpoint_pole_d1_residual_mm"]=@(poleD1Residual);
        metrics[@"endpoint_normal_d2_residual_mm"]=@(poleD2Residual);metrics[@"endpoint_angle_residual_rad"]=@(angleResidual);
        metrics[@"endpoint_curvature_residual_per_mm"]=@(curvatureResidual);metrics[@"endpoint_sample_count"]=@(jetSamples);
        metrics[@"section_count"]=@(count);metrics[@"u_pole_count"]=@(poleCount);metrics[@"v_degree"]=@(degree);
        metrics[@"volume_mm3"]=@(OS3DVolume(solid));metrics[@"faces"]=@(OS3DFaceCount(solid));
        metrics[@"whole_boundary_angle_bound_rad"]=@(wholeAngle);
        metrics[@"whole_boundary_curvature_bound_per_mm"]=@(wholeCurvature);
        metrics[@"span_mm"]=@(span);return validated;
    } catch(Standard_Failure &failure) {
        OS3DSetStatus(status,OCCTOpCodeKernelRefused,OS3DCrashMessage("endpoint loft",failure.GetMessageString()));return nil;
    } catch(...) {return nil;}
}

// Independent numerical evidence from a delivered BRep. Sample positions,
// first/second derivatives and finite differences without reading build metrics.
+ (NSDictionary *)endpointLoftJets:(OCCTShape *)shape {
    OS3DSignalScope signals;
    try {
        OCC_CATCH_SIGNALS
        if(!shape || shape->_shape.IsNull() || OS3DSurfaceCount(shape->_shape,TopAbs_FACE)>128) return @{};
        NSMutableArray *rows=[NSMutableArray array];
        int faceIndex=0;
        for(TopExp_Explorer ex(shape->_shape,TopAbs_FACE);ex.More();ex.Next()) {
            ++faceIndex;TopLoc_Location location;
            Handle(Geom_BSplineSurface) surface=Handle(Geom_BSplineSurface)::DownCast(BRep_Tool::Surface(TopoDS::Face(ex.Current()),location));
            if(surface.IsNull()) continue;
            const double u0=surface->UKnot(surface->FirstUKnotIndex()),u1=surface->UKnot(surface->LastUKnotIndex());
            const double v0=surface->VKnot(surface->FirstVKnotIndex()),v1=surface->VKnot(surface->LastVKnotIndex()),h=(v1-v0)*1e-4;
            if(h<=0 || rows.count>16384) return @{};
            auto pack=[](const gp_XYZ &v) {return @[@(v.X()),@(v.Y()),@(v.Z())];};
            const double stations[]={0,1.0/3,0.5,2.0/3,1};
            for(int station=0;station<5;station++) for(int i=0;i<=16;i++) {
                const int side=station==0 ? 0 : (station==4 ? 1 : -1);
                const double u=u0+(u1-u0)*i/16,v=v0+(v1-v0)*stations[station],step=side==1 ? -h : h;
                gp_Pnt p;gp_Vec du,dv,duu,dvv,duv;surface->D2(u,v,p,du,dv,duu,dvv,duv);
                const gp_Pnt p1=surface->Value(u,v+step),p2=surface->Value(u,v+2*step),p3=surface->Value(u,v+3*step);
                gp_XYZ finiteD1=(p.XYZ()*-3+p1.XYZ()*4-p2.XYZ())/(2*step);
                gp_XYZ finiteD2=(p.XYZ()*2-p1.XYZ()*5+p2.XYZ()*4-p3.XYZ())/(step*step);
                p.Transform(location.Transformation());dv.Transform(location.Transformation());dvv.Transform(location.Transformation());
                finiteD1.Multiply(location.Transformation().VectorialPart());finiteD2.Multiply(location.Transformation().VectorialPart());
                [rows addObject:@{@"face":@(faceIndex),@"side":@(side),@"v_fraction":@(stations[station]),@"u_fraction":@((double)i/16),@"point":pack(p.XYZ()),
                    @"d1":pack(dv.XYZ()),@"d2":pack(dvv.XYZ()),@"finite_d1":pack(finiteD1),@"finite_d2":pack(finiteD2)}];
            }
        }
        return @{@"jets":rows,@"method":@"actual-brep-surface-derivatives-and-one-sided-finite-differences"};
    } catch(...) {return @{};}
}

@end
