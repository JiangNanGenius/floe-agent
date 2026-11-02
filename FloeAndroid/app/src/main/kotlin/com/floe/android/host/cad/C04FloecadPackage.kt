// SPDX-License-Identifier: MPL-2.0
//
// C04C native `.floecad` directory-package reader and derived-preview builder.
//
// The native writer is FloeCADKit `FileCADDocumentStore.swift` (fixed donor
// object a59b4d4005f616c611df67fab7620e9853c525b9). A package is a DIRECTORY:
//
//   manifest.json          revision / schema / unit / contentSHA256 / counts
//   document.json          bodies, images, assembly, drawings metadata
//   blobs/<id>.mesh        "OS3D" v1/v2 binary render mesh
//   blobs/<id>.brep        OCCT BRep bytes (preserved, not re-encoded)
//   blobs/images/<id>.img  original PNG/JPEG/WebP bytes
//   previous/              optional previous commit (never read as truth)
//
// This reader validates the actual manifest/document/blob identities before
// interpreting bytes, then emits a bounded derived GLB in glTF metres and the
// placements needed by the EXISTING C04A WebView viewport to tessellate
// preserved B-Rep-only bodies with its pinned offline OCCT worker. WebP
// inserted images are decoded to a derived PNG texture only; original bytes,
// digests and the manifest unit are never rewritten.
// The intermediate `floe.cad-package/1` JSON schema from C04A is NOT the
// source format and is not accepted here.
package com.floe.android.host.cad

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

/** Closed C04C limits. These describe what the DERIVED PREVIEW can hold; the
 * native package itself may be larger and stays untouched on disk. Structural
 * package limits are separate so a valid-but-large package fails as a typed
 * preview limit rather than as an unexplained session-resource cap. */
internal object C04FloecadLimits {
    const val MAX_MANIFEST_BYTES = 2L shl 20
    const val MAX_DOCUMENT_BYTES = 32L shl 20
    const val MAX_BLOB_BYTES = 256L shl 20
    const val MAX_PACKAGE_BYTES = 512L shl 20
    const val MAX_PREVIEW_BYTES = 96L shl 20
    const val MAX_GLB_BYTES = 128L shl 20
    const val MAX_FILES = 1024
    const val MAX_BODIES = 512
    const val MAX_IMAGES = 128
    const val MAX_ASSEMBLY_INSTANCES = 4096
    const val MAX_VERTICES = 4_000_000
    const val MAX_TRIANGLES = 4_000_000
    const val MAX_TEXTURE_BYTES = 32L shl 20
    const val MAX_TEXTURE_EDGE = 8_192
    const val MAX_TEXTURES = 128
    const val MAX_TEXTURE_TOTAL_BYTES = 64L shl 20
    /** The derived GLB is a glTF 2.0 scene, whose normative unit is metres.
     * The native writer stores millimetres, so every rendered position and
     * translation is scaled by this factor before it enters the GLB. */
    const val MILLIMETERS_TO_METERS = 0.001
    /** Bounded on-device B-Rep tessellation. One OCCT worker run is capped at
     * 10 MiB / 200k triangles / 600k vertices by the pinned worker itself. */
    const val MAX_BREP_SOURCE_BYTES = 10L shl 20
    const val MAX_BREP_TOTAL_TRIANGLES = 2_000_000
    const val MAX_PATH_BYTES = 4096
    const val MAX_NAME_CHARS = 256
    const val MAX_SCHEMA_VERSION = 1_000
    /** FloeCAD document schemas whose known fields this adapter understands.
     * A newer value still opens read-only with an explicit boundary. */
    const val KNOWN_SCHEMA_VERSION = 3
    const val MAX_REVISION = 1_000_000_000
    const val MAX_ABS_COORDINATE = 1e12
    const val MAX_ABS_SCALE = 1e9

    val PACKAGE_EXTENSION = "floecad"
    val MANIFEST_NAME = "manifest.json"
    val DOCUMENT_NAME = "document.json"
    val BLOB_EXTENSIONS = setOf("mesh", "brep", "img")
    val IMAGE_MEDIA_TYPES = setOf("image/png", "image/jpeg", "image/webp")
    /** glTF 2.0 core embeds PNG/JPEG only. WebP needs EXT_texture_webp, which
     * the pinned mesh.js path does not advertise; it is decoded on device to
     * PNG for the DERIVED GLB only, never substituted in the source package. */
    val GLB_IMAGE_MEDIA_TYPES = setOf("image/png", "image/jpeg")
}

internal class C04FloecadFailure(val code: String, val detail: String) : Exception(detail)

internal data class C04FloecadStaged(
    val relativePath: String,
    val file: File,
    val bytes: Long,
    val sha256: String,
)

/** The only byte source this reader uses. The production adapter stages each
 * requested path through the existing G04 native workspace egress; tests use
 * an in-memory package. The reader still validates every path itself, so a
 * source can never widen the package root. */
internal interface C04FloecadSource {
    fun stage(relativePath: String, maxBytes: Long): C04FloecadStaged
}

internal data class C04FloecadResource(
    val path: String,
    val sha256: String,
    val bytes: Long,
    val mediaType: String,
    val file: File,
)

internal data class C04FloecadInstance(
    val id: String,
    val name: String,
    val bodyID: String,
    val copiedBodyID: String?,
    val matrix: C04FloecadMatrix,
    val hidden: Boolean,
)

internal data class C04FloecadMaterial(
    val baseColor: DoubleArray = doubleArrayOf(0.72, 0.74, 0.78, 1.0),
    val metallic: Double = 0.0,
    val roughness: Double = 0.0,
    val opacity: Double = 1.0,
    val baseColorTexture: ByteArray? = null,
)

/** One visible placement of a B-Rep-only body. `matrix` is the same
 * column-major source-millimetre transform the mesh path uses. The WebView
 * tessellates the preserved B-Rep blob once and applies every placement. */
internal data class C04FloecadBrepPlacement(
    val name: String,
    val blobPath: String,
    val matrix: DoubleArray,
)

internal data class C04FloecadPreview(
    val manifestSha256: String,
    val documentSha256: String,
    val contentSHA256: String,
    val modelSHA256: String?,
    val schemaVersion: Int,
    val revision: Int,
    val name: String,
    val sourceUnits: String,
    val displayUnits: String,
    val bodyCount: Int,
    val imageCount: Int,
    val assemblyInstanceCount: Int,
    val brepOnlyCount: Int,
    val brepPlacements: List<C04FloecadBrepPlacement>,
    val brepBytes: Long,
    val convertedWebpTextures: Int,
    val hdrImageCount: Int,
    val drawingPageCount: Int,
    val derivedFile: File,
    val derivedBytes: Long,
    val derivedSha256: String,
    val meshCount: Int,
    val triangleCount: Int,
    val vertexCount: Int,
    val boundsMinimum: DoubleArray,
    val boundsMaximum: DoubleArray,
    val missing: List<String>,
    val limitations: String,
    val resources: List<C04FloecadResource>,
) {
    /** Source-millimetre package bounds for the fallback path where the JS
     * bridge did not run. B-Rep-only previews have no mesh bounds. */
    fun boundsOrNull(): C04CadBounds? {
        if (boundsMinimum.size != 3 || boundsMaximum.size != 3) return null
        if (!boundsMinimum.all { it.isFinite() } || !boundsMaximum.all { it.isFinite() }) {
            return null
        }
        if (boundsMinimum.indices.any { boundsMinimum[it] > boundsMaximum[it] }) return null
        return C04CadBounds(
            minimum = boundsMinimum.toList(),
            maximum = boundsMaximum.toList(),
        )
    }

    fun toManifestJson(brepBodies: JsonArray = JsonArray(emptyList())): JsonObject = buildJsonObject {
        put("schemaVersion", schemaVersion)
        put("revision", revision)
        put("name", name)
        put("sourceUnits", sourceUnits)
        put("displayUnits", displayUnits)
        put("sourceUnitScale", C04FloecadLimits.MILLIMETERS_TO_METERS)
        put("gltfUnit", "m")
        put("bodyCount", bodyCount)
        put("imageCount", imageCount)
        put("assemblyInstanceCount", assemblyInstanceCount)
        put("brepOnlyCount", brepOnlyCount)
        put("brepPlacementCount", brepPlacements.size)
        put("brepBytes", brepBytes)
        put("convertedWebpTextures", convertedWebpTextures)
        put("hdrImageCount", hdrImageCount)
        put("drawingPageCount", drawingPageCount)
        put("meshCount", meshCount)
        put("triangleCount", triangleCount)
        put("vertexCount", vertexCount)
        put("missingCount", missing.size)
        put("limitations", limitations.take(512))
        put("derived", true)
        put("originalUnmodified", true)
        put("contentSHA256", contentSHA256)
        modelSHA256?.let { put("modelSHA256", it) }
        if (brepBodies.isNotEmpty()) put("brepBodies", brepBodies)
    }
}

/** Decodes an otherwise-valid inserted image into a bounded PNG for the
 * DERIVED GLB only. The original package bytes and digests never change. */
internal interface C04FloecadImageDecoder {
    fun toPng(bytes: ByteArray, mediaType: String): ByteArray?
}

