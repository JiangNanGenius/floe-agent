// SPDX-License-Identifier: MPL-2.0
//
// C04A closed format routing. The extension -> reader mapping is verified
// against the pinned donor sources (not a marketing format list):
//
//  * dxf.js exports `DxfViewer` (dxf-viewer 1.0.48) and `dxf-worker.js`
//    calls `DxfViewer.SetupWorker()`; it reads DXF only.
//  * floe_cad_engine.js wraps `CadSession(bytes, "dxf"|"dwg")`; Rust
//    `read()` in ThirdParty/CADEngine/src/lib.rs accepts exactly "dxf" and
//    "dwg", and `display_dxf()` produces the render projection.
//  * occt-worker.js calls `ReadStepFile`, `ReadIgesFile` or `ReadBrepFile`
//    on occt-import-js 0.0.23 and returns a bounded STL display mesh.
//  * mesh.js `CanImportExtension` accepts exactly stl, obj, gltf, glb and
//    3mf for the required set; its own OCCT/FBX/Draco paths are NOT used
//    because they load external CDN libraries.
//
// `.floecad` is the native directory package read by C04FloecadPackage; it is
// routed through the derived-GLB preview path, never through a ZIP/container
// guess or the intermediate `floe.cad-package/1` metadata schema.
package com.floe.android.host.cad

import java.util.Locale

private val C04_MESH_RESOURCE_EXTENSIONS = setOf("bin", "mtl", "png", "jpg", "jpeg", "webp")

internal enum class C04CadFamily {
    VECTOR_2D,
    SURFACE_3D,
    MESH_3D,
}

internal enum class C04CadFormat(
    val extension: String,
    val family: C04CadFamily,
    val reader: String,
    val maxSourceBytes: Long,
    val mimeType: String,
    val resourceExtensions: Set<String> = emptySet(),
) {
    DXF("dxf", C04CadFamily.VECTOR_2D, "dxf-viewer/1.0.48", 64L shl 20, "application/dxf"),
    DWG("dwg", C04CadFamily.VECTOR_2D, "floe-cad-engine/acadrust-0.5.5", 10L shl 20, "application/acad"),
    STEP("step", C04CadFamily.SURFACE_3D, "occt-import-js/0.0.23", 10L shl 20, "application/step"),
    STP("stp", C04CadFamily.SURFACE_3D, "occt-import-js/0.0.23", 10L shl 20, "application/step"),
    IGES("iges", C04CadFamily.SURFACE_3D, "occt-import-js/0.0.23", 10L shl 20, "model/iges"),
    IGS("igs", C04CadFamily.SURFACE_3D, "occt-import-js/0.0.23", 10L shl 20, "model/iges"),
    BREP("brep", C04CadFamily.SURFACE_3D, "occt-import-js/0.0.23", 10L shl 20, "application/octet-stream"),
    GLB("glb", C04CadFamily.MESH_3D, "online-3d-viewer/0.18.0", 64L shl 20, "model/gltf-binary",
        C04_MESH_RESOURCE_EXTENSIONS),
    GLTF("gltf", C04CadFamily.MESH_3D, "online-3d-viewer/0.18.0", 64L shl 20, "model/gltf+json",
        C04_MESH_RESOURCE_EXTENSIONS),
    OBJ("obj", C04CadFamily.MESH_3D, "online-3d-viewer/0.18.0", 64L shl 20, "text/plain",
        C04_MESH_RESOURCE_EXTENSIONS),
    STL("stl", C04CadFamily.MESH_3D, "online-3d-viewer/0.18.0", 64L shl 20, "model/stl",
        C04_MESH_RESOURCE_EXTENSIONS),
    THREE_MF("3mf", C04CadFamily.MESH_3D, "online-3d-viewer/0.18.0", 64L shl 20, "model/3mf",
        C04_MESH_RESOURCE_EXTENSIONS),
    FLOECAD("floecad", C04CadFamily.MESH_3D, "floecad-package/1", 512L shl 20,
        "application/vnd.floe.cad.package",
        setOf("json", "mesh", "brep", "img", "png", "jpg", "jpeg", "webp")),
    ;

    val label: String get() = extension.uppercase(Locale.ROOT)

    val wireName: String
        get() = when (family) {
            C04CadFamily.VECTOR_2D -> "vector2d"
            C04CadFamily.SURFACE_3D -> "surface3d"
            C04CadFamily.MESH_3D -> "mesh3d"
        }

    val acceptsSidecars: Boolean get() = family == C04CadFamily.MESH_3D

    val workspaceExtensions: Set<String>
        get() = when (this) {
            STEP, STP -> setOf("step", "stp")
            IGES, IGS -> setOf("iges", "igs")
            FLOECAD -> setOf("json", "mesh", "brep", "img")
            else -> setOf(extension)
        }

    companion object {
        /** Extension-only route, mirroring the Swift domain. Content is
         * proved by the actual pinned reader, never by this table. */
        fun fromPath(relativePath: String): C04CadFormat? {
            val name = relativePath.substringAfterLast('/')
            val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
            return entries.firstOrNull { it.extension == extension }
        }

        fun isNativePackage(relativePath: String): Boolean =
            relativePath.substringAfterLast('.', "").equals("floecad", ignoreCase = true)
    }
}

internal object C04CadLimits {
    const val MAX_RESOURCES = 32
    const val MAX_RESOURCE_BYTES = 64L shl 20
    const val MAX_TOTAL_RESOURCE_BYTES = 256L shl 20
    const val MAX_PATH_BYTES = 4096
    const val MAX_CAPTURE_BYTES = 24L shl 20
    const val MAX_CAPTURE_EVENT_BYTES = 40L shl 20
    const val MAX_CAPTURE_EDGE = 8192
    const val MIN_CAPTURE_EDGE = 64
    const val MAX_RESOURCE_COUNT_FOR_MANIFEST = MAX_RESOURCES
    /** The native package session is aggregated to one derived GLB; these are
     * the structural reader caps, not C04A's single-file sidecar budget. */
    const val MAX_FLOECAD_FILES = C04FloecadLimits.MAX_FILES
    const val MAX_FLOECAD_PREVIEW_BYTES = C04FloecadLimits.MAX_PREVIEW_BYTES
    const val MAX_PREFLIGHT_BYTES = 16L shl 20
    const val MAX_MTL_BYTES = 1L shl 20
    const val SESSION_TTL_MILLIS = 15 * 60 * 1000L
    const val MAX_SESSIONS = 4
}

/** Image/media type allowlist used for native-egress sidecars. The extension
 * is checked by the resolver; this map is only the Content-Type handed to the
 * local-only WebView. */
internal fun c04MimeType(relativePath: String): String =
    when (relativePath.substringAfterLast('.', "").lowercase(Locale.ROOT)) {
        "png" -> "image/png"
        "jpg", "jpeg" -> "image/jpeg"
        "webp" -> "image/webp"
        "bin" -> "application/octet-stream"
        "mtl" -> "text/x-mtl"
        "glb" -> "model/gltf-binary"
        "gltf" -> "model/gltf+json"
        "obj" -> "text/plain"
        "stl" -> "model/stl"
        "3mf" -> "model/3mf"
        "floecad" -> "application/vnd.floe.cad.package"
        "step", "stp" -> "application/step"
        "iges", "igs" -> "model/iges"
        "dxf" -> "application/dxf"
        "dwg" -> "application/acad"
        else -> "application/octet-stream"
    }
