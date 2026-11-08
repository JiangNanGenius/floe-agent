#ifndef FLOE_FIELDS_MFEM_H
#define FLOE_FIELDS_MFEM_H

/*
 Floe serial MFEM field-solver bridge (CPU, double precision, no MPI).

 Provides a small, stable C ABI over a pinned MFEM build for:
   - electrostatics  (Laplace -div(eps grad V) = 0, Dirichlet potential / PEC / PMC)
   - pressure acoustics frequency response (Helmholtz with complex k, pressure /
     normal-velocity / impedance / first-order-radiation boundaries)

 The bridge never calls exit/abort/chdir/fork or spawns processes; MFEM errors
 are thrown as C++ exceptions internally and returned as status codes with a
 per-session message. All values are SI. Output buffers are caller-owned and sized using
 floe_fields_mfem_mesh_sizes; a NULL output skips copying that field.
 */

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FloeFieldsMFEMSession FloeFieldsMFEMSession;

typedef enum FloeFieldsMFEMStatus {
    kFloeFieldsOk = 0,
    kFloeFieldsErrInvalidInput = 1,
    kFloeFieldsErrUnsupported = 2,
    kFloeFieldsErrSolver = 3,
    kFloeFieldsErrCancelled = 4,
    kFloeFieldsErrNoMemory = 5
} FloeFieldsMFEMStatus;

/* Electromagnetic boundary kinds (subset of the shared field configuration). */
typedef enum FloeFieldsEMBoundaryKind {
    kFloeFieldsEMPerfectElectric = 0,   /* Dirichlet V = 0                */
    kFloeFieldsEMPerfectMagnetic = 1,   /* natural (homogeneous Neumann)  */
    kFloeFieldsEMRadiation = 2,         /* unsupported for electrostatics */
    kFloeFieldsEMAbsorbingLayer = 3,    /* unsupported                    */
    kFloeFieldsEMElectricPotential = 4, /* Dirichlet V = value.real       */
    kFloeFieldsEMSurfaceCurrent = 5     /* unsupported for electrostatics */
} FloeFieldsEMBoundaryKind;

/* Acoustic boundary kinds. */
typedef enum FloeFieldsAcousticBoundaryKind {
    kFloeFieldsAcRigidWall = 0,      /* homogeneous Neumann              */
    kFloeFieldsAcPressure = 1,       /* Dirichlet p = value (complex)    */
    kFloeFieldsAcNormalVelocity = 2, /* d p/d n = -i*omega*rho*v_n       */
    kFloeFieldsAcImpedance = 3,      /* Robin, Z = value.real (Pa*s/m)   */
    kFloeFieldsAcRadiation = 4       /* first-order, Z = rho*c           */
} FloeFieldsAcousticBoundaryKind;

FloeFieldsMFEMSession *floe_fields_mfem_create(void);
void floe_fields_mfem_destroy(FloeFieldsMFEMSession *session);

/* Returns a static version string, e.g. "mfem 4.8.0 / floe-fields 1". */
const char *floe_fields_mfem_version(void);

/* Copy the session's last error message (empty string when none). */
void floe_fields_mfem_last_error(const FloeFieldsMFEMSession *session,
                                 char *buffer, int bufferCapacity);

/*
 Sets a tetrahedral mesh from raw arrays.
   coords:        nodeCount*3 interleaved xyz (meters), nodeCount >= 4
   tets:          tetCount*4 zero-based node indices, positive orientation
   regionIDs:     regionCount C strings; regionPerTet maps each tet to an index
   bdrTris:       bdrTriCount*3 node indices (surface facets)
   boundaryIDs:   boundaryCount C strings; boundaryPerTri maps each triangle
 Any previously set mesh, materials and boundaries are discarded.
 */
int floe_fields_mfem_set_mesh(FloeFieldsMFEMSession *session,
                              const double *coords, int nodeCount,
                              const int *tets, int tetCount,
                              const char *const *regionIDs,
                              const int *regionPerTet, int regionCount,
                              const int *bdrTris, int bdrTriCount,
                              const char *const *boundaryIDs,
                              const int *boundaryPerTri, int boundaryCount);

/* Per-region electromagnetic material (SI). regionID must match set_mesh. */
int floe_fields_mfem_add_em_material(FloeFieldsMFEMSession *session,
                                     const char *regionID,
                                     double epsilonR, double muR,
                                     double sigmaSiemensPerMeter);

