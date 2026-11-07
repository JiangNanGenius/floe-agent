#ifndef FLOE_MESHING_NATIVE_H
#define FLOE_MESHING_NATIVE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct FloeMeshingSession FloeMeshingSession;
/* Status: 0 success, 1 input, 2 unsupported, 3 mesher, 4 cancelled, 5 budget. */
FloeMeshingSession *floe_mesh_create(void);
void floe_mesh_destroy(FloeMeshingSession *session);
const char *floe_mesh_version(void);
int floe_mesh_supports_brep(void);
const char *floe_mesh_error(const FloeMeshingSession *session);
void floe_mesh_cancel(FloeMeshingSession *session);
int floe_mesh_set_brep(FloeMeshingSession *session,const uint8_t *bytes,size_t length,double lengthToMeters,const char *identityPrefix);
/* kind: 0 face, 1 solid, 2 edge. Index is one-based inside the supplied B-rep. */
int floe_mesh_set_entity(FloeMeshingSession *session,int kind,int index,const char *sourceID,const char *regionID);
/* A surface is already in SI, outward oriented, closed and manifold per region.
   Zero-based triangles carry material-region and source-boundary attributes. */
int floe_mesh_set_surface(FloeMeshingSession *session,const double *xyz,int nodes,const int *triangles,int faces,const int *regions,const char *const *regionIDs,int regionCount,const int *tags,const char *const *boundaryIDs,int boundaryCount);
int floe_mesh_set_local_size(FloeMeshingSession *session,const char *sourceID,double meters);
int floe_mesh_run(FloeMeshingSession *session,double maximumSize,double minimumSize,double growth,int curvature,int maximumNodes,int maximumElements);
int floe_mesh_node_count(const FloeMeshingSession *session);
int floe_mesh_element_count(const FloeMeshingSession *session);
int floe_mesh_face_count(const FloeMeshingSession *session);
int floe_mesh_region_count(const FloeMeshingSession *session);
int floe_mesh_boundary_count(const FloeMeshingSession *session);
/* Borrowed immutable buffers remain valid until destroy or the next run. */
const double *floe_mesh_nodes(const FloeMeshingSession *session);
const int *floe_mesh_tetrahedra(const FloeMeshingSession *session);
const int *floe_mesh_regions(const FloeMeshingSession *session);
const int *floe_mesh_triangles(const FloeMeshingSession *session);
const int *floe_mesh_boundaries(const FloeMeshingSession *session);
const char *floe_mesh_region_id(const FloeMeshingSession *session,int index);
const char *floe_mesh_boundary_id(const FloeMeshingSession *session,int index);
#ifdef __cplusplus
}
#endif
#endif