internal class C04FloecadPackageReader(
    private val source: C04FloecadSource,
    private val outputDirectory: File,
    private val imageDecoder: C04FloecadImageDecoder? = null,
) {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = false
        allowSpecialFloatingPointValues = false
    }

    fun read(packageRoot: String, isCurrent: () -> Boolean = { true }): C04FloecadPreview {
        val root = normalizePackageRoot(packageRoot)
        fun check() {
            if (!isCurrent()) throw C04FloecadFailure("ownerChanged", "owner")
        }
        check()
        val manifestStaged = stagePackageFile(
            "$root/${C04FloecadLimits.MANIFEST_NAME}",
            C04FloecadLimits.MAX_MANIFEST_BYTES, "manifestMissing", ::check)
        val manifestBytes = readBounded(manifestStaged.file, C04FloecadLimits.MAX_MANIFEST_BYTES)
            ?: throw C04FloecadFailure("invalidPackage", "manifestRead")
        val manifest = parseManifest(manifestBytes)
        val documentStaged = stagePackageFile(
            "$root/${C04FloecadLimits.DOCUMENT_NAME}",
            C04FloecadLimits.MAX_DOCUMENT_BYTES, "documentMissing", ::check)
        val documentBytes = readBounded(documentStaged.file, C04FloecadLimits.MAX_DOCUMENT_BYTES)
            ?: throw C04FloecadFailure("invalidPackage", "documentRead")
        val document = parseDocument(documentBytes, ::check)
        // The preview artifact is not needed for geometry, but its digest is
        // part of the writer's content identity (below). No preview bytes are
        // read as geometry.

        val resources = LinkedHashMap<String, C04FloecadResource>()
        val stagedByPath = LinkedHashMap<String, C04FloecadStaged>()
        var resourceBytes = 0L
        fun register(path: String, sha: String, mediaType: String): C04FloecadStaged {
            val previous = resources[path]
            if (previous != null) {
                if (!previous.sha256.equals(sha, ignoreCase = true)) {
                    throw C04FloecadFailure("invalidPackage", "duplicateBlob")
                }
                return stagedByPath[path]
                    ?: throw C04FloecadFailure("invalidPackage", "duplicateBlob")
            }
            val staged = stageChecked("$root/$path", C04FloecadLimits.MAX_BLOB_BYTES, ::check)
            if (!staged.sha256.equals(sha, ignoreCase = true)) {
                throw C04FloecadFailure("invalidPackage", "blobDigest")
            }
            if (resources.size >= C04FloecadLimits.MAX_FILES) {
                throw C04FloecadFailure("previewTooLarge", "files")
            }
            resourceBytes += staged.bytes
            if (resourceBytes > C04FloecadLimits.MAX_PACKAGE_BYTES) {
                throw C04FloecadFailure("previewTooLarge", "packageBytes")
            }
            resources[path] = C04FloecadResource(path, sha.lowercase(), staged.bytes, mediaType, staged.file)
            stagedByPath[path] = staged
            return staged
        }

        var previewBytes = 0L
        val bodyRecords = ArrayList<C04FloecadBodyRecord>(document.bodies.size)
        for (body in document.bodies) {
            check()
            val meshPath = body.meshBlob
            val meshSha = body.meshSHA256
            if ((meshPath == null) != (meshSha == null)) {
                throw C04FloecadFailure("invalidPackage", "meshRecord")
            }
            if (meshPath != null && meshSha != null) {
                validateBlobPath(meshPath)
                val staged = register(meshPath, meshSha, "application/vnd.floe.cad.mesh")
                previewBytes += staged.bytes
                if (previewBytes > C04FloecadLimits.MAX_PREVIEW_BYTES) {
                    throw C04FloecadFailure("previewTooLarge", "previewBytes")
                }
            }
            val brepPath = body.brepBlob
            val brepSha = body.brepSHA256
            if ((brepPath == null) != (brepSha == null)) {
                throw C04FloecadFailure("invalidPackage", "brepRecord")
            }
            if (brepPath != null && brepSha != null) {
                validateBlobPath(brepPath)
                register(brepPath, brepSha, "application/octet-stream")
            }
            bodyRecords.add(C04FloecadBodyRecord(
                bodyID = body.bodyID,
                name = body.name,
                transform = body.transform,
                meshBlob = meshPath,
                meshSHA256 = meshSha,
                brepBlob = brepPath,
                brepSHA256 = brepSha,
                isHidden = body.isHidden,
                material = body.material,
            ))
        }
        val imageRecords = ArrayList<C04FloecadImageRecord>(document.images.size)
        var hdrImageCount = 0
        for (image in document.images) {
            check()
            validateBlobPath(image.blobPath)
            val staged = register(image.blobPath, image.sha256, "application/octet-stream")
            previewBytes += staged.bytes
            if (previewBytes > C04FloecadLimits.MAX_PREVIEW_BYTES) {
                throw C04FloecadFailure("previewTooLarge", "previewBytes")
            }
            val mediaType = imageMediaType(staged.file)
                ?: throw C04FloecadFailure("unsupportedPackage", "imageType")
            if (mediaType == "image/png" && isSixteenBitPng(staged.file)) {
                hdrImageCount += 1
            }
            // Replace the generic descriptor with the actual media type.
            resources[image.blobPath] = C04FloecadResource(
                image.blobPath, image.sha256.lowercase(), staged.bytes, mediaType, staged.file)
            imageRecords.add(image)
        }
        if (previewBytes > C04FloecadLimits.MAX_PREVIEW_BYTES) {
            throw C04FloecadFailure("previewTooLarge", "previewBytes")
        }

        // Re-read the manifest after all blobs. A source that changed while the
        // snapshot was assembled can never be rendered as one coherent package.
        check()
        val manifestAgain = stagePackageFile(
            "$root/${C04FloecadLimits.MANIFEST_NAME}",
            C04FloecadLimits.MAX_MANIFEST_BYTES, "manifestMissing", ::check)
        if (!manifestAgain.sha256.equals(manifestStaged.sha256, ignoreCase = true)) {
            throw C04FloecadFailure("sourceChanged", "manifestChanged")
        }

        val contentDigest = contentSHA256(documentBytes, resources.values.toList(),
            manifest.thumbnailSHA256)
        if (!contentDigest.equals(manifest.contentSHA256, ignoreCase = true)) {
            throw C04FloecadFailure("invalidPackage", "contentSHA256")
        }

        val assembly = parseAssembly(document.assembly)
        if (assembly.size > C04FloecadLimits.MAX_ASSEMBLY_INSTANCES) {
            throw C04FloecadFailure("previewTooLarge", "assembly")
        }
        val drawingPageCount = drawingPageCount(document.drawings)
        check()

        val built = C04FloecadGlbBuilder(json, imageDecoder).build(
            packageRoot = root,
            manifest = manifest,
            bodies = bodyRecords,
            images = imageRecords,
            instances = assembly,
            resources = resources,
            outputDirectory = outputDirectory,
            check = ::check,
        )
        val hdrTextures = hdrImageCount + built.hdrTextures
        val limitations = buildList {
            add("Derived read-only preview; the original package was validated and is unchanged.")
            add("GLB geometry is normalized to metres; bounds and counts are in source millimetres.")
            if (manifest.schemaVersion > C04FloecadLimits.KNOWN_SCHEMA_VERSION) {
                add("Package schema ${manifest.schemaVersion} uses known fields only; newer fields are preserved but not interpreted.")
            }
            if (built.brepOnlyCount > 0) {
                if (built.brepPlacements.isNotEmpty()) {
                    add("${built.brepOnlyCount} B-Rep-only ${if (built.brepOnlyCount == 1) "body is" else "bodies are"} preserved; any displayed B-Rep surface is a derived on-device tessellation, not exact geometry.")
                } else {
                    add("${built.brepOnlyCount} B-Rep-only ${if (built.brepOnlyCount == 1) "body is" else "bodies are"} preserved but not shown; no surface was fabricated.")
                }
            }
            if (drawingPageCount > 0) {
                add("$drawingPageCount saved drawing ${if (drawingPageCount == 1) "page" else "pages"} contain no stored raster snapshot in the package and are not displayed.")
            }
            if (assembly.isNotEmpty()) add("Assembly placements are shown from the saved instance transforms.")
            if (built.skippedTextures > 0) {
                add("${built.skippedTextures} image/material ${if (built.skippedTextures == 1) "texture was" else "textures were"} skipped (unsupported encoding or no mesh UVs).")
            }
            if (built.convertedWebpTextures > 0) {
                add("${built.convertedWebpTextures} WebP ${if (built.convertedWebpTextures == 1) "image was" else "images were"} decoded to PNG for this derived preview; original bytes are unchanged.")
            }
            if (hdrTextures > 0) {
                add("$hdrTextures 16-bit or HDR ${if (hdrTextures == 1) "texture is" else "textures are"} shown as 8-bit SDR in this preview; source bytes are unchanged.")
            }
            if (manifest.displayUnits != "mm") {
                add("The package display preference is ${manifest.displayUnits}; bounds remain in source millimetres.")
            }
            if (built.truncatedBrepPlacements > 0) {
                add("${built.truncatedBrepPlacements} B-Rep ${if (built.truncatedBrepPlacements == 1) "placement is" else "placements are"} outside the bounded on-device tessellation limit and are not shown.")
            }
        }.joinToString(" ").take(512)
        return C04FloecadPreview(
            manifestSha256 = manifestStaged.sha256,
            documentSha256 = documentStaged.sha256,
            contentSHA256 = contentDigest,
            modelSHA256 = manifest.modelSHA256,
            schemaVersion = manifest.schemaVersion,
            revision = manifest.revision,
            name = manifest.name,
            sourceUnits = "mm",
            displayUnits = manifest.displayUnits,
            bodyCount = bodyRecords.size,
            imageCount = imageRecords.size,
            assemblyInstanceCount = assembly.size,
            brepOnlyCount = built.brepOnlyCount,
            brepPlacements = built.brepPlacements,
            brepBytes = built.brepPlacements
                .map { it.blobPath }
                .distinct()
                .sumOf { path -> resources[path]?.bytes ?: 0L },
            convertedWebpTextures = built.convertedWebpTextures,
            hdrImageCount = hdrTextures,
            drawingPageCount = drawingPageCount,
            derivedFile = built.file,
            derivedBytes = built.bytes,
            derivedSha256 = built.sha256,
            meshCount = built.meshCount,
            triangleCount = built.triangleCount,
            vertexCount = built.vertexCount,
            boundsMinimum = built.minimum,
            boundsMaximum = built.maximum,
            missing = built.missing,
            limitations = limitations,
            resources = resources.values.toList(),
        )
    }

    private fun stagePackageFile(
        relativePath: String,
        maxBytes: Long,
        missingDetail: String,
        check: () -> Unit,
    ): C04FloecadStaged = try {
        stageChecked(relativePath, maxBytes, check)
    } catch (error: C04FloecadFailure) {
        if (error.code == "resourceMissing") {
            throw C04FloecadFailure("invalidPackage", missingDetail)
        }
        throw error
    }

    private fun stageChecked(
        relativePath: String,
        maxBytes: Long,
        check: () -> Unit,
    ): C04FloecadStaged {
        check()
        val staged = try {
            source.stage(relativePath, maxBytes)
        } catch (error: C04FloecadFailure) {
            throw error
        } catch (error: Throwable) {
            throw C04FloecadFailure("resourceMissing", error.message?.take(120) ?: "stage")
        }
        if (staged.bytes < 1L || staged.bytes > maxBytes) {
            throw C04FloecadFailure("previewTooLarge", "blobBytes")
        }
        if (!staged.file.isFile || staged.file.length() != staged.bytes) {
            throw C04FloecadFailure("invalidPackage", "stagedFile")
        }
        val actual = sha256(staged.file)
        if (!actual.equals(staged.sha256, ignoreCase = true)) {
            throw C04FloecadFailure("sourceChanged", "stagedDigest")
        }
        check()
        return staged
    }

    private fun parseManifest(bytes: ByteArray): C04FloecadManifest {
        val objectValue = parseObject(bytes, "manifest")
        val schema = intField(objectValue, "schemaVersion")
            ?: throw C04FloecadFailure("invalidPackage", "schemaVersion")
        if (schema !in 1..C04FloecadLimits.MAX_SCHEMA_VERSION) {
            throw C04FloecadFailure("unsupportedPackage", "schemaVersion")
        }
        val revision = intField(objectValue, "revision")
            ?: throw C04FloecadFailure("invalidPackage", "revision")
        if (revision !in 0..C04FloecadLimits.MAX_REVISION) {
            throw C04FloecadFailure("invalidPackage", "revision")
        }
        val name = stringField(objectValue, "name")?.takeIf { it.isNotBlank() }
            ?: throw C04FloecadFailure("invalidPackage", "name")
        if (name.length > C04FloecadLimits.MAX_NAME_CHARS) {
            throw C04FloecadFailure("invalidPackage", "name")
        }
        val content = stringField(objectValue, "contentSHA256")
            ?.takeIf { isSHA256(it) }
            ?: throw C04FloecadFailure("invalidPackage", "contentSHA256")
        val model = stringField(objectValue, "modelSHA256")?.takeIf { isSHA256(it) }
        if (objectValue["modelSHA256"] != null && model == null) {
            throw C04FloecadFailure("invalidPackage", "modelSHA256")
        }
        val thumbnail = stringField(objectValue, "thumbnailSHA256")?.takeIf { isSHA256(it) }
        if (objectValue["thumbnailSHA256"] != null && thumbnail == null) {
            throw C04FloecadFailure("invalidPackage", "thumbnailSHA256")
        }
        val unitValue = stringField(objectValue, "unit")
        val unit = when (unitValue) {
            null -> "mm"
            "mm", "cm", "m", "in", "ft" -> unitValue
            else -> "mm"
        }
        val tolerance = doubleField(objectValue, "tolerance")
        if (objectValue["tolerance"] != null &&
            (tolerance == null || !tolerance.isFinite() || tolerance < 0 || tolerance > 1e9)
        ) {
            throw C04FloecadFailure("invalidPackage", "tolerance")
        }
        val counts = objectValue["counts"] as? JsonObject
        counts?.forEach { (key, value) ->
            val number = (value as? JsonPrimitive)?.intOrNull
            if (number == null || number < 0) {
                throw C04FloecadFailure("invalidPackage", "counts")
            }
            if (key.length > 64) throw C04FloecadFailure("invalidPackage", "counts")
        }
        return C04FloecadManifest(
            schemaVersion = schema,
            revision = revision,
            name = name,
            contentSHA256 = content.lowercase(),
            modelSHA256 = model?.lowercase(),
            thumbnailSHA256 = thumbnail?.lowercase(),
            displayUnits = unit,
            tolerance = tolerance,
        )
    }

    private fun parseDocument(bytes: ByteArray, check: () -> Unit): C04FloecadDocument {
        val objectValue = parseObject(bytes, "document")
        val bodiesArray = objectValue["bodies"] as? JsonArray
            ?: throw C04FloecadFailure("invalidPackage", "bodies")
        if (bodiesArray.size > C04FloecadLimits.MAX_BODIES) {
            throw C04FloecadFailure("previewTooLarge", "bodies")
        }
        val bodies = ArrayList<C04FloecadBodyRecord>(bodiesArray.size)
        val bodyIDs = HashSet<String>()
        for (element in bodiesArray) {
            check()
            val body = element as? JsonObject
                ?: throw C04FloecadFailure("invalidPackage", "body")
            val id = stringField(body, "bodyID")?.takeIf { isUUID(it) }
                ?: throw C04FloecadFailure("invalidPackage", "bodyID")
            if (!bodyIDs.add(id.lowercase())) {
                throw C04FloecadFailure("invalidPackage", "bodyID")
            }
            val name = (stringField(body, "name") ?: "Body").take(C04FloecadLimits.MAX_NAME_CHARS)
            val transformData = stringField(body, "transform")
                ?: throw C04FloecadFailure("invalidPackage", "transform")
            val transform = parseTransformData(transformData)
            val meshBlob = stringField(body, "meshBlob")
            val meshSha = stringField(body, "meshSHA256")?.takeIf { isSHA256(it) }
            val brepBlob = stringField(body, "brepBlob")
            val brepSha = stringField(body, "brepSHA256")?.takeIf { isSHA256(it) }
            if ((meshBlob == null) != (meshSha == null)) {
                throw C04FloecadFailure("invalidPackage", "meshRecord")
            }
            if ((brepBlob == null) != (brepSha == null)) {
                throw C04FloecadFailure("invalidPackage", "brepRecord")
            }
            val materialData = stringField(body, "material")
            val material = materialData?.let { parseMaterialData(it) }
            bodies.add(C04FloecadBodyRecord(
                bodyID = id,
                name = name,
                transform = transform,
                meshBlob = meshBlob,
                meshSHA256 = meshSha?.lowercase(),
                brepBlob = brepBlob,
                brepSHA256 = brepSha?.lowercase(),
                isHidden = boolField(body, "isHidden") ?: false,
                material = material,
            ))
        }
        val imagesArray = (objectValue["images"] as? JsonArray) ?: JsonArray(emptyList<JsonElement>())
        if (imagesArray.size > C04FloecadLimits.MAX_IMAGES) {
            throw C04FloecadFailure("previewTooLarge", "images")
        }
        val images = ArrayList<C04FloecadImageRecord>(imagesArray.size)
        for (element in imagesArray) {
            check()
            val image = element as? JsonObject
                ?: throw C04FloecadFailure("invalidPackage", "image")
            val imageID = stringField(image, "imageID")?.takeIf { isUUID(it) }
                ?: throw C04FloecadFailure("invalidPackage", "imageID")
            val blob = stringField(image, "imageBlob")
            val sha = stringField(image, "imageSHA256")?.takeIf { isSHA256(it) }
            if ((blob == null) != (sha == null)) {
                throw C04FloecadFailure("invalidPackage", "imageRecord")
            }
            if (blob == null || sha == null) continue
            val infoData = stringField(image, "info")
                ?: throw C04FloecadFailure("invalidPackage", "imageInfo")
            val info = parseImageInfo(infoData, imageID)
            images.add(C04FloecadImageRecord(
                id = imageID,
                name = info.name,
                blobPath = blob,
                sha256 = sha.lowercase(),
                origin = info.origin,
                xAxis = info.xAxis,
                yAxis = info.yAxis,
                width = info.width,
                height = info.height,
                opacity = info.opacity,
                hidden = info.hidden,
            ))
        }
        val assembly = stringField(objectValue, "assembly")?.let { decodeBase64(it, "assembly") }
        val drawings = stringField(objectValue, "drawings")?.let { decodeBase64(it, "drawings") }
        return C04FloecadDocument(
            bodies = bodies, images = images, assembly = assembly, drawings = drawings)
    }

    private fun parseTransformData(value: String): C04FloecadMatrix {
        val bytes = decodeBase64(value, "transform")
        val objectValue = parseObject(bytes, "transform")
        val translation = doubleArrayField(objectValue, "translation", 3, "transform")
        val rotation = doubleArrayField(objectValue, "rotation", 4, "transform")
        val scale = doubleField(objectValue, "scale")
            ?: throw C04FloecadFailure("invalidPackage", "transform")
        return C04FloecadMatrix.fromTrs(
            translation[0], translation[1], translation[2],
            rotation[0], rotation[1], rotation[2], rotation[3],
            scale, scale, scale,
        )
    }

    private fun parseMaterialData(value: String): C04FloecadMaterial? {
        val bytes = try {
            decodeBase64(value, "material")
        } catch (_: C04FloecadFailure) {
            return null
        }
        val objectValue = try {
            json.parseToJsonElement(String(bytes, Charsets.UTF_8)) as? JsonObject
        } catch (_: Throwable) {
            null
        } ?: return null
        val base = (objectValue["baseColor"] as? JsonArray)?.mapNotNull {
            (it as? JsonPrimitive)?.takeIf { primitive -> !primitive.isString }?.content
                ?.toDoubleOrNull()?.takeIf { v -> v.isFinite() }
        }
        val color = if (base?.size == 4) base.map { it.coerceIn(0.0, 1.0) }.toDoubleArray()
        else doubleArrayOf(0.72, 0.74, 0.78, 1.0)
        val metallic = doubleField(objectValue, "metallic")?.coerceIn(0.0, 1.0) ?: 0.0
        val roughness = doubleField(objectValue, "roughness")?.coerceIn(0.0, 1.0) ?: 0.0
        val opacity = doubleField(objectValue, "opacity")?.coerceIn(0.0, 1.0) ?: color[3].coerceIn(0.0, 1.0)
        val texture = stringField(objectValue, "baseColorTexture")
            ?.let { runCatching { decodeBase64(it, "materialTexture") }.getOrNull() }
        return C04FloecadMaterial(
            baseColor = color,
            metallic = metallic,
            roughness = roughness,
            opacity = opacity,
            baseColorTexture = texture,
        )
    }

    private fun parseImageInfo(value: String, imageID: String): C04FloecadImageInfo {
        val bytes = decodeBase64(value, "imageInfo")
        val objectValue = parseObject(bytes, "imageInfo")
        val id = objectValue["id"]?.let { rawID(it) }
        if (id != null && !id.equals(imageID, ignoreCase = true)) {
            throw C04FloecadFailure("invalidPackage", "imageID")
        }
        val plane = objectValue["plane"] as? JsonObject
            ?: throw C04FloecadFailure("invalidPackage", "imagePlane")
        val origin = doubleArrayField(plane, "origin", 3, "imagePlane")
        val xAxis = doubleArrayField(plane, "xAxis", 3, "imagePlane")
        val yAxis = doubleArrayField(plane, "yAxis", 3, "imagePlane")
        if (xAxis.all { it == 0.0 } || yAxis.all { it == 0.0 }) {
            throw C04FloecadFailure("invalidPackage", "imagePlane")
        }
        if (!axesFinite(origin) || !axesFinite(xAxis) || !axesFinite(yAxis)) {
            throw C04FloecadFailure("invalidPackage", "imagePlane")
        }
        val width = doubleField(objectValue, "width")
            ?: throw C04FloecadFailure("invalidPackage", "imageSize")
        val height = doubleField(objectValue, "height")
            ?: throw C04FloecadFailure("invalidPackage", "imageSize")
        if (!width.isFinite() || !height.isFinite() || width <= 0 || height <= 0 ||
            width > 1e7 || height > 1e7
        ) {
            throw C04FloecadFailure("invalidPackage", "imageSize")
        }
        val opacity = doubleField(objectValue, "opacity")?.coerceIn(0.0, 1.0) ?: 1.0
        val name = (stringField(objectValue, "name") ?: "Image")
            .take(C04FloecadLimits.MAX_NAME_CHARS)
        return C04FloecadImageInfo(
            name = name, origin = origin, xAxis = xAxis, yAxis = yAxis,
            width = width, height = height, opacity = opacity,
            hidden = boolField(objectValue, "isHidden") ?: false,
        )
    }

    private fun parseAssembly(value: ByteArray?): List<C04FloecadInstance> {
        if (value == null || value.isEmpty()) return emptyList()
        val objectValue = parseObject(value, "assembly")
        val array = (objectValue["instances"] as? JsonArray) ?: JsonArray(emptyList<JsonElement>())
        val instances = ArrayList<C04FloecadInstance>(array.size)
        for (element in array) {
            val objectItem = element as? JsonObject
                ?: throw C04FloecadFailure("invalidPackage", "assemblyInstance")
            val idValue = stringField(objectItem, "id")
            if (idValue != null && !isUUID(idValue)) {
                throw C04FloecadFailure("invalidPackage", "assemblyID")
            }
            val id = idValue ?: UUID.randomUUID().toString()
            val bodyID = stringField(objectItem, "bodyID")?.takeIf { isUUID(it) }
                ?: throw C04FloecadFailure("invalidPackage", "assemblyBody")
            val copiedValue = stringField(objectItem, "copiedBodyID")
            if (copiedValue != null && !isUUID(copiedValue)) {
                throw C04FloecadFailure("invalidPackage", "assemblyCopy")
            }
            val copied = copiedValue
            val transform = objectItem["transform"] as? JsonObject
                ?: throw C04FloecadFailure("invalidPackage", "assemblyTransform")
            val position = doubleArrayField(transform, "position", 3, "assemblyTransform")
            val rotation = doubleArrayField(transform, "rotation", 4, "assemblyTransform")
            val scale = doubleArrayField(transform, "scale", 3, "assemblyTransform")
            instances.add(C04FloecadInstance(
                id = id,
                name = (stringField(objectItem, "name") ?: "Instance")
                    .take(C04FloecadLimits.MAX_NAME_CHARS),
                bodyID = bodyID,
                copiedBodyID = copied,
                matrix = C04FloecadMatrix.fromTrs(
                    position[0], position[1], position[2],
                    rotation[0], rotation[1], rotation[2], rotation[3],
                    scale[0], scale[1], scale[2],
                ),
                hidden = boolField(objectItem, "isHidden") ?: false,
            ))
        }
        return instances
    }

    private fun drawingPageCount(value: ByteArray?): Int {
        if (value == null || value.isEmpty()) return 0
        return try {
            val objectValue = parseObject(value, "drawings")
            (objectValue["pages"] as? JsonArray)?.size ?: 0
        } catch (_: Throwable) {
            0
        }
    }

    private fun parseObject(bytes: ByteArray, field: String): JsonObject =
        try {
            json.parseToJsonElement(String(bytes, Charsets.UTF_8)) as? JsonObject
        } catch (_: Throwable) {
            null
        } ?: throw C04FloecadFailure("invalidPackage", field)

    private fun decodeBase64(value: String, field: String): ByteArray {
        if (value.isEmpty() || value.length > 64 * 1024 * 1024) {
            throw C04FloecadFailure("invalidPackage", field)
        }
        return try {
            Base64.getDecoder().decode(value)
        } catch (_: IllegalArgumentException) {
            throw C04FloecadFailure("invalidPackage", field)
        }
    }

    private fun normalizePackageRoot(raw: String): String {
        if (raw.length > C04FloecadLimits.MAX_PATH_BYTES || raw.startsWith("/") ||
            raw.contains('\\') || raw.contains(':') ||
            raw.any { it.code < 32 || it.code == 127 }
        ) {
            throw C04FloecadFailure("invalidPackage", "path")
        }
        val parts = raw.split('/')
        if (parts.isEmpty() || parts.any { it.isEmpty() || it == "." || it == ".." || it.length > 255 }) {
            throw C04FloecadFailure("invalidPackage", "path")
        }
        if (!parts.last().endsWith(".${C04FloecadLimits.PACKAGE_EXTENSION}", ignoreCase = true)) {
            throw C04FloecadFailure("invalidPackage", "extension")
        }
        return parts.joinToString("/")
    }

    private fun validateBlobPath(path: String) {
        val fail = C04FloecadFailure("invalidPackage", "blobPath")
        if (path.length > C04FloecadLimits.MAX_PATH_BYTES || path.startsWith("/") ||
            path.contains('\\') || path.contains(':') ||
            path.any { it.code < 32 || it.code == 127 }
        ) throw fail
        val parts = path.split('/')
        if (parts.size !in 2..3) throw fail
        if (parts[0] != "blobs") throw fail
        if (parts.size == 3 && parts[1] != "images") throw fail
        for (part in parts) {
            if (part.isEmpty() || part == "." || part == ".." || part.length > 255) throw fail
        }
        val extension = path.substringAfterLast('.', "").lowercase()
        if (extension !in C04FloecadLimits.BLOB_EXTENSIONS) throw fail
    }

    private fun isSixteenBitPng(file: File): Boolean {
        val header = readBounded(file, 26) ?: return false
        if (header.size < 26) return false
        if (header[0] != 0x89.toByte() || header[1] != 0x50.toByte() ||
            header[2] != 0x4E.toByte() || header[3] != 0x47.toByte()
        ) return false
        return (header[24].toInt() and 0xFF) == 16
    }

    private fun imageMediaType(file: File): String? {
        val header = readBounded(file, 16) ?: return null
        if (header.size >= 8 && header[0] == 0x89.toByte() && header[1] == 0x50.toByte() &&
            header[2] == 0x4E.toByte() && header[3] == 0x47.toByte()
        ) return "image/png"
        if (header.size >= 3 && header[0] == 0xFF.toByte() && header[1] == 0xD8.toByte() &&
            header[2] == 0xFF.toByte()
        ) return "image/jpeg"
        if (header.size >= 12 && String(header, 0, 4, Charsets.US_ASCII) == "RIFF" &&
            String(header, 8, 4, Charsets.US_ASCII) == "WEBP"
        ) return "image/webp"
        return null
    }

    companion object {
        fun contentSHA256(
            documentBytes: ByteArray,
            resources: List<C04FloecadResource>,
            thumbnailSHA256: String?,
        ): String {
            val digest = MessageDigest.getInstance("SHA-256")
            digest.update(documentBytes)
            for (resource in resources.sortedBy { it.path }) {
                digest.update(resource.path.toByteArray(Charsets.UTF_8))
                digest.update(resource.sha256.lowercase().toByteArray(Charsets.UTF_8))
            }
            if (!thumbnailSHA256.isNullOrBlank()) {
                digest.update(thumbnailSHA256.lowercase().toByteArray(Charsets.UTF_8))
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }

        fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            FileInputStream(file).use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    digest.update(buffer, 0, read)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }

        fun isSHA256(value: String): Boolean =
            value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }

        fun isUUID(value: String): Boolean = try {
            UUID.fromString(value).toString().equals(value, ignoreCase = true)
        } catch (_: IllegalArgumentException) {
            false
        }

        private fun readBounded(file: File, maximum: Long): ByteArray? {
            if (!file.isFile || file.length() > maximum) return null
            return try {
                FileInputStream(file).use { input ->
                    val output = ByteArrayOutputStream(minOf(file.length(), maximum).toInt())
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        output.write(buffer, 0, read)
                        if (output.size().toLong() > maximum) return null
                    }
                    output.toByteArray()
                }
            } catch (_: Throwable) {
                null
            }
        }

        private fun axesFinite(values: DoubleArray): Boolean =
            values.size == 3 && values.all { it.isFinite() && kotlin.math.abs(it) <= C04FloecadLimits.MAX_ABS_COORDINATE }

        private fun intField(objectValue: JsonObject, key: String): Int? =
            (objectValue[key] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull

        private fun doubleField(objectValue: JsonObject, key: String): Double? =
            (objectValue[key] as? JsonPrimitive)?.takeIf { !it.isString }?.content
                ?.toDoubleOrNull()?.takeIf { it.isFinite() }

        private fun stringField(objectValue: JsonObject, key: String): String? =
            (objectValue[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

        private fun boolField(objectValue: JsonObject, key: String): Boolean? =
            (objectValue[key] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull

        private fun doubleArrayField(
            objectValue: JsonObject,
            key: String,
            size: Int,
            field: String,
        ): DoubleArray {
            val array = objectValue[key] as? JsonArray
                ?: throw C04FloecadFailure("invalidPackage", field)
            if (array.size != size) throw C04FloecadFailure("invalidPackage", field)
            val values = DoubleArray(size)
            for (index in 0 until size) {
                val value = (array[index] as? JsonPrimitive)?.takeIf { !it.isString }?.content
                    ?.toDoubleOrNull()
                    ?: throw C04FloecadFailure("invalidPackage", field)
                if (!value.isFinite() || kotlin.math.abs(value.toDouble()) > C04FloecadLimits.MAX_ABS_COORDINATE) {
                    throw C04FloecadFailure("invalidPackage", field)
                }
                values[index] = value
            }
            return values
        }

        private fun rawID(value: JsonElement): String? {
            val objectValue = value as? JsonObject ?: return null
            return stringField(objectValue, "raw")
        }
    }
}

internal data class C04FloecadManifest(
    val schemaVersion: Int,
    val revision: Int,
    val name: String,
    val contentSHA256: String,
    val modelSHA256: String?,
    val thumbnailSHA256: String?,
    val displayUnits: String,
    val tolerance: Double?,
)

private data class C04FloecadBodyRecord(
    val bodyID: String,
    val name: String,
    val transform: C04FloecadMatrix,
    val meshBlob: String?,
    val meshSHA256: String?,
    val brepBlob: String?,
    val brepSHA256: String?,
    val isHidden: Boolean,
    val material: C04FloecadMaterial?,
)

private data class C04FloecadImageRecord(
    val id: String,
    val name: String,
    val blobPath: String,
    val sha256: String,
    val origin: DoubleArray,
    val xAxis: DoubleArray,
    val yAxis: DoubleArray,
    val width: Double,
    val height: Double,
    val opacity: Double,
    val hidden: Boolean,
)

private data class C04FloecadImageInfo(
    val name: String,
    val origin: DoubleArray,
    val xAxis: DoubleArray,
    val yAxis: DoubleArray,
    val width: Double,
    val height: Double,
    val opacity: Double,
    val hidden: Boolean,
)

private data class C04FloecadDocument(
    val bodies: List<C04FloecadBodyRecord>,
    val images: List<C04FloecadImageRecord>,
    val assembly: ByteArray?,
    val drawings: ByteArray?,
)

/** Column-major 4x4 (three.js/glTF convention). */
internal class C04FloecadMatrix private constructor(val values: DoubleArray) {
    init {
        require(values.size == 16)
    }

    fun multiply(other: C04FloecadMatrix): C04FloecadMatrix {
        val a = values
        val b = other.values
        val out = DoubleArray(16)
        for (column in 0 until 4) {
            for (row in 0 until 4) {
                var sum = 0.0
                for (k in 0 until 4) {
                    sum += a[k * 4 + row] * b[column * 4 + k]
                }
                out[column * 4 + row] = sum
            }
        }
        return C04FloecadMatrix(out)
    }

    fun transformPoint(x: Double, y: Double, z: Double): DoubleArray = doubleArrayOf(
        values[0] * x + values[4] * y + values[8] * z + values[12],
        values[1] * x + values[5] * y + values[9] * z + values[13],
        values[2] * x + values[6] * y + values[10] * z + values[14],
    )

    companion object {
        val IDENTITY = C04FloecadMatrix(doubleArrayOf(
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0,
        ))

        fun fromTrs(
            tx: Double, ty: Double, tz: Double,
            qx: Double, qy: Double, qz: Double, qw: Double,
            sx: Double, sy: Double, sz: Double,
        ): C04FloecadMatrix {
            if (!tx.isFinite() || !ty.isFinite() || !tz.isFinite() ||
                !qx.isFinite() || !qy.isFinite() || !qz.isFinite() || !qw.isFinite() ||
                !sx.isFinite() || !sy.isFinite() || !sz.isFinite() ||
                kotlin.math.abs(tx) > C04FloecadLimits.MAX_ABS_COORDINATE ||
                kotlin.math.abs(ty) > C04FloecadLimits.MAX_ABS_COORDINATE ||
                kotlin.math.abs(tz) > C04FloecadLimits.MAX_ABS_COORDINATE ||
                kotlin.math.abs(sx) > C04FloecadLimits.MAX_ABS_SCALE ||
                kotlin.math.abs(sy) > C04FloecadLimits.MAX_ABS_SCALE ||
                kotlin.math.abs(sz) > C04FloecadLimits.MAX_ABS_SCALE
            ) {
                throw C04FloecadFailure("invalidPackage", "transform")
            }
            val length = kotlin.math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
            if (!length.isFinite() || length < 1e-12) {
                throw C04FloecadFailure("invalidPackage", "rotation")
            }
            val x = qx / length
            val y = qy / length
            val z = qz / length
            val w = qw / length
            val m = DoubleArray(16)
            m[0] = (1 - 2 * (y * y + z * z)) * sx
            m[1] = (2 * (x * y + z * w)) * sx
            m[2] = (2 * (x * z - y * w)) * sx
            m[3] = 0.0
            m[4] = (2 * (x * y - z * w)) * sy
            m[5] = (1 - 2 * (x * x + z * z)) * sy
            m[6] = (2 * (y * z + x * w)) * sy
            m[7] = 0.0
            m[8] = (2 * (x * z + y * w)) * sz
            m[9] = (2 * (y * z - x * w)) * sz
            m[10] = (1 - 2 * (x * x + y * y)) * sz
            m[11] = 0.0
            m[12] = tx
            m[13] = ty
            m[14] = tz
            m[15] = 1.0
            return C04FloecadMatrix(m)
        }
    }
}

// MARK: - Derived GLB builder

private data class C04FloecadBuilt(
    val file: File,
    val bytes: Long,
    val sha256: String,
    val meshCount: Int,
    val triangleCount: Int,
    val vertexCount: Int,
    val minimum: DoubleArray,
    val maximum: DoubleArray,
    val brepOnlyCount: Int,
    val brepPlacements: List<C04FloecadBrepPlacement>,
    val truncatedBrepPlacements: Int,
    val skippedTextures: Int,
    val convertedWebpTextures: Int,
    val hdrTextures: Int,
    val missing: List<String>,
)

private data class C04FloecadMeshData(
    val positions: FloatArray,
    val normals: FloatArray,
    val indices: IntArray,
    val uvs: FloatArray?,
)

private class C04FloecadGlbBuilder(
    private val json: Json,
    private val imageDecoder: C04FloecadImageDecoder?,
) {
    private data class BodyMesh(
        val meshIndex: Int,
        val materialIndex: Int,
        val triangles: Int,
        val vertices: Int,
        /** Source-millimetre positions, used for package bounds only. */
        val sourcePositions: FloatArray,
    )

    fun build(
        packageRoot: String,
        manifest: C04FloecadManifest,
        bodies: List<C04FloecadBodyRecord>,
        images: List<C04FloecadImageRecord>,
        instances: List<C04FloecadInstance>,
        resources: Map<String, C04FloecadResource>,
        outputDirectory: File,
        check: () -> Unit,
    ): C04FloecadBuilt {
        val nodes = ArrayList<JsonObject>()
        val meshes = ArrayList<JsonObject>()
        val materials = ArrayList<JsonObject>()
        val accessors = ArrayList<JsonObject>()
        val bufferViews = ArrayList<JsonObject>()
        val imagesJson = ArrayList<JsonObject>()
        val texturesJson = ArrayList<JsonObject>()
        val bin = C04FloecadBinBuilder()
        val meshByBody = HashMap<String, BodyMesh>()
        val missing = ArrayList<String>()
        var skippedTextures = 0
        var convertedWebpTextures = 0
        var hdrTextures = 0
        var textureBytes = 0L
        var brepOnly = 0
        var truncatedBrepPlacements = 0
        var totalTriangles = 0
        var totalVertices = 0
        var minX = Double.POSITIVE_INFINITY
        var minY = Double.POSITIVE_INFINITY
        var minZ = Double.POSITIVE_INFINITY
        var maxX = Double.NEGATIVE_INFINITY
        var maxY = Double.NEGATIVE_INFINITY
        var maxZ = Double.NEGATIVE_INFINITY

        fun addTexture(sourceBytes: ByteArray): Int? {
            if (sourceBytes.isEmpty() || sourceBytes.size > C04FloecadLimits.MAX_TEXTURE_BYTES ||
                imagesJson.size >= C04FloecadLimits.MAX_TEXTURES
            ) return null
            var bytes = sourceBytes
            var mime = imageMime(bytes) ?: return null
            if (mime == "image/webp") {
                val decoded = try {
                    imageDecoder?.toPng(bytes, mime)
                } catch (_: Throwable) {
                    null
                } ?: return null
                if (imageMime(decoded) != "image/png") return null
                bytes = decoded
                mime = "image/png"
                convertedWebpTextures += 1
            }
            if (mime !in C04FloecadLimits.GLB_IMAGE_MEDIA_TYPES) return null
            if (mime == "image/png") {
                C04CadPng.inspectTexture(bytes) ?: return null
                if (pngBitDepth(bytes) == 16) hdrTextures += 1
            }
            textureBytes += bytes.size
            if (textureBytes > C04FloecadLimits.MAX_TEXTURE_TOTAL_BYTES) {
                throw C04FloecadFailure("previewTooLarge", "textureBytes")
            }
            val view = bin.add(bytes)
            bufferViews.add(buildJsonObject {
                put("buffer", 0)
                put("byteOffset", view.first)
                put("byteLength", view.second)
            })
            imagesJson.add(buildJsonObject {
                put("bufferView", bufferViews.size - 1)
                put("mimeType", mime)
            })
            texturesJson.add(buildJsonObject {
                put("sampler", 0)
                put("source", imagesJson.size - 1)
            })
            return texturesJson.size - 1
        }

        fun addMaterial(
            name: String,
            color: DoubleArray,
            metallic: Double,
            roughness: Double,
            opacity: Double,
            texture: Int?,
        ): Int {
            materials.add(buildJsonObject {
                put("name", name.take(C04FloecadLimits.MAX_NAME_CHARS))
                put("pbrMetallicRoughness", buildJsonObject {
                    put("baseColorFactor", buildJsonArray { color.forEach { add(JsonPrimitive(it)) } })
                    put("metallicFactor", metallic.coerceIn(0.0, 1.0))
                    put("roughnessFactor", roughness.coerceIn(0.0, 1.0))
                    if (texture != null) {
                        put("baseColorTexture", buildJsonObject { put("index", texture) })
                    }
                })
                put("doubleSided", true)
                if (opacity < 0.999) put("alphaMode", "BLEND")
            })
            return materials.size - 1
        }

        fun addMesh(
            name: String,
            sourcePositions: FloatArray,
            normals: FloatArray,
            indices: IntArray,
            uvs: FloatArray?,
            materialIndex: Int,
        ): Int {
            // The GLB is glTF 2.0: positions MUST be metres. Source OS3D and
            // OCCT values are millimetres, so the rendered copy is converted
            // here while package bounds keep the original millimetres.
            val positions = FloatArray(sourcePositions.size) { index ->
                (sourcePositions[index] * C04FloecadLimits.MILLIMETERS_TO_METERS).toFloat()
            }
            val positionsAccessor = addFloatAccessor(bin, accessors, bufferViews,
                positions, 3, 34962, withBounds = true)
            val normalsAccessor = addFloatAccessor(bin, accessors, bufferViews,
                normals, 3, 34962, withBounds = false)
            val uvAccessor = if (uvs != null && uvs.size == (positions.size / 3) * 2) {
                addFloatAccessor(bin, accessors, bufferViews, uvs, 2, 34962, withBounds = false)
            } else null
            val indexAccessor = addIndexAccessor(bin, accessors, bufferViews, indices)
            meshes.add(buildJsonObject {
                put("name", name.take(C04FloecadLimits.MAX_NAME_CHARS))
                put("primitives", buildJsonArray {
                    add(buildJsonObject {
                        put("attributes", buildJsonObject {
                            put("POSITION", positionsAccessor)
                            put("NORMAL", normalsAccessor)
                            if (uvAccessor != null) put("TEXCOORD_0", uvAccessor)
                        })
                        put("indices", indexAccessor)
                        put("material", materialIndex)
                        put("mode", 4)
                    })
                })
            })
            return meshes.size - 1
        }

        fun updateBounds(positions: FloatArray, matrix: C04FloecadMatrix?) {
            var index = 0
            while (index + 2 < positions.size) {
                val point = if (matrix == null) {
                    doubleArrayOf(positions[index].toDouble(), positions[index + 1].toDouble(), positions[index + 2].toDouble())
                } else {
                    matrix.transformPoint(
                        positions[index].toDouble(), positions[index + 1].toDouble(), positions[index + 2].toDouble())
                }
                minX = minOf(minX, point[0]); maxX = maxOf(maxX, point[0])
                minY = minOf(minY, point[1]); maxY = maxOf(maxY, point[1])
                minZ = minOf(minZ, point[2]); maxZ = maxOf(maxZ, point[2])
                index += 3
            }
        }

        fun gltfMatrix(matrix: C04FloecadMatrix): DoubleArray =
            matrix.values.copyOf().also { values ->
                values[12] *= C04FloecadLimits.MILLIMETERS_TO_METERS
                values[13] *= C04FloecadLimits.MILLIMETERS_TO_METERS
                values[14] *= C04FloecadLimits.MILLIMETERS_TO_METERS
            }

        fun addMeshNode(name: String, matrix: C04FloecadMatrix, mesh: BodyMesh) {
            nodes.add(buildJsonObject {
                put("name", name.take(C04FloecadLimits.MAX_NAME_CHARS))
                put("mesh", mesh.meshIndex)
                put("matrix", buildJsonArray {
                    gltfMatrix(matrix).forEach { add(JsonPrimitive(it)) }
                })
            })
            totalTriangles += mesh.triangles
            totalVertices += mesh.vertices
            updateBounds(mesh.sourcePositions, matrix)
        }

        for (body in bodies) {
            check()
            val meshPath = body.meshBlob
            if (meshPath == null) {
                if (body.brepBlob != null) brepOnly += 1 else missing.add(body.name.take(80))
                continue
            }
            val resource = resources[meshPath]
                ?: throw C04FloecadFailure("invalidPackage", "meshResource")
            val mesh = decodeMesh(resource.file)
            if (mesh.indices.size / 3 + totalTriangles > C04FloecadLimits.MAX_TRIANGLES ||
                mesh.positions.size / 3 + totalVertices > C04FloecadLimits.MAX_VERTICES
            ) {
                throw C04FloecadFailure("previewTooLarge", "geometry")
            }
            val material = body.material ?: C04FloecadMaterial()
            var texture: Int? = null
            val materialTexture = material.baseColorTexture
            if (materialTexture != null && materialTexture.isNotEmpty()) {
                texture = if (mesh.uvs != null) addTexture(materialTexture) else null
                if (texture == null) skippedTextures += 1
            }
            val materialIndex = addMaterial(
                body.name, material.baseColor, material.metallic, material.roughness,
                material.opacity, texture)
            val meshIndex = addMesh(
                body.name, mesh.positions, mesh.normals, mesh.indices, mesh.uvs, materialIndex)
            meshByBody[body.bodyID.lowercase()] = BodyMesh(
                meshIndex, materialIndex, mesh.indices.size / 3,
                mesh.positions.size / 3, mesh.positions.copyOf())
        }

        for (image in images) {
            check()
            val resource = resources[image.blobPath]
                ?: throw C04FloecadFailure("invalidPackage", "imageResource")
            val bytes = readBytes(resource.file, C04FloecadLimits.MAX_TEXTURE_BYTES)
                ?: throw C04FloecadFailure("previewTooLarge", "imageBytes")
            val texture = addTexture(bytes)
            if (texture == null) {
                skippedTextures += 1
                continue
            }
            val quad = imageQuad(image)
            if (quad == null) {
                missing.add(image.name.take(80))
                continue
            }
            val materialIndex = addMaterial(
                image.name, doubleArrayOf(1.0, 1.0, 1.0, image.opacity),
                0.0, 1.0, image.opacity, texture)
            val meshIndex = addMesh(
                image.name, quad.positions, quad.normals, quad.indices, quad.uvs, materialIndex)
            nodes.add(buildJsonObject {
                put("name", image.name.take(C04FloecadLimits.MAX_NAME_CHARS))
                put("mesh", meshIndex)
            })
            totalTriangles += 2
            totalVertices += 4
            updateBounds(quad.positions, null)
        }

        val brepPlacements = ArrayList<C04FloecadBrepPlacement>()
        fun addBrepPlacement(name: String, body: C04FloecadBodyRecord, matrix: C04FloecadMatrix) {
            val blobPath = body.brepBlob ?: return
            val resource = resources[blobPath] ?: return
            if (brepPlacements.size >= C04FloecadLimits.MAX_ASSEMBLY_INSTANCES + C04FloecadLimits.MAX_BODIES) {
                truncatedBrepPlacements += 1
                return
            }
            // The pinned worker refuses inputs above 10 MiB; a larger B-Rep
            // is preserved but cannot be tessellated by that reader.
            if (resource.bytes > C04FloecadLimits.MAX_BREP_SOURCE_BYTES) {
                truncatedBrepPlacements += 1
                return
            }
            brepPlacements.add(C04FloecadBrepPlacement(
                name = name.take(C04FloecadLimits.MAX_NAME_CHARS),
                blobPath = blobPath,
                matrix = matrix.values.copyOf(),
            ))
        }

        for (body in bodies) {
            if (body.isHidden) continue
            val mesh = meshByBody[body.bodyID.lowercase()]
            if (mesh != null) {
                addMeshNode(body.name, body.transform, mesh)
            } else if (body.brepBlob != null) {
                addBrepPlacement(body.name, body, body.transform)
            }
        }
        for (instance in instances) {
            if (instance.hidden) continue
            val sourceID = (instance.copiedBodyID ?: instance.bodyID).lowercase()
            val body = bodies.firstOrNull { it.bodyID.equals(sourceID, ignoreCase = true) } ?: continue
            val mesh = meshByBody[sourceID]
            if (mesh != null) {
                addMeshNode(instance.name, instance.matrix.multiply(body.transform), mesh)
            } else if (body.brepBlob != null) {
                addBrepPlacement(instance.name, body, instance.matrix.multiply(body.transform))
            }
        }

        if (nodes.isEmpty() && brepPlacements.isEmpty()) {
            if (brepOnly > 0) {
                throw C04FloecadFailure("brepOnly", "brepTessellationLimit")
            }
            throw C04FloecadFailure("invalidPackage", "noGeometry")
        }
        if (totalTriangles > C04FloecadLimits.MAX_TRIANGLES ||
            totalVertices > C04FloecadLimits.MAX_VERTICES
        ) {
            throw C04FloecadFailure("previewTooLarge", "geometry")
        }

        val document = buildJsonObject {
            put("asset", buildJsonObject {
                put("version", "2.0")
                put("generator", "FloeAndroid C04C")
                put("extras", buildJsonObject {
                    // glTF 2.0 has no unit field: its normative unit is the
                    // metre, and this scene's positions/translations are
                    // already converted to metres. `extras` records the
                    // source scale for diagnostics only.
                    put("unit", "m")
                    put("sourceUnit", "mm")
                    put("sourceUnitScale", C04FloecadLimits.MILLIMETERS_TO_METERS)
                    put("upAxis", "y")
                    put("sourceFormat", "floecad")
                    put("packageSchema", manifest.schemaVersion)
                })
            })
            put("scene", 0)
            put("scenes", buildJsonArray {
                add(buildJsonObject {
                    put("nodes", buildJsonArray { nodes.indices.forEach { add(JsonPrimitive(it)) } })
                })
            })
            put("nodes", JsonArray(nodes))
            put("meshes", JsonArray(meshes))
            put("materials", JsonArray(materials))
            put("accessors", JsonArray(accessors))
            put("bufferViews", JsonArray(bufferViews))
            if (bin.size > 0) {
                put("buffers", buildJsonArray {
                    add(buildJsonObject { put("byteLength", bin.size) })
                })
            }
            if (imagesJson.isNotEmpty()) {
                put("images", JsonArray(imagesJson))
                put("textures", JsonArray(texturesJson))
                put("samplers", buildJsonArray {
                    add(buildJsonObject {
                        put("magFilter", 9729)
                        put("minFilter", 9987)
                        put("wrapS", 10497)
                        put("wrapT", 10497)
                    })
                })
            }
        }
        val bytes = encodeGlb(document.toString().toByteArray(Charsets.UTF_8), bin.toByteArray())
        if (bytes.size.toLong() > C04FloecadLimits.MAX_GLB_BYTES) {
            throw C04FloecadFailure("previewTooLarge", "glbBytes")
        }
        if (!outputDirectory.isDirectory && !outputDirectory.mkdirs()) {
            throw C04FloecadFailure("previewTooLarge", "outputDirectory")
        }
        check()
        val temp = File(outputDirectory, "preview-${UUID.randomUUID()}.glb.tmp")
        val file = File(outputDirectory, "preview.glb")
        try {
            temp.outputStream().use { output ->
                output.write(bytes)
                output.flush()
                output.fd.sync()
            }
            if (file.exists() && !file.delete()) {
                throw C04FloecadFailure("previewTooLarge", "outputFile")
            }
            if (!temp.renameTo(file)) {
                throw C04FloecadFailure("previewTooLarge", "outputFile")
            }
        } catch (error: C04FloecadFailure) {
            temp.delete()
            throw error
        } catch (_: Throwable) {
            temp.delete()
            throw C04FloecadFailure("previewTooLarge", "outputFile")
        }
        val sha = C04FloecadPackageReader.sha256(file)
        return C04FloecadBuilt(
            file = file,
            bytes = file.length(),
            sha256 = sha,
            meshCount = nodes.size,
            triangleCount = totalTriangles,
            vertexCount = totalVertices,
            minimum = doubleArrayOf(minX, minY, minZ),
            maximum = doubleArrayOf(maxX, maxY, maxZ),
            brepOnlyCount = brepOnly,
            brepPlacements = brepPlacements,
            truncatedBrepPlacements = truncatedBrepPlacements,
            skippedTextures = skippedTextures,
            convertedWebpTextures = convertedWebpTextures,
            hdrTextures = hdrTextures,
            missing = missing,
        )
    }

    private data class Quad(
        val positions: FloatArray,
        val normals: FloatArray,
        val uvs: FloatArray,
        val indices: IntArray,
    )

    private fun imageQuad(image: C04FloecadImageRecord): Quad? {
        val nx = image.yAxis[1] * image.xAxis[2] - image.yAxis[2] * image.xAxis[1]
        val ny = image.yAxis[2] * image.xAxis[0] - image.yAxis[0] * image.xAxis[2]
        val nz = image.yAxis[0] * image.xAxis[1] - image.yAxis[1] * image.xAxis[0]
        val length = kotlin.math.sqrt(nx * nx + ny * ny + nz * nz)
        if (!length.isFinite() || length < 1e-9) return null
        val hx = image.width / 2.0
        val hy = image.height / 2.0
        val corners = arrayOf(
            doubleArrayOf(image.origin[0] - image.xAxis[0] * hx - image.yAxis[0] * hy,
                image.origin[1] - image.xAxis[1] * hx - image.yAxis[1] * hy,
                image.origin[2] - image.xAxis[2] * hx - image.yAxis[2] * hy),
            doubleArrayOf(image.origin[0] + image.xAxis[0] * hx - image.yAxis[0] * hy,
                image.origin[1] + image.xAxis[1] * hx - image.yAxis[1] * hy,
                image.origin[2] + image.xAxis[2] * hx - image.yAxis[2] * hy),
            doubleArrayOf(image.origin[0] + image.xAxis[0] * hx + image.yAxis[0] * hy,
                image.origin[1] + image.xAxis[1] * hx + image.yAxis[1] * hy,
                image.origin[2] + image.xAxis[2] * hx + image.yAxis[2] * hy),
            doubleArrayOf(image.origin[0] - image.xAxis[0] * hx + image.yAxis[0] * hy,
                image.origin[1] - image.xAxis[1] * hx + image.yAxis[1] * hy,
                image.origin[2] - image.xAxis[2] * hx + image.yAxis[2] * hy),
        )
        if (corners.any { point -> point.any { !it.isFinite() || kotlin.math.abs(it) > C04FloecadLimits.MAX_ABS_COORDINATE } }) {
            return null
        }
        val positions = FloatArray(12)
        val normals = FloatArray(12)
        for (index in 0 until 4) {
            positions[index * 3] = corners[index][0].toFloat()
            positions[index * 3 + 1] = corners[index][1].toFloat()
            positions[index * 3 + 2] = corners[index][2].toFloat()
            normals[index * 3] = (nx / length).toFloat()
            normals[index * 3 + 1] = (ny / length).toFloat()
            normals[index * 3 + 2] = (nz / length).toFloat()
        }
        return Quad(
            positions = positions,
            normals = normals,
            uvs = floatArrayOf(0f, 1f, 1f, 1f, 1f, 0f, 0f, 0f),
            indices = intArrayOf(0, 1, 2, 0, 2, 3),
        )
    }

    private fun decodeMesh(file: File): C04FloecadMeshData {
        val bytes = readBytes(file, C04FloecadLimits.MAX_BLOB_BYTES)
            ?: throw C04FloecadFailure("invalidPackage", "meshRead")
        if (bytes.size < 16) throw C04FloecadFailure("invalidPackage", "meshTruncated")
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val magic = buffer.int
        if (magic != 0x4F533344) throw C04FloecadFailure("invalidPackage", "meshMagic")
        val version = buffer.int
        if (version != 1 && version != 2) {
            throw C04FloecadFailure("unsupportedPackage", "meshVersion")
        }
        val vertexCount = buffer.int
        val indexCount = buffer.int
        if (vertexCount < 0 || indexCount < 0 ||
            vertexCount > C04FloecadLimits.MAX_VERTICES ||
            indexCount > C04FloecadLimits.MAX_TRIANGLES * 3
        ) {
            throw C04FloecadFailure("previewTooLarge", "meshCounts")
        }
        if (indexCount == 0 || indexCount % 3 != 0) {
            throw C04FloecadFailure("invalidPackage", "meshIndices")
        }
        val expected = 16L + vertexCount.toLong() * 24L + indexCount.toLong() * 4L +
            if (version == 2) vertexCount.toLong() * 8L else 0L
        if (expected != bytes.size.toLong()) {
            throw C04FloecadFailure("invalidPackage", if (expected > bytes.size) "meshTruncated" else "meshLength")
        }
        val positions = FloatArray(vertexCount * 3)
        for (index in positions.indices) {
            val value = buffer.float
            if (!value.isFinite() || kotlin.math.abs(value.toDouble()) > C04FloecadLimits.MAX_ABS_COORDINATE) {
                throw C04FloecadFailure("invalidPackage", "meshPosition")
            }
            positions[index] = value
        }
        val normals = FloatArray(vertexCount * 3)
        for (index in normals.indices) {
            val value = buffer.float
            if (!value.isFinite()) throw C04FloecadFailure("invalidPackage", "meshNormal")
            normals[index] = value
        }
        val indices = IntArray(indexCount)
        for (index in indices.indices) {
            val value = buffer.int
            if (value < 0 || value >= vertexCount) {
                throw C04FloecadFailure("invalidPackage", "meshIndex")
            }
            indices[index] = value
        }
        val uvs = if (version == 2) {
            FloatArray(vertexCount * 2).also { values ->
                for (index in values.indices) {
                    val value = buffer.float
                    if (!value.isFinite()) throw C04FloecadFailure("invalidPackage", "meshUV")
                    values[index] = value
                }
            }
        } else null
        return C04FloecadMeshData(positions, normals, indices, uvs)
    }

    private fun readBytes(file: File, maximum: Long): ByteArray? {
        if (!file.isFile || file.length() > maximum) return null
        return try {
            FileInputStream(file).use { input ->
                val output = ByteArrayOutputStream(minOf(file.length(), maximum).toInt())
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    output.write(buffer, 0, read)
                    if (output.size().toLong() > maximum) return null
                }
                output.toByteArray()
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun pngBitDepth(bytes: ByteArray): Int =
        if (bytes.size > 24) bytes[24].toInt() and 0xFF else 8

    private fun imageMime(bytes: ByteArray): String? {
        if (bytes.size >= 8 && bytes[0] == 0x89.toByte() && bytes[1] == 0x50.toByte() &&
            bytes[2] == 0x4E.toByte() && bytes[3] == 0x47.toByte()
        ) return "image/png"
        if (bytes.size >= 3 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte() &&
            bytes[2] == 0xFF.toByte()
        ) return "image/jpeg"
        if (bytes.size >= 12 && String(bytes, 0, 4, Charsets.US_ASCII) == "RIFF" &&
            String(bytes, 8, 4, Charsets.US_ASCII) == "WEBP"
        ) return "image/webp"
        return null
    }

    private fun addFloatAccessor(
        bin: C04FloecadBinBuilder,
        accessors: MutableList<JsonObject>,
        bufferViews: MutableList<JsonObject>,
        values: FloatArray,
        components: Int,
        target: Int,
        withBounds: Boolean,
    ): Int {
        val view = bin.addFloats(values)
        bufferViews.add(buildJsonObject {
            put("buffer", 0)
            put("byteOffset", view.first)
            put("byteLength", view.second)
            put("target", target)
        })
        val count = values.size / components
        val objectValue = buildJsonObject {
            put("bufferView", bufferViews.size - 1)
            put("componentType", 5126)
            put("count", count)
            put("type", if (components == 2) "VEC2" else "VEC3")
            if (withBounds) {
                var minX = Float.MAX_VALUE
                var minY = Float.MAX_VALUE
                var minZ = Float.MAX_VALUE
                var maxX = -Float.MAX_VALUE
                var maxY = -Float.MAX_VALUE
                var maxZ = -Float.MAX_VALUE
                var index = 0
                while (index + 2 < values.size) {
                    minX = minOf(minX, values[index]); maxX = maxOf(maxX, values[index])
                    minY = minOf(minY, values[index + 1]); maxY = maxOf(maxY, values[index + 1])
                    minZ = minOf(minZ, values[index + 2]); maxZ = maxOf(maxZ, values[index + 2])
                    index += 3
                }
                put("min", buildJsonArray {
                    add(JsonPrimitive(minX.toDouble()))
                    add(JsonPrimitive(minY.toDouble()))
                    add(JsonPrimitive(minZ.toDouble()))
                })
                put("max", buildJsonArray {
                    add(JsonPrimitive(maxX.toDouble()))
                    add(JsonPrimitive(maxY.toDouble()))
                    add(JsonPrimitive(maxZ.toDouble()))
                })
            }
        }
        accessors.add(objectValue)
        return accessors.size - 1
    }

    private fun addIndexAccessor(
        bin: C04FloecadBinBuilder,
        accessors: MutableList<JsonObject>,
        bufferViews: MutableList<JsonObject>,
        indices: IntArray,
    ): Int {
        val view = bin.addInts(indices)
        bufferViews.add(buildJsonObject {
            put("buffer", 0)
            put("byteOffset", view.first)
            put("byteLength", view.second)
            put("target", 34963)
        })
        accessors.add(buildJsonObject {
            put("bufferView", bufferViews.size - 1)
            put("componentType", 5125)
            put("count", indices.size)
            put("type", "SCALAR")
        })
        return accessors.size - 1
    }

    private fun encodeGlb(jsonBytes: ByteArray, binBytes: ByteArray): ByteArray {
        val jsonPadding = (4 - jsonBytes.size % 4) % 4
        val jsonLength = jsonBytes.size + jsonPadding
        val binPadding = (4 - binBytes.size % 4) % 4
        val binLength = binBytes.size + binPadding
        val total = 12 + 8 + jsonLength + if (binBytes.isEmpty()) 0 else 8 + binLength
        val output = ByteArray(total)
        val buffer = ByteBuffer.wrap(output).order(ByteOrder.LITTLE_ENDIAN)
        buffer.putInt(0x46546C67)
        buffer.putInt(2)
        buffer.putInt(total)
        buffer.putInt(jsonLength)
        buffer.putInt(0x4E4F534A)
        buffer.put(jsonBytes)
        repeat(jsonPadding) { buffer.put(0x20.toByte()) }
        if (binBytes.isNotEmpty()) {
            buffer.putInt(binLength)
            buffer.putInt(0x004E4942)
            buffer.put(binBytes)
            repeat(binPadding) { buffer.put(0.toByte()) }
        }
        return output
    }
}

private class C04FloecadBinBuilder {
    private val out = ByteArrayOutputStream()
    val size: Int get() = out.size()

    fun add(bytes: ByteArray): Pair<Int, Int> {
        align()
        val offset = out.size()
        out.write(bytes)
        return offset to bytes.size
    }

    fun addFloats(values: FloatArray, target: Int = 0): Pair<Int, Int> {
        align()
        val offset = out.size()
        val buffer = ByteBuffer.allocate(values.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        values.forEach { buffer.putFloat(it) }
        out.write(buffer.array())
        return offset to values.size * 4
    }

    fun addInts(values: IntArray): Pair<Int, Int> {
        align()
        val offset = out.size()
        val buffer = ByteBuffer.allocate(values.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        values.forEach { buffer.putInt(it) }
        out.write(buffer.array())
        return offset to values.size * 4
    }

    fun toByteArray(): ByteArray = out.toByteArray()

    private fun align() {
        while (out.size() % 4 != 0) out.write(0)
    }
}
