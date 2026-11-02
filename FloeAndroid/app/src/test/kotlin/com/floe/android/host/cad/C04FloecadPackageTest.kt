// SPDX-License-Identifier: MPL-2.0
//
// C04B focused JVM tests for the ACTUAL native `.floecad` directory reader and
// derived-GLB builder. AUTHORED, NOT RUN by this source-only lane. Device
// WebView rendering/capture and App entry remain Main's unified qualification.
package com.floe.android.host.cad

import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class C04FloecadPackageTest {
    private val root = "Models/Part.floecad"
    private val bodyID = "B61A7FB4-2F24-4334-811F-7C0CE642C305"
    private val imageID = "8EC485EE-C72E-4AA0-A94E-3B30BF9B2DB0"
    private val png = Base64.getDecoder().decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lK3u+QAAAABJRU5ErkJggg==")

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun base64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    private fun transform(translation: List<Double> = listOf(0.0, 0.0, 0.0)): String =
        base64(buildJsonObject {
            put("translation", buildJsonArray { translation.forEach { add(JsonPrimitive(it)) } })
            put("rotation", buildJsonArray { listOf(0.0, 0.0, 0.0, 1.0).forEach { add(JsonPrimitive(it)) } })
            put("scale", 1.0)
        }.toString().toByteArray())

    private fun imageInfo(): String = base64(buildJsonObject {
        put("id", buildJsonObject { put("raw", imageID) })
        put("name", "Reference")
        put("plane", buildJsonObject {
            put("origin", buildJsonArray { listOf(0.0, 0.0, 0.0).forEach { add(JsonPrimitive(it)) } })
            put("xAxis", buildJsonArray { listOf(1.0, 0.0, 0.0).forEach { add(JsonPrimitive(it)) } })
            put("yAxis", buildJsonArray { listOf(0.0, 0.0, -1.0).forEach { add(JsonPrimitive(it)) } })
        })
        put("width", 20.0)
        put("height", 10.0)
        put("opacity", 1.0)
        put("isHidden", false)
    }.toString().toByteArray())

    private fun mesh(version: Int = 1, vertices: Int = 3, indices: IntArray = intArrayOf(0, 1, 2)): ByteArray {
        val buffer = ByteBuffer.allocate(
            16 + vertices * 24 + indices.size * 4 + if (version == 2) vertices * 8 else 0,
        ).order(ByteOrder.LITTLE_ENDIAN)
        buffer.putInt(0x4F533344)
        buffer.putInt(version)
        buffer.putInt(vertices)
        buffer.putInt(indices.size)
        for (index in 0 until vertices) {
            buffer.putFloat(index.toFloat()); buffer.putFloat(0f); buffer.putFloat(0f)
        }
        repeat(vertices) {
            buffer.putFloat(0f); buffer.putFloat(1f); buffer.putFloat(0f)
        }
        indices.forEach { buffer.putInt(it) }
        if (version == 2) {
            repeat(vertices) { buffer.putFloat(0f); buffer.putFloat(1f) }
        }
        return buffer.array()
    }

    private data class Fixture(
        val files: MutableMap<String, ByteArray>,
        val manifest: JsonObject,
        val document: JsonObject,
        val mesh: ByteArray,
    )

    private fun fixture(
        withImage: Boolean = false,
        withAssembly: Boolean = false,
        withBRepOnly: Boolean = false,
        version: Int = 1,
        translation: List<Double> = listOf(0.0, 0.0, 0.0),
        thumbnailSHA: String? = null,
        meshBytesOverride: ByteArray? = null,
        imageBytes: ByteArray = png,
    ): Fixture {
        val meshBytes = meshBytesOverride ?: mesh(version)
        val meshPath = "blobs/$bodyID.mesh"
        val meshSha = sha(meshBytes)
        val brepBytes = "FloeBRep".toByteArray()
        val brepPath = "blobs/$bodyID.brep"
        val brepSha = sha(brepBytes)
        val files = LinkedHashMap<String, ByteArray>()
        files["$root/manifest.json"] = ByteArray(0) // replaced below
        files["$root/document.json"] = ByteArray(0)
        files["$root/$brepPath"] = brepBytes
        if (!withBRepOnly) files["$root/$meshPath"] = meshBytes
        val imagePath = "blobs/images/$imageID.img"
        if (withImage) files["$root/$imagePath"] = imageBytes
        val bodies = buildJsonArray {
            add(buildJsonObject {
                put("bodyID", bodyID)
                put("name", "Body")
                put("transform", transform(translation))
                if (!withBRepOnly) {
                    put("meshBlob", meshPath)
                    put("meshSHA256", meshSha)
                }
                put("brepBlob", brepPath)
                put("brepSHA256", brepSha)
                put("isHidden", false)
            })
        }
        val images = buildJsonArray {
            if (withImage) {
                add(buildJsonObject {
                    put("imageID", imageID)
                    put("info", imageInfo())
                    put("imageBlob", imagePath)
                    put("imageSHA256", sha(imageBytes))
                })
            }
        }
        val assembly = if (withAssembly) {
            base64(buildJsonObject {
                put("instances", buildJsonArray {
                    add(buildJsonObject {
                        put("id", UUID.randomUUID().toString())
                        put("name", "Placed")
                        put("bodyID", bodyID)
                        put("transform", buildJsonObject {
                            put("position", buildJsonArray { listOf(10.0, 0.0, 0.0).forEach { add(JsonPrimitive(it)) } })
                            put("rotation", buildJsonArray { listOf(0.0, 0.0, 0.0, 1.0).forEach { add(JsonPrimitive(it)) } })
                            put("scale", buildJsonArray { listOf(1.0, 1.0, 1.0).forEach { add(JsonPrimitive(it)) } })
                        })
                        put("isHidden", false)
                    })
                })
            }.toString().toByteArray())
        } else null
        val document = buildJsonObject {
            put("bodies", bodies)
            put("images", images)
            put("sketches", JsonArray(emptyList<JsonElement>()))
            put("planes", JsonArray(emptyList<JsonElement>()))
            put("axes", JsonArray(emptyList<JsonElement>()))
            put("symbols", JsonArray(emptyList<JsonElement>()))
            put("features", JsonArray(emptyList<JsonElement>()))
            put("variables", JsonArray(emptyList<JsonElement>()))
            if (assembly != null) put("assembly", assembly)
            put("futureField", buildJsonObject { put("ignored", true) })
        }
        val documentBytes = document.toString().toByteArray()
        files["$root/document.json"] = documentBytes
        val blobs = listOfNotNull(
            if (withBRepOnly) null else meshPath to meshSha,
            brepPath to brepSha,
            if (withImage) imagePath to sha(imageBytes) else null,
        )
        val content = digest(documentBytes, blobs, thumbnailSHA)
        val manifest = buildJsonObject {
            put("schemaVersion", 3)
            put("revision", 6)
            put("name", "Part")
            put("contentSHA256", content)
            put("modelSHA256", "a".repeat(64))
            thumbnailSHA?.let { put("thumbnailSHA256", it) }
            put("appBuild", "FloeCAD/test")
            put("unit", "mm")
            put("tolerance", 0.001)
            put("counts", buildJsonObject { put("bodies", 1); put("images", if (withImage) 1 else 0) })
            put("futureField", buildJsonObject { put("ignored", true) })
        }
        files["$root/manifest.json"] = manifest.toString().toByteArray()
        return Fixture(files, manifest, document, meshBytes)
    }

    private fun digest(document: ByteArray, blobs: List<Pair<String, String>>, thumbnail: String?): String {
        val hasher = MessageDigest.getInstance("SHA-256")
        hasher.update(document)
        blobs.sortedBy { it.first }.forEach { (path, sha) ->
            hasher.update(path.toByteArray()); hasher.update(sha.toByteArray())
        }
        if (thumbnail != null) hasher.update(thumbnail.toByteArray())
        return hasher.digest().joinToString("") { "%02x".format(it) }
    }

    private class MemorySource(
        private val files: MutableMap<String, ByteArray>,
        private val root: File,
        var secondManifest: ByteArray? = null,
        var forceWrongSha: Boolean = false,
        var stages: Int = 0,
        var current: () -> Boolean = { true },
    ) : C04FloecadSource {
        override fun stage(relativePath: String, maxBytes: Long): C04FloecadStaged {
            if (!current()) throw C04FloecadFailure("ownerChanged", "owner")
            stages += 1
            var bytes = files[relativePath] ?: throw C04FloecadFailure("resourceMissing", relativePath)
            if (relativePath.endsWith("/manifest.json") && stages > 1 && secondManifest != null) {
                bytes = secondManifest!!
            }
            if (bytes.size.toLong() > maxBytes) throw C04FloecadFailure("previewTooLarge", "bytes")
            val file = File(root, "stage-${UUID.randomUUID()}.bin")
            file.writeBytes(bytes)
            val actual = MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it) }
            return C04FloecadStaged(
                relativePath, file, bytes.size.toLong(),
                if (forceWrongSha) "0".repeat(64) else actual,
            )
        }
    }

    private fun tempRoot(): File = Files.createTempDirectory("c04b-floecad-test").toFile()

    private fun read(
        fixture: Fixture,
        decoder: C04FloecadImageDecoder? = null,
        mutate: (MemorySource) -> Unit = {},
    ): C04FloecadPreview {
        val root = tempRoot()
        val source = MemorySource(fixture.files, root)
        mutate(source)
        return C04FloecadPackageReader(source, File(root, "preview"), decoder).read(this.root) {
            source.current()
        }
    }

    private fun expectFailure(code: String, block: () -> Unit): C04FloecadFailure {
        try {
            block()
            fail("expected $code")
        } catch (error: C04FloecadFailure) {
            assertEquals(code, error.code)
            return error
        }
        error("unreachable")
    }

    @Test
    fun readsActualManifestDocumentAndBuildsDerivedGlb() {
        val fixture = fixture(withImage = true, withAssembly = true)
        val before = fixture.files.toMap()
        val preview = read(fixture)
        assertEquals(1, preview.bodyCount)
        assertEquals(1, preview.imageCount)
        assertEquals(1, preview.assemblyInstanceCount)
        assertEquals(3, preview.meshCount) // body + placed instance + image
        assertTrue(preview.derivedFile.isFile)
        assertEquals(preview.derivedBytes, preview.derivedFile.length())
        assertEquals(preview.derivedSha256, sha(preview.derivedFile.readBytes()))
        val glb = parseGlb(preview.derivedFile.readBytes())
        val extras = glb["asset"]!!.jsonObject["extras"]!!.jsonObject
        assertEquals("floecad", extras["sourceFormat"]!!.jsonPrimitive.content)
        assertEquals("m", extras["unit"]!!.jsonPrimitive.content)
        assertEquals("mm", extras["sourceUnit"]!!.jsonPrimitive.content)
        assertEquals(2, glb["meshes"]!!.jsonArray.size)
        assertEquals(3, glb["nodes"]!!.jsonArray.size)
        val placedMatrix = glb["nodes"]!!.jsonArray[2].jsonObject["matrix"]!!.jsonArray
        assertEquals(0.01, placedMatrix[12].jsonPrimitive.content.toDouble(), 0.000001)
        assertEquals(4, preview.triangleCount)
        assertEquals(10, preview.vertexCount)
        assertEquals(-10.0, preview.boundsMinimum[0], 0.0001)
        assertEquals(12.0, preview.boundsMaximum[0], 0.0001)
        assertTrue(preview.limitations.contains("Derived read-only preview"))
        assertTrue(preview.limitations.contains("normalized to metres"))
        assertTrue(preview.limitations.contains("Assembly placements"))
        assertEquals(before.keys, fixture.files.keys)
        assertTrue(before["$root/document.json"]!!.contentEquals(fixture.files["$root/document.json"]!!))
    }

    @Test
    fun reopensTheSamePackageWithoutRewritingAnyOriginalByte() {
        val fixture = fixture(withImage = true)
        val before = fixture.files.mapValues { (_, value) -> value.copyOf() }
        val first = read(fixture)
        val second = read(fixture)
        assertTrue(first.derivedFile.isFile)
        assertTrue(second.derivedFile.isFile)
        assertEquals(first.contentSHA256, second.contentSHA256)
        assertEquals(before.keys, fixture.files.keys)
        before.forEach { (path, bytes) ->
            assertTrue("original byte changed: $path", bytes.contentEquals(fixture.files[path]))
        }
    }

    @Test
    fun versionOneMeshAndNonIdentityDocumentTransformAreIndependent() {
        val fixture = fixture(version = 1, translation = listOf(10.0, 20.0, 30.0))
        val preview = read(fixture)
        val glb = parseGlb(preview.derivedFile.readBytes())
        val matrix = glb["nodes"]!!.jsonArray[0].jsonObject["matrix"]!!.jsonArray
        assertEquals(0.01, matrix[12].jsonPrimitive.content.toDouble(), 0.000001)
        assertEquals(0.02, matrix[13].jsonPrimitive.content.toDouble(), 0.000001)
        assertEquals(0.03, matrix[14].jsonPrimitive.content.toDouble(), 0.000001)
        // Source-space bounds stay in the native millimetres.
        assertEquals(10.0, preview.boundsMinimum[0], 0.0001)
        assertEquals(12.0, preview.boundsMaximum[0], 0.0001)
    }

    @Test
    fun versionTwoMeshKeepsTextureCoordinates() {
        val fixture = fixture(version = 2)
        val preview = read(fixture)
        val glb = parseGlb(preview.derivedFile.readBytes())
        val primitive = glb["meshes"]!!.jsonArray[0].jsonObject["primitives"]!!.jsonArray[0].jsonObject
        assertTrue(primitive["attributes"]!!.jsonObject.containsKey("TEXCOORD_0"))
    }

    @Test
    fun rejectsTruncatedCorruptAndOutOfRangeMeshes() {
        val complete = mesh()
        expectFailure("invalidPackage") {
            read(fixture(meshBytesOverride = complete.copyOf(complete.size - 1)))
        }
        val badMagic = complete.copyOf()
        badMagic[0] = 0
        expectFailure("invalidPackage") {
            read(fixture(meshBytesOverride = badMagic))
        }
        expectFailure("invalidPackage") {
            read(fixture(meshBytesOverride = meshWithIndices(intArrayOf(0, 1, 99))))
        }
        expectFailure("invalidPackage") {
            read(fixture(meshBytesOverride = mesh(version = 2, indices = intArrayOf(0, 1, 2)).copyOf(
                mesh(version = 2, indices = intArrayOf(0, 1, 2)).size - 1)))
        }
    }

    private fun meshWithIndices(indices: IntArray): ByteArray {
        val buffer = ByteBuffer.allocate(16 + 3 * 24 + indices.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        buffer.putInt(0x4F533344); buffer.putInt(1); buffer.putInt(3); buffer.putInt(indices.size)
        repeat(3) { buffer.putFloat(it.toFloat()); buffer.putFloat(0f); buffer.putFloat(0f) }
        repeat(3) { buffer.putFloat(0f); buffer.putFloat(1f); buffer.putFloat(0f) }
        indices.forEach { buffer.putInt(it) }
        return buffer.array()
    }

    @Test
    fun rejectsPathEscapeAndAbsoluteOrUriBlobNames() {
        for (bad in listOf("../escape.mesh", "/etc/passwd.mesh", "https://example.com/a.mesh",
            "blobs/../../a.mesh", "previous/blobs/a.mesh")) {
            val fixture = fixture()
            val body = fixture.document["bodies"]!!.jsonArray[0].jsonObject
            val document = buildJsonObject {
                fixture.document.forEach { (key, value) -> put(key, value) }
                put("bodies", buildJsonArray {
                    add(buildJsonObject {
                        body.forEach { (key, value) -> put(key, value) }
                        put("meshBlob", bad)
                    })
                })
            }
            fixture.files["$root/document.json"] = document.toString().toByteArray()
            expectFailure("invalidPackage") { read(fixture) }
        }
    }

    @Test
    fun rejectsContentDigestMismatchAndMidSnapshotManifestChange() {
        val fixture = fixture()
        val changedManifest = buildJsonObject {
            fixture.manifest.forEach { (key, value) -> put(key, value) }
            put("revision", 7)
            put("contentSHA256", "0".repeat(64))
        }
        fixture.files["$root/manifest.json"] = changedManifest.toString().toByteArray()
        expectFailure("invalidPackage") { read(fixture) }

        val changing = fixture()
        val sourceHook: (MemorySource) -> Unit = { source ->
            source.secondManifest = buildJsonObject {
                changing.manifest.forEach { (key, value) -> put(key, value) }
                put("revision", 7)
                put("contentSHA256", "0".repeat(64))
            }.toString().toByteArray()
        }
        expectFailure("sourceChanged") { read(changing, mutate = sourceHook) }
    }

    @Test
    fun rejectsOwnerCancellationAndWrongStagedDigest() {
        val fixture = fixture()
        expectFailure("ownerChanged") {
            read(fixture, mutate = { source -> source.current = { false } })
        }
        expectFailure("sourceChanged") {
            read(fixture, mutate = { source -> source.forceWrongSha = true })
        }
    }

    @Test
    fun acceptsUnknownFieldsButRejectsDuplicateBodyIDsAndMalformedImages() {
        val fixture = fixture(withImage = true)
        val document = buildJsonObject {
            fixture.document.forEach { (key, value) -> put(key, value) }
            put("unknownFuture", buildJsonObject { put("safe", true) })
        }
        fixture.files["$root/document.json"] = document.toString().toByteArray()
        // Recompute the manifest identity after the additive document change.
        val blobs = listOf(
            "blobs/$bodyID.mesh" to sha(fixture.mesh),
            "blobs/$bodyID.brep" to sha("FloeBRep".toByteArray()),
            "blobs/images/$imageID.img" to sha(png),
        )
        val content = digest(document.toString().toByteArray(), blobs, null)
        val manifest = fixture.manifest.toString().replace(
            fixture.manifest["contentSHA256"]!!.jsonPrimitive.content, content)
        fixture.files["$root/manifest.json"] = manifest.toByteArray()
        assertNotNull(read(fixture))

        val duplicate = fixture()
        val body = duplicate.document["bodies"]!!.jsonArray[0].jsonObject
        val duplicateDoc = buildJsonObject {
            duplicate.document.forEach { (key, value) -> put(key, value) }
            put("bodies", buildJsonArray {
                add(buildJsonObject { body.forEach { (key, value) -> put(key, value) } })
                add(buildJsonObject { body.forEach { (key, value) -> put(key, value) } })
            })
        }
        duplicate.files["$root/document.json"] = duplicateDoc.toString().toByteArray()
        expectFailure("invalidPackage") { read(duplicate) }

        val malformedImage = fixture(withImage = true)
        val image = malformedImage.document["images"]!!.jsonArray[0].jsonObject
        val badImageDoc = buildJsonObject {
            malformedImage.document.forEach { (key, value) -> put(key, value) }
            put("images", buildJsonArray {
                add(buildJsonObject {
                    image.forEach { (key, value) -> put(key, value) }
                    put("info", base64("{}".toByteArray()))
                })
            })
        }
        malformedImage.files["$root/document.json"] = badImageDoc.toString().toByteArray()
        expectFailure("invalidPackage") { read(malformedImage) }
    }

    @Test
    fun mixedBRepOnlyBodiesArePreservedAndReported() {
        val fixture = fixture(withImage = false)
        val body = fixture.document["bodies"]!!.jsonArray[0].jsonObject
        val document = buildJsonObject {
            fixture.document.forEach { (key, value) -> put(key, value) }
            put("bodies", buildJsonArray {
                add(buildJsonObject {
                    body.forEach { (key, value) ->
                        if (key != "meshBlob" && key != "meshSHA256") put(key, value)
                    }
                })
                add(buildJsonObject {
                    body.forEach { (key, value) -> put(key, value) }
                    put("bodyID", UUID.randomUUID().toString())
                    put("name", "Mesh body")
                })
            })
        }
        val documentBytes = document.toString().toByteArray()
        fixture.files["$root/document.json"] = documentBytes
        // Keep only the BRep + mesh resources actually referenced.
        val content = digest(documentBytes, listOf(
            "blobs/$bodyID.brep" to sha("FloeBRep".toByteArray()),
            "blobs/$bodyID.mesh" to sha(fixture.mesh),
        ), null)
        val manifest = fixture.manifest.toString()
            .replace(fixture.manifest["contentSHA256"]!!.jsonPrimitive.content, content)
        fixture.files["$root/manifest.json"] = manifest.toByteArray()
        val preview = read(fixture)
        assertEquals(1, preview.brepOnlyCount)
        assertEquals(1, preview.brepPlacements.size)
        assertEquals("blobs/$bodyID.brep", preview.brepPlacements[0].blobPath)
        assertTrue(preview.limitations.contains("on-device tessellation"))
        assertEquals(1, preview.meshCount)
    }

    @Test
    fun onlyBRepPackageBuildsAnEmptyGlbAndServableBrepPlacement() {
        val fixture = fixture(withBRepOnly = true)
        val preview = read(fixture)
        assertEquals(1, preview.brepOnlyCount)
        assertEquals(1, preview.brepPlacements.size)
        assertEquals(0, preview.meshCount)
        assertTrue(preview.derivedFile.isFile)
        val glb = parseGlb(preview.derivedFile.readBytes())
        assertEquals(0, glb["nodes"]!!.jsonArray.size)
        assertEquals(0, glb["meshes"]!!.jsonArray.size)
        assertTrue(preview.limitations.contains("on-device tessellation"))
    }

    @Test
    fun missingBlobIsAResourceFailureAndSingleComponentRootIsAccepted() {
        val fixture = fixture()
        fixture.files.remove("$root/blobs/$bodyID.mesh")
        expectFailure("resourceMissing") { read(fixture) }

        val single = fixture()
        val singleRoot = "Part.floecad"
        val remapped = LinkedHashMap<String, ByteArray>()
        single.files.forEach { (path, bytes) ->
            remapped[path.replace(root, singleRoot)] = bytes
        }
        val temp = tempRoot()
        val source = MemorySource(remapped, temp)
        val preview = C04FloecadPackageReader(source, File(temp, "preview")).read(singleRoot)
        assertTrue(preview.derivedFile.isFile)
    }

    @Test
    fun oneMillimetreAndOneMetreReferencesAreNormalizedToGltfMetres() {
        val small = read(fixture(translation = listOf(1.0, 0.0, 0.0)))
        val smallGlb = parseGlb(small.derivedFile.readBytes())
        val smallMatrix = smallGlb["nodes"]!!.jsonArray[0].jsonObject["matrix"]!!.jsonArray
        assertEquals(0.001, smallMatrix[12].jsonPrimitive.content.toDouble(), 0.0000001)
        val smallAccessor = positionAccessor(smallGlb, 0)
        assertEquals(0.0, smallAccessor["min"]!!.jsonArray[0].jsonPrimitive.content.toDouble(), 0.0000001)
        assertEquals(0.002, smallAccessor["max"]!!.jsonArray[0].jsonPrimitive.content.toDouble(), 0.0000001)
        assertEquals(1.0, small.boundsMinimum[0], 0.0001)
        assertEquals(3.0, small.boundsMaximum[0], 0.0001)

        val large = read(fixture(translation = listOf(1000.0, 0.0, 0.0)))
        val largeGlb = parseGlb(large.derivedFile.readBytes())
        val largeMatrix = largeGlb["nodes"]!!.jsonArray[0].jsonObject["matrix"]!!.jsonArray
        assertEquals(1.0, largeMatrix[12].jsonPrimitive.content.toDouble(), 0.000001)
        assertEquals(1000.0, large.boundsMinimum[0], 0.0001)
        assertEquals(1002.0, large.boundsMaximum[0], 0.0001)
        assertEquals("m", largeGlb["asset"]!!.jsonObject["extras"]!!.jsonObject["unit"]!!.jsonPrimitive.content)
    }

    @Test
    fun insertedImagePlaneIsConvertedToMetresButPackageBoundsStayMillimetres() {
        val preview = read(fixture(withImage = true))
        val glb = parseGlb(preview.derivedFile.readBytes())
        val imageAccessor = positionAccessor(glb, 1)
        assertEquals(-0.01, imageAccessor["min"]!!.jsonArray[0].jsonPrimitive.content.toDouble(), 0.0000001)
        assertEquals(0.01, imageAccessor["max"]!!.jsonArray[0].jsonPrimitive.content.toDouble(), 0.0000001)
        assertEquals(-10.0, preview.boundsMinimum[0], 0.0001)
        assertEquals(10.0, preview.boundsMaximum[0], 0.0001)
    }

    @Test
    fun webpInsertedImageIsDecodedToPngOnlyForTheDerivedGlb() {
        val webp = byteArrayOf(
            'R'.code.toByte(), 'I'.code.toByte(), 'F'.code.toByte(), 'F'.code.toByte(),
            0, 0, 0, 0,
            'W'.code.toByte(), 'E'.code.toByte(), 'B'.code.toByte(), 'P'.code.toByte(),
            'V'.code.toByte(), 'P'.code.toByte(), '8'.code.toByte(), ' '.code.toByte(),
        )
        class Decoder : C04FloecadImageDecoder {
            var calls = 0
            override fun toPng(bytes: ByteArray, mediaType: String): ByteArray {
                calls += 1
                assertEquals("image/webp", mediaType)
                return this@C04FloecadPackageTest.png
            }
        }
        val decoder = Decoder()
        val fixture = fixture(withImage = true, imageBytes = webp)
        val before = fixture.files["$root/blobs/images/$imageID.img"]!!.copyOf()
        val preview = read(fixture, decoder)
        assertEquals(1, decoder.calls)
        assertEquals(1, preview.convertedWebpTextures)
        val glb = parseGlb(preview.derivedFile.readBytes())
        assertEquals("image/png", glb["images"]!!.jsonArray[0].jsonObject["mimeType"]!!.jsonPrimitive.content)
        assertTrue(before.contentEquals(fixture.files["$root/blobs/images/$imageID.img"]))
        assertTrue(preview.limitations.contains("WebP"))
    }

    private fun positionAccessor(glb: JsonObject, meshIndex: Int): JsonObject {
        val primitive = glb["meshes"]!!.jsonArray[meshIndex]
            .jsonObject["primitives"]!!.jsonArray[0].jsonObject
        val accessorIndex = primitive["attributes"]!!.jsonObject["POSITION"]!!
            .jsonPrimitive.content.toInt()
        return glb["accessors"]!!.jsonArray[accessorIndex].jsonObject
    }

    private fun parseGlb(bytes: ByteArray): JsonObject {
        assertTrue(bytes.size > 20)
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(0x46546C67, buffer.int)
        assertEquals(2, buffer.int)
        assertEquals(bytes.size, buffer.int)
        val jsonLength = buffer.int
        assertEquals(0x4E4F534A, buffer.int)
        val jsonBytes = ByteArray(jsonLength)
        buffer.get(jsonBytes)
        return Json.parseToJsonElement(String(jsonBytes, Charsets.UTF_8).trimEnd()).jsonObject
    }
}
