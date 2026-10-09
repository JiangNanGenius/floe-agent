//
//  ShaderTypes.h
//  openshape3d
//
//  Shared between Swift (via bridging header) and Metal Shading Language so
//  uniform struct layouts are defined exactly once. simd types only; no
//  matrix_float3x3 (its Swift/MSL layouts differ).
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

typedef enum {
    BufferIndexPositions = 0,
    BufferIndexNormals = 1,
    BufferIndexFrameUniforms = 2,
    BufferIndexBodyUniforms = 3,
    BufferIndexTexcoords = 4,
} BufferIndex;

typedef enum {
    SelectionStateNone = 0,
    SelectionStateSelected = 1,
    SelectionStateHovered = 2,
    SelectionStatePreview = 3,
} SelectionState;

typedef struct {
    matrix_float4x4 viewProjectionMatrix;
    vector_float4 cameraPosition;      // xyz used
    vector_float4 keyLightDirection;   // xyz used, normalized, world space
    vector_float4 skyColor;            // hemisphere ambient top
    vector_float4 groundColor;         // hemisphere ambient bottom
    vector_float4 backgroundTop;
    vector_float4 backgroundBottom;
    vector_float4 accentColor;         // selection highlight
    vector_float4 gridParams;          // x: minor spacing, y: major every N, z: fade distance, w: unused
    vector_float4 gridCenter;          // xyz: world position the grid quad is centered on
    vector_float4 gridOrigin;          // sketch coordinate origin in world space
    vector_float4 gridXAxis;           // orthonormal in-plane basis
    vector_float4 gridYAxis;
    vector_float4 clipPlane;           // section view: xyz unit normal, w offset;
                                       // fragments with dot(p, xyz) + w < 0 are discarded
    float edgeDepthBiasNDC;
    float clipEnabled;                 // 0 = section view off (default)
    float viewportWidth;               // drawable pixels — thick lines expand in
    float viewportHeight;              // screen space, so they need the size
} FrameUniforms;

typedef struct {
    matrix_float4x4 modelMatrix;       // uniform scale + rotation + translation
    vector_float4 baseColor;
    unsigned int selectionState;       // SelectionState
    float metallic;                    // 0 (default) = dielectric, white highlight
    float roughness;                   // 0 (default) = legacy fixed highlight; >0 mapped
    float lineHalfWidthPx;             // thick-line pipeline: half stroke width
} BodyUniforms;

#endif /* ShaderTypes_h */
