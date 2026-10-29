//
//  ShaderTypes.h
//  openshape3d
//
//  Shared between Swift (via bridging header) and Metal Shading Language so
//  uniform struct layouts are defined exactly once. simd types only; no
//  matrix_float3x3 (its Swift/MSL layouts differ).
//
//  ABI CONTRACT: this file and Sources/FloeCAD/Shaders/ShaderTypes.h are
//  BYTE-IDENTICAL. The runtime MSL compile in RenderContext inlines the
//  resource-bundle copy into Shaders.metal while Swift sees the OCCTShim copy;
//  if the two diverge, `BodyUniforms` fields silently land at different
//  offsets. Change both (or copy one onto the other) in the same edit.
//
//  BodyUniforms layout (size 128; offsets 0/64/80/84/88/92/96/112/116/120/124
//  for modelMatrix, baseColor, selectionState, metallic, roughness,
//  lineHalfWidthPx, emissive, textureFlags, flipVFlags, srgbFlags,
//  normalStrength) is enforced by the sizeof `static_assert` in Shaders.metal
//  plus the private C/Swift ABI probe in Local/Private/.../cad-shaders.
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

// One bit per material image slot. The bit order is the Swift
// `MaterialTextureSlot.allCases` order (baseColor, metallic, roughness,
// normal, emissive, opacity); a slot's bit states whether that map is bound
// and sampled for the current draw.
typedef enum {
    BodyTextureFlagBaseColor = 1u << 0,
    BodyTextureFlagMetallic  = 1u << 1,
    BodyTextureFlagRoughness = 1u << 2,
    BodyTextureFlagNormal    = 1u << 3,
    BodyTextureFlagEmissive  = 1u << 4,
    BodyTextureFlagOpacity   = 1u << 5,
} BodyTextureFlag;

// Fragment `[[texture(n)]]` index for each image slot. Every slot is bound on
// every textured draw (a neutral 1x1 fallback fills an absent slot) so the
// fragment function never samples an unbound texture.
typedef enum {
    BodyTextureIndexBaseColor = 0,
    BodyTextureIndexMetallic  = 1,
    BodyTextureIndexRoughness = 2,
    BodyTextureIndexNormal    = 3,
    BodyTextureIndexEmissive  = 4,
    BodyTextureIndexOpacity   = 5,
} BodyTextureIndex;

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
    vector_float4 lightParams;         // x: key intensity scale (>0 enables the
                                       // legacy rig), y: fill intensity scale,
                                       // z: legacy rig active (0 = CAD headlight),
                                       // w: flat background (skip vignette)
    vector_float4 fillLightPosition;   // xyz: fill light world position (mm),
                                       // w: attenuation radius (mm)
} FrameUniforms;

typedef struct {
    matrix_float4x4 modelMatrix;       // uniform scale + rotation + translation
    vector_float4 baseColor;           // rgb factor; a = effective opacity
    unsigned int selectionState;       // SelectionState
    float metallic;                    // 0 (default) = dielectric, white highlight
    float roughness;                   // 0 (default) = legacy fixed highlight; >0 mapped
    float lineHalfWidthPx;             // thick-line pipeline: half stroke width

    // Custom PBR material. Every field below is ZERO on a flat/legacy body,
    // so the pre-material shading path is unchanged byte for byte.
    vector_float4 emissive;            // xyz: emissive factor in the renderer's
                                       // working space; w: strength (0 = off)
    unsigned int textureFlags;         // BodyTextureFlag bits actually sampled
    unsigned int flipVFlags;           // BodyTextureFlag bits whose image rows
                                       // are bottom-up (sample v -> 1 - v)
    unsigned int srgbFlags;            // BodyTextureFlag bits authored as sRGB
                                       // (unset = linear data, e.g. roughness)
    float normalStrength;              // 1 when a normal map is sampled, else 0
} BodyUniforms;

#endif /* ShaderTypes_h */