/* Per-region acoustic medium (SI). */
int floe_fields_mfem_add_acoustic_medium(FloeFieldsMFEMSession *session,
                                         const char *regionID,
                                         double densityKgPerM3,
                                         double soundSpeedMetersPerSecond,
                                         double lossFactor);

int floe_fields_mfem_add_em_boundary(FloeFieldsMFEMSession *session,
                                     const char *boundaryID,
                                     int kind, double valueReal, double valueImag);

int floe_fields_mfem_add_acoustic_boundary(FloeFieldsMFEMSession *session,
                                           const char *boundaryID,
                                           int kind,
                                           double valueReal, double valueImag);

void floe_fields_mfem_set_acoustic_reference_pressure(
    FloeFieldsMFEMSession *session, double referencePressurePascal);

/* Request cancellation of the in-flight solve; checked at phase boundaries. */
void floe_fields_mfem_cancel(FloeFieldsMFEMSession *session);
void floe_fields_mfem_clear_cancel(FloeFieldsMFEMSession *session);

/*
 Solves -div(eps grad V) = 0 with the configured boundaries.
 Outputs (all optional; NULL skips copying):
   potential:        nodeCount                (V)
   electricField:    elementCount*3           (V/m, elementwise)
   electricFlux:     elementCount*3           (C/m^2, elementwise)
 Scalars: energyJoules, capacitanceFarads (nonzero only when >= 2 distinct
 Dirichlet potentials are applied: C = 2*W/dV^2), residual (solver), seconds.
 */
int floe_fields_mfem_solve_electrostatic(FloeFieldsMFEMSession *session,
                                         int feOrder, double relTol,
                                         int maxIterations,
                                         double *potential,
                                         double *electricField,
                                         double *electricFlux,
                                         double *energyJoules,
                                         double *capacitanceFarads,
                                         double *residual,
                                         double *solveSeconds);

/*
 Solves the Helmholtz frequency response at one frequency.
 Outputs (NULL skips copying):
   pressureReal/Imag: nodeCount            (Pa)
   velocityReal/Imag: elementCount*3       (m/s, elementwise)
   soundPressureLevel: nodeCount           (dB re reference pressure)
 Scalars: residual, seconds.
 */
int floe_fields_mfem_solve_acoustic(FloeFieldsMFEMSession *session,
                                    double frequencyHz,
                                    int feOrder, double relTol,
                                    int maxIterations,
                                    double *pressureReal,
                                    double *pressureImag,
                                    double *velocityReal,
                                    double *velocityImag,
                                    double *soundPressureLevel,
                                    double *residual,
                                    double *solveSeconds);

/* Convenience: node/element counts of the current mesh (0 when unset). */
void floe_fields_mfem_mesh_sizes(const FloeFieldsMFEMSession *session,
                                 int *nodeCount, int *elementCount);

/* Additive ABI 3: isotropic tet4 transient heat, SI, backward Euler.
 rhoCp is volumetric heat capacity (J/(m^3 K)); heat sources are W/m^3.
 Flux is positive OUT of the domain; convection uses h (W/(m^2 K)), ambient K.
 Set mesh/media/constant boundaries before begin. Begin projects prescribed
 vertex temperatures into the initial state; step advances only after success.
 Output arrays, when non-NULL, have nodeCount temperatures and tetCount*3 fluxes.
 Energy is J relative to zero Kelvin; boundaryInW is positive INTO the domain.
 A failed/cancelled step retains the last accepted state; rebuild after edits.
 No standalone process, ambient paths, new upstream dependencies or MPI. */
int floe_fields_mfem_add_thermal_material(FloeFieldsMFEMSession *,const char *,double k,double rhoCp,double sourceWPerM3);
int floe_fields_mfem_add_thermal_temperature(FloeFieldsMFEMSession *,int node,double kelvin);
int floe_fields_mfem_add_thermal_flux(FloeFieldsMFEMSession *,const char *,double outwardWPerM2);
int floe_fields_mfem_add_thermal_convection(FloeFieldsMFEMSession *,const char *,double h,double ambientK);
int floe_fields_mfem_thermal_begin(FloeFieldsMFEMSession *,double initialKelvin,double *temperature,double *heatFlux,double *energyJ);
int floe_fields_mfem_thermal_step(FloeFieldsMFEMSession *,double stepSeconds,double relativeTolerance,int maximumIterations,double *temperature,double *heatFlux,double *energyJ,double *sourceW,double *boundaryInW,double *energyResidualW,double *relativeResidual,double *solveSeconds);

#ifdef __cplusplus
}
#endif

#endif /* FLOE_FIELDS_MFEM_H */
