// SPDX-License-Identifier: MPL-2.0
//
// Pure resource-reference resolution for the offline viewer. Imported CAD
// text/JSON is DATA: it may name a relative sidecar only inside the main
// file's authorized directory subtree. It can never name an absolute path, a
// content/file URL, another app's URI, a symlink target or a host path. The
// native workspace egress remains the only byte reader.
package com.floe.android.host.cad

import java.io.ByteArrayOutputStream
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.Locale
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

internal enum class C04CadReferenceKind { BUFFER, MATERIAL, IMAGE }

internal data class C04CadReference(
    val raw: String,
    val kind: C04CadReferenceKind,
    val required: Boolean,
)

internal data class C04CadResourceIssue(
    val reference: String,
    val code: String,
)

internal data class C04CadResolution(
    val references: List<C04CadReference> = emptyList(),
    val issues: List<C04CadResourceIssue> = emptyList(),
    val unsupportedExtensions: List<String> = emptyList(),
    val invalidMainBytes: Boolean = false,
)

/**
 * Canonical path/resource rules shared by the controller and JVM tests.
 * No Android type and no filesystem path is used here.
 */
internal object C04CadResourceResolver {
    private val json = Json { ignoreUnknownKeys = false }
    private val control = Regex("[\\u0000-\\u001F\\u007F]")
    private val scheme = Regex("^[A-Za-z][A-Za-z0-9+.-]*:")
    private val unsupportedRequired = setOf(
        "KHR_draco_mesh_compression",
        "EXT_meshopt_compression",
        "KHR_texture_basisu",
    )
    private val mtlMapKeys = setOf(
        "map_kd", "map_ka", "map_ks", "map_ke", "map_ns", "map_d",
        "map_bump", "bump", "normal", "disp", "decal", "refl", "map_tr",
    )

    fun mainDirectory(relativePath: String): String =
        relativePath.substringBeforeLast('/', "")

    fun extensionOf(relativePath: String): String =
        relativePath.substringAfterLast('.', "").lowercase(Locale.ROOT)

    /**
     * Resolves one reference to a canonical workspace-relative sidecar path.
     * Returns a stable issue code on refusal; never a host path.
     */
    fun resolve(raw: String, mainDirectory: String): Result<String> {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return Result.failure(C04CadResolveFailure("empty"))
        if (trimmed.toByteArray(Charsets.UTF_8).size > C04CadLimits.MAX_PATH_BYTES) {
            return Result.failure(C04CadResolveFailure("tooLong"))
        }
        if (control.containsMatchIn(trimmed)) return Result.failure(C04CadResolveFailure("control"))
        if (trimmed.startsWith("~")) return Result.failure(C04CadResolveFailure("home"))
        if (trimmed.startsWith("/")) return Result.failure(C04CadResolveFailure("absolute"))
        if (trimmed.contains("\\")) return Result.failure(C04CadResolveFailure("backslash"))
        if (scheme.containsMatchIn(trimmed)) return Result.failure(C04CadResolveFailure("scheme"))
        val decoded = percentDecode(trimmed) ?: return Result.failure(C04CadResolveFailure("encoding"))
        if (decoded.startsWith("/") || decoded.contains("\\") ||
            control.containsMatchIn(decoded) || scheme.containsMatchIn(decoded)
        ) {
            return Result.failure(C04CadResolveFailure("encodedPath"))
        }
        val components = decoded.split('/')
        if (components.any { it.isEmpty() || it == "." || it == ".." }) {
            return Result.failure(C04CadResolveFailure("traversal"))
        }
        if (components.any { it.toByteArray(Charsets.UTF_8).size > 255 }) {
            return Result.failure(C04CadResolveFailure("componentTooLong"))
        }
        val relative = if (mainDirectory.isEmpty()) {
            components.joinToString("/")
        } else {
            components.joinToString("/", prefix = "$mainDirectory/")
        }
        if (relative.toByteArray(Charsets.UTF_8).size > C04CadLimits.MAX_PATH_BYTES) {
            return Result.failure(C04CadResolveFailure("tooLong"))
        }
        return Result.success(relative)
    }

    /** Parses the main file for directly referenced sidecars. */
    fun discover(
        format: C04CadFormat,
        relativePath: String,
        bytes: ByteArray,
    ): C04CadResolution = when (format) {
        C04CadFormat.GLTF -> discoverGltf(bytes, isGlb = false)
        C04CadFormat.GLB -> discoverGltf(bytes, isGlb = true)
        C04CadFormat.OBJ -> discoverObj(bytes)
        else -> C04CadResolution()
    }

    /** Parses a staged MTL file for texture references. */
    fun discoverMtl(bytes: ByteArray): C04CadResolution {
        if (bytes.size > C04CadLimits.MAX_MTL_BYTES.toInt()) {
            return C04CadResolution(
                issues = listOf(C04CadResourceIssue("", "materialTooLarge")),
            )
        }
        val text = decodeText(bytes) ?: return C04CadResolution(
            issues = listOf(C04CadResourceIssue("", "invalidText")),
        )
        val references = ArrayList<C04CadReference>()
        for (line in text.lineSequence().take(200_000)) {
            val clean = line.substringBefore('#').trim()
            if (clean.isEmpty()) continue
            val key = clean.substringBefore(' ', "").lowercase(Locale.ROOT)
            if (key !in mtlMapKeys) continue
            val name = clean.substringAfter(' ', "").trim()
                .removeSurrounding("\"").substringAfterLast(' ').removeSurrounding("\"")
            if (name.isBlank()) continue
            references += C04CadReference(name, C04CadReferenceKind.IMAGE, required = false)
            if (references.size >= C04CadLimits.MAX_RESOURCES) break
        }
        return C04CadResolution(references = references)
    }

