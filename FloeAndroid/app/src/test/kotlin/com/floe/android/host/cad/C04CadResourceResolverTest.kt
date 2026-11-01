// SPDX-License-Identifier: MPL-2.0
//
// Focused JVM tests for the C04A source-only viewer helpers. AUTHORED, NOT
// RUN by this lane; real WebView/WASM rendering and App acceptance remain
// Main's unified qualification.
package com.floe.android.host.cad

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class C04CadResourceResolverTest {
    @Test
    fun routesEveryRequiredFormatIncludingNativePackage() {
        val expected = mapOf(
            "dxf" to C04CadFormat.DXF,
            "dwg" to C04CadFormat.DWG,
            "step" to C04CadFormat.STEP,
            "stp" to C04CadFormat.STP,
            "iges" to C04CadFormat.IGES,
            "igs" to C04CadFormat.IGS,
            "brep" to C04CadFormat.BREP,
            "glb" to C04CadFormat.GLB,
            "gltf" to C04CadFormat.GLTF,
            "obj" to C04CadFormat.OBJ,
            "stl" to C04CadFormat.STL,
            "3mf" to C04CadFormat.THREE_MF,
            "floecad" to C04CadFormat.FLOECAD,
        )
        for ((extension, format) in expected) {
            assertEquals(format, C04CadFormat.fromPath("models/part.$extension"))
        }
        assertEquals(C04CadFormat.FLOECAD, C04CadFormat.fromPath("models/part.floecad"))
        assertTrue(C04CadFormat.isNativePackage("models/part.floecad"))
        assertNull(C04CadFormat.fromPath("models/part.unknown"))
    }

    @Test
    fun resolvesOnlyRelativeSidecarsInsideTheMainDirectory() {
        assertEquals(
            "models/textures/a.png",
            C04CadResourceResolver.resolve("textures/a.png", "models").getOrThrow(),
        )
        assertEquals(
            "models/materials/textures/a.png",
            C04CadResourceResolver.resolve("textures/a.png", "models/materials").getOrThrow(),
        )
        assertTrue(C04CadResourceResolver.resolve("../secret.bin", "models").isFailure)
        assertTrue(C04CadResourceResolver.resolve("/etc/passwd", "models").isFailure)
        assertTrue(C04CadResourceResolver.resolve("https://example.com/a.png", "models").isFailure)
        assertTrue(C04CadResourceResolver.resolve("textures\\a.png", "models").isFailure)
        assertTrue(C04CadResourceResolver.resolve("textures/%2e%2e/a.png", "models").isFailure)
        assertTrue(C04CadResourceResolver.resolve("", "models").isFailure)
    }

    @Test
    fun gltfDiscoversBuffersAndImagesButSkipsEmbeddedData() {
        val bytes = """
            {"buffers":[{"uri":"part.bin"}],
             "images":[{"uri":"textures/a.png"},{"uri":"data:image/png;base64,AA=="}]}
        """.trimIndent().toByteArray()
        val result = C04CadResourceResolver.discover(
            C04CadFormat.GLTF, "models/part.gltf", bytes)
        assertEquals(2, result.references.size)
        assertEquals(C04CadReferenceKind.BUFFER, result.references[0].kind)
        assertEquals("part.bin", result.references[0].raw)
        assertEquals(C04CadReferenceKind.IMAGE, result.references[1].kind)
        assertEquals("textures/a.png", result.references[1].raw)
    }

    @Test
    fun gltfReportsRequiredCompressionExtensions() {
        val bytes = """
            {"extensionsRequired":["KHR_draco_mesh_compression"],"buffers":[]}
        """.trimIndent().toByteArray()
        val result = C04CadResourceResolver.discover(
            C04CadFormat.GLTF, "models/part.gltf", bytes)
        assertTrue(result.unsupportedExtensions.contains("KHR_draco_mesh_compression"))
    }

    @Test
    fun objAndMtlExposeMaterialAndTextureReferences() {
        val obj = "mtllib part.mtl\nv 0 0 0\n".toByteArray()
        val objResult = C04CadResourceResolver.discover(
            C04CadFormat.OBJ, "models/part.obj", obj)
        assertEquals(1, objResult.references.size)
        assertEquals("part.mtl", objResult.references[0].raw)

        val mtl = "newmtl a\nmap_Kd -s 1 1 1 textures/a.png\n".toByteArray()
        val mtlResult = C04CadResourceResolver.discoverMtl(mtl)
        assertEquals(1, mtlResult.references.size)
        assertEquals("textures/a.png", mtlResult.references[0].raw)
    }
}