    private fun discoverGltf(bytes: ByteArray, isGlb: Boolean): C04CadResolution {
        if (bytes.size > C04CadLimits.MAX_PREFLIGHT_BYTES.toInt()) {
            return C04CadResolution(
                issues = listOf(C04CadResourceIssue("", "preflightTooLarge")),
            )
        }
        val jsonBytes = if (isGlb) glbJsonChunk(bytes) else bytes
            ?: return C04CadResolution(
                issues = listOf(C04CadResourceIssue("", "invalidGlb")),
                invalidMainBytes = true,
            )
        val root = try {
            json.parseToJsonElement(decodeText(jsonBytes)
                ?: throw IllegalArgumentException("encoding")) as? JsonObject
        } catch (_: Throwable) {
            null
        } ?: return C04CadResolution(
            issues = listOf(C04CadResourceIssue("", "invalidGltfJson")),
            invalidMainBytes = true,
        )
        val references = ArrayList<C04CadReference>()
        val issues = ArrayList<C04CadResourceIssue>()
        fun addArray(name: String, kind: C04CadReferenceKind, required: Boolean) {
            val array = root[name] as? JsonArray ?: return
            for (element in array) {
                val objectValue = element as? JsonObject ?: continue
                val uri = (objectValue["uri"] as? JsonPrimitive)?.contentOrNull ?: continue
                if (uri.startsWith("data:", ignoreCase = true)) continue
                references += C04CadReference(uri, kind, required)
                if (references.size >= C04CadLimits.MAX_RESOURCES) return
            }
        }
        addArray("buffers", C04CadReferenceKind.BUFFER, required = true)
        addArray("images", C04CadReferenceKind.IMAGE, required = false)
        val required = root["extensionsRequired"] as? JsonArray
        val unsupported = required
            ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            ?.filter { it in unsupportedRequired }
            .orEmpty()
        if (unsupported.isNotEmpty()) {
            issues += C04CadResourceIssue("", "unsupportedCompression")
        }
        return C04CadResolution(
            references = references,
            issues = issues,
            unsupportedExtensions = unsupported,
        )
    }

    private fun discoverObj(bytes: ByteArray): C04CadResolution {
        if (bytes.size > C04CadLimits.MAX_PREFLIGHT_BYTES.toInt()) {
            return C04CadResolution(
                issues = listOf(C04CadResourceIssue("", "preflightTooLarge")),
            )
        }
        val text = decodeText(bytes) ?: return C04CadResolution(
            issues = listOf(C04CadResourceIssue("", "invalidText")),
        )
        val references = ArrayList<C04CadReference>()
        for (line in text.lineSequence().take(500_000)) {
            val clean = line.substringBefore('#').trim()
            if (!clean.startsWith("mtllib ", ignoreCase = true)) continue
            val value = clean.substringAfter(' ', "").trim().removeSurrounding("\"")
            if (value.isBlank()) continue
            references += C04CadReference(
                value, C04CadReferenceKind.MATERIAL, required = false)
            if (references.size >= C04CadLimits.MAX_RESOURCES) break
        }
        return C04CadResolution(references = references)
    }

    private fun glbJsonChunk(bytes: ByteArray): ByteArray? {
        if (bytes.size < 20) return null
        if (bytes[0] != 'g'.code.toByte() || bytes[1] != 'l'.code.toByte() ||
            bytes[2] != 'T'.code.toByte() || bytes[3] != 'F'.code.toByte()
        ) return null
        val version = readUInt32LE(bytes, 4)
        val length = readUInt32LE(bytes, 8)
        if (version != 2u || length != bytes.size.toUInt()) return null
        val chunkLength = readUInt32LE(bytes, 12)
        val chunkType = readUInt32LE(bytes, 16)
        if (chunkType != 0x4E4F534Au) return null // JSON
        if (chunkLength > Int.MAX_VALUE.toUInt() ||
            20L + chunkLength.toLong() > bytes.size
        ) return null
        return bytes.copyOfRange(20, 20 + chunkLength.toInt())
    }

    private fun readUInt32LE(bytes: ByteArray, offset: Int): UInt =
        (bytes[offset].toUInt() and 0xFFu) or
            ((bytes[offset + 1].toUInt() and 0xFFu) shl 8) or
            ((bytes[offset + 2].toUInt() and 0xFFu) shl 16) or
            ((bytes[offset + 3].toUInt() and 0xFFu) shl 24)

    private fun decodeText(bytes: ByteArray): String? = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(java.nio.ByteBuffer.wrap(bytes))
            .toString()
    } catch (_: CharacterCodingException) {
        null
    }

    private fun percentDecode(value: String): String? {
        if (!value.contains('%')) return value
        val output = ByteArrayOutputStream(value.length)
        var index = 0
        while (index < value.length) {
            val char = value[index]
            if (char == '%') {
                if (index + 2 >= value.length) return null
                val high = hex(value[index + 1]) ?: return null
                val low = hex(value[index + 2]) ?: return null
                output.write((high shl 4) or low)
                index += 3
            } else {
                val encoded = char.toString().toByteArray(Charsets.UTF_8)
                output.write(encoded, 0, encoded.size)
                index += 1
            }
        }
        return try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(java.nio.ByteBuffer.wrap(output.toByteArray()))
                .toString()
        } catch (_: CharacterCodingException) {
            null
        }
    }

    private fun hex(value: Char): Int? = when (value) {
        in '0'..'9' -> value - '0'
        in 'a'..'f' -> value - 'a' + 10
        in 'A'..'F' -> value - 'A' + 10
        else -> null
    }
}

internal class C04CadResolveFailure(val code: String) : Exception(code)
