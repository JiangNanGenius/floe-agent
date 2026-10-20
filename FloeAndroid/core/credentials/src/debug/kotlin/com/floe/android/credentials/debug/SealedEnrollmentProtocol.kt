// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials.debug

import android.content.Context
import com.floe.android.credentials.AtomicRecordFile
import com.floe.android.credentials.CredentialFileMetadata
import com.floe.android.credentials.CredentialLimits
import com.floe.android.credentials.CredentialReferenceCodec
import com.floe.android.credentials.CredentialStoreException
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.nio.charset.StandardCharsets
import org.json.JSONException
import org.json.JSONObject

/**
 * Public wire constants and the debug-only session descriptor.
 *
 * The descriptor is intentionally public metadata: session id, package,
 * namespace, opaque reference, expiry and an X.509 RSA public key. The sealed
 * payload is a separate byte string and must never be logged or written to a
 * plaintext file.
 */
object SealedEnrollmentProtocol {
    const val VERSION = 1

    const val SESSION_ID_BYTES = 16
    const val SESSION_ID_HEX_CHARS = SESSION_ID_BYTES * 2
    const val AES_KEY_BYTES = 32
    const val AES_GCM_IV_BYTES = 12
    const val GCM_TAG_BITS = 128
    const val GCM_TAG_BYTES = 16
    const val RSA_KEY_BITS = 3072
    const val RSA_WRAPPED_KEY_BYTES = RSA_KEY_BITS / 8
    const val MAX_PAYLOAD_BYTES = CredentialLimits.MAX_SECRET_BYTES

    private const val HEADER_AND_WRAPPED =
        4 + 1 + 1 + SESSION_ID_BYTES + 1 + AES_GCM_IV_BYTES + 2 + RSA_WRAPPED_KEY_BYTES
    const val MIN_SEALED_BYTES = HEADER_AND_WRAPPED + GCM_TAG_BYTES
    const val MAX_SEALED_BYTES = HEADER_AND_WRAPPED + MAX_PAYLOAD_BYTES + GCM_TAG_BYTES

    const val DEFAULT_SESSION_TTL_MILLIS = 5 * 60 * 1000L
    const val MAX_SESSION_TTL_MILLIS = 15 * 60 * 1000L

    const val AES_TRANSFORMATION = "AES/GCM/NoPadding"
    const val RSA_TRANSFORMATION = "RSA/ECB/OAEPWithSHA-256AndMGF1Padding"
    const val ANDROID_KEYSTORE = "AndroidKeyStore"
    const val SESSION_KEY_PREFIX = "floe.qa.enroll.v1."
    const val SESSION_DIRECTORY = "floe-qa-enrollment"

    fun isSessionId(value: String): Boolean =
        value.length == SESSION_ID_HEX_CHARS && value.all { it in '0'..'9' || it in 'a'..'f' }

    fun aliasFor(sessionID: String): String = SESSION_KEY_PREFIX + sessionID
}

data class EnrollmentDescriptor(
    val protocolVersion: Int,
    val sessionID: String,
    val packageName: String,
    val namespace: String,
    val reference: String,
    val expiresAtEpochMillis: Long,
    val publicKeyDer: ByteArray,
) {
    override fun toString(): String =
        "EnrollmentDescriptor(protocolVersion=$protocolVersion, sessionID=$sessionID, " +
            "packageName=$packageName, namespace=$namespace, reference=$reference, " +
            "expiresAtEpochMillis=$expiresAtEpochMillis, publicKeyBytes=${publicKeyDer.size})"
}

data class EnrollmentImportResult(
    val sessionID: String,
    val reference: String,
    val byteCount: Int,
)

internal data class SessionState(
    val protocolVersion: Int,
    val sessionID: String,
    val packageName: String,
    val namespace: String,
    val reference: String,
    val createdAtEpochMillis: Long,
    val expiresAtEpochMillis: Long,
)

internal data class SealedEnvelope(
    val sessionID: String,
    val iv: ByteArray,
    val wrappedKey: ByteArray,
    val ciphertext: ByteArray,
)

/**
 * Envelope:
 *
 * ```
 * 0   4  "FLQE"
 * 4   1  protocol version (1)
 * 5   1  session id length (16)
 * 6  16  session id bytes
 * 22  1  AES-GCM IV length (12)
 * 23 12  random AES-GCM IV
 * 35  2  RSA-wrapped AES key length, big endian (384)
 * 37 384 RSA-OAEP(SHA-256, MGF1-SHA-1) wrapped AES-256 key
 * ...    AES-256-GCM ciphertext including 16-byte tag
 * ```
 */
internal object SealedEnvelopeCodec {
    private val MAGIC = byteArrayOf('F'.code.toByte(), 'L'.code.toByte(), 'Q'.code.toByte(), 'E'.code.toByte())

    fun encode(
        sessionID: ByteArray,
        iv: ByteArray,
        wrappedKey: ByteArray,
        ciphertext: ByteArray,
    ): ByteArray {
        if (sessionID.size != SealedEnrollmentProtocol.SESSION_ID_BYTES ||
            iv.size != SealedEnrollmentProtocol.AES_GCM_IV_BYTES ||
            wrappedKey.size != SealedEnrollmentProtocol.RSA_WRAPPED_KEY_BYTES ||
            ciphertext.size < SealedEnrollmentProtocol.GCM_TAG_BYTES ||
            ciphertext.size > SealedEnrollmentProtocol.MAX_PAYLOAD_BYTES + SealedEnrollmentProtocol.GCM_TAG_BYTES
        ) {
            throw DebugEnrollmentException.SealedEnvelopeRejected()
        }
        val total = 37 + wrappedKey.size + ciphertext.size
        if (total > SealedEnrollmentProtocol.MAX_SEALED_BYTES) {
            throw DebugEnrollmentException.SealedEnvelopeRejected()
        }
        val output = ByteArrayOutputStream(total)
        output.write(MAGIC)
        output.write(SealedEnrollmentProtocol.VERSION)
        output.write(sessionID.size)
        output.write(sessionID)
        output.write(iv.size)
        output.write(iv)
        writeU16(output, wrappedKey.size)
        output.write(wrappedKey)
        output.write(ciphertext)
        return output.toByteArray()
    }

    fun parse(bytes: ByteArray): SealedEnvelope {
        if (bytes.size < SealedEnrollmentProtocol.MIN_SEALED_BYTES ||
            bytes.size > SealedEnrollmentProtocol.MAX_SEALED_BYTES
        ) {
            throw DebugEnrollmentException.SealedEnvelopeRejected()
        }
        for (index in MAGIC.indices) {
            if (bytes[index] != MAGIC[index]) {
                throw DebugEnrollmentException.SealedEnvelopeRejected()
            }
        }
        if ((bytes[4].toInt() and 0xFF) != SealedEnrollmentProtocol.VERSION) {
            throw DebugEnrollmentException.SealedEnvelopeRejected()
        }
        if ((bytes[5].toInt() and 0xFF) != SealedEnrollmentProtocol.SESSION_ID_BYTES) {
            throw DebugEnrollmentException.SealedEnvelopeRejected()
        }
        val sessionEnd = 6 + SealedEnrollmentProtocol.SESSION_ID_BYTES
        if (bytes.size < sessionEnd + 1) {
            throw DebugEnrollmentException.SealedEnvelopeRejected()
        }
        if ((bytes[sessionEnd].toInt() and 0xFF) != SealedEnrollmentProtocol.AES_GCM_IV_BYTES) {
            throw DebugEnrollmentException.SealedEnvelopeRejected()
        }
        val ivStart = sessionEnd + 1
        val ivEnd = ivStart + SealedEnrollmentProtocol.AES_GCM_IV_BYTES
        if (bytes.size < ivEnd + 2 + SealedEnrollmentProtocol.GCM_TAG_BYTES) {
            throw DebugEnrollmentException.SealedEnvelopeRejected()
        }
        val wrappedLength = ((bytes[ivEnd].toInt() and 0xFF) shl 8) or (bytes[ivEnd + 1].toInt() and 0xFF)
        if (wrappedLength != SealedEnrollmentProtocol.RSA_WRAPPED_KEY_BYTES) {
            throw DebugEnrollmentException.SealedEnvelopeRejected()
        }
        val wrappedStart = ivEnd + 2
        val wrappedEnd = wrappedStart + wrappedLength
        if (bytes.size < wrappedEnd + SealedEnrollmentProtocol.GCM_TAG_BYTES) {
            throw DebugEnrollmentException.SealedEnvelopeRejected()
        }
        val ciphertext = bytes.copyOfRange(wrappedEnd, bytes.size)
        if (ciphertext.size > SealedEnrollmentProtocol.MAX_PAYLOAD_BYTES + SealedEnrollmentProtocol.GCM_TAG_BYTES) {
            throw DebugEnrollmentException.SealedEnvelopeRejected()
        }
        return SealedEnvelope(
            sessionID = bytes.copyOfRange(6, sessionEnd).toHex(),
            iv = bytes.copyOfRange(ivStart, ivEnd),
            wrappedKey = bytes.copyOfRange(wrappedStart, wrappedEnd),
            ciphertext = ciphertext,
        )
    }

    private fun writeU16(output: ByteArrayOutputStream, value: Int) {
        output.write((value ushr 8) and 0xFF)
        output.write(value and 0xFF)
    }
}

/**
 * AAD fields are length-prefixed and ordered:
 * `"FLEN" | version | u16(sessionID) | u16(package) | u16(namespace) |
 * u16(reference) | u64(expiresAtEpochMillis)`.
 *
 * The host sealer must reproduce these bytes exactly. Because the session id,
 * package, reference, namespace and expiry are authenticated, a ciphertext
 * sealed for one session or reference cannot be imported into another.
 */
internal object EnrollmentAad {
    private val MAGIC = byteArrayOf('F'.code.toByte(), 'L'.code.toByte(), 'E'.code.toByte(), 'N'.code.toByte())

    fun encode(descriptor: EnrollmentDescriptor): ByteArray =
        encode(
            descriptor.protocolVersion,
            descriptor.sessionID,
            descriptor.packageName,
            descriptor.namespace,
            descriptor.reference,
            descriptor.expiresAtEpochMillis,
        )

    fun encode(state: SessionState): ByteArray =
        encode(
            state.protocolVersion,
            state.sessionID,
            state.packageName,
            state.namespace,
            state.reference,
            state.expiresAtEpochMillis,
        )

    private fun encode(
        protocolVersion: Int,
        sessionID: String,
        packageName: String,
        namespace: String,
        reference: String,
        expiresAtEpochMillis: Long,
    ): ByteArray {
        if (protocolVersion !in 0..0xFF) throw DebugEnrollmentException.InvalidSession()
        val output = ByteArrayOutputStream(4 + 1 + 2 + 32 + 2 + 256 + 2 + 64 + 2 + 128 + 8)
        output.write(MAGIC)
        output.write(protocolVersion)
        writeField(output, sessionID)
        writeField(output, packageName)
        writeField(output, namespace)
        writeField(output, reference)
        writeU64(output, expiresAtEpochMillis)
        return output.toByteArray()
    }

    private fun writeField(output: ByteArrayOutputStream, value: String) {
        val bytes = value.toByteArray(StandardCharsets.UTF_8)
        if (bytes.size > 0xFFFF) throw DebugEnrollmentException.InvalidSession()
        writeU16(output, bytes.size)
        output.write(bytes)
    }

    private fun writeU16(output: ByteArrayOutputStream, value: Int) {
        output.write((value ushr 8) and 0xFF)
        output.write(value and 0xFF)
    }

    private fun writeU64(output: ByteArrayOutputStream, value: Long) {
        for (shift in 56 downTo 0 step 8) {
            output.write(((value ushr shift) and 0xFF).toInt())
        }
    }
}

/**
 * Debug-only JSON metadata under `noBackupFilesDir`. It contains no secret:
 * only the session id, package, namespace, opaque reference and timestamps.
 * The session private key is in AndroidKeyStore.
 */
internal object SessionStateStore {
    private const val MAX_STATE_BYTES = 4096
    private const val SUFFIX = ".json"
    private const val CONSUMED_SUFFIX = ".consumed"
    private val CONSUMED_MARKER =
        "Floe QA sealed session consumed\n".toByteArray(StandardCharsets.UTF_8)

    fun directory(context: Context): File =
        File(context.noBackupFilesDir, SealedEnrollmentProtocol.SESSION_DIRECTORY)

    fun stateFile(context: Context, sessionID: String): File {
        if (!SealedEnrollmentProtocol.isSessionId(sessionID)) {
            throw DebugEnrollmentException.InvalidSession()
        }
        return File(directory(context), "$sessionID$SUFFIX")
    }

    fun consumedFile(context: Context, sessionID: String): File {
        if (!SealedEnrollmentProtocol.isSessionId(sessionID)) {
            throw DebugEnrollmentException.InvalidSession()
        }
        return File(directory(context), "$sessionID$CONSUMED_SUFFIX")
    }

    fun write(context: Context, state: SessionState) {
        val file = stateFile(context, state.sessionID)
        val json = JSONObject()
            .put("protocolVersion", state.protocolVersion)
            .put("sessionID", state.sessionID)
            .put("packageName", state.packageName)
            .put("namespace", state.namespace)
            .put("reference", state.reference)
            .put("createdAtEpochMillis", state.createdAtEpochMillis)
            .put("expiresAtEpochMillis", state.expiresAtEpochMillis)
            .toString()
            .toByteArray(StandardCharsets.UTF_8)
        try {
            AtomicRecordFile.replace(file) { output -> output.write(json) }
        } catch (error: CredentialStoreException) {
            throw DebugEnrollmentException.SessionCreationFailed(error)
        }
    }

    fun read(context: Context, sessionID: String): SessionState? {
        val file = stateFile(context, sessionID)
        val attributes = try {
            CredentialFileMetadata.attributesOrNull(file)
        } catch (error: CredentialStoreException) {
            throw DebugEnrollmentException.InvalidSession(error)
        } ?: return null
        if (attributes.isSymbolicLink || !attributes.isRegularFile) {
            throw DebugEnrollmentException.InvalidSession()
        }
        if (attributes.size() <= 0L || attributes.size() > MAX_STATE_BYTES.toLong()) {
            throw DebugEnrollmentException.InvalidSession()
        }
        val bytes = readBounded(file)
        val json = try {
            JSONObject(String(bytes, StandardCharsets.UTF_8))
        } catch (error: JSONException) {
            throw DebugEnrollmentException.InvalidSession(error)
        }
        val state = try {
            SessionState(
                protocolVersion = json.getInt("protocolVersion"),
                sessionID = json.getString("sessionID"),
                packageName = json.getString("packageName"),
                namespace = json.getString("namespace"),
                reference = json.getString("reference"),
                createdAtEpochMillis = json.getLong("createdAtEpochMillis"),
                expiresAtEpochMillis = json.getLong("expiresAtEpochMillis"),
            )
        } catch (error: JSONException) {
            throw DebugEnrollmentException.InvalidSession(error)
        }
        if (state.protocolVersion != SealedEnrollmentProtocol.VERSION ||
            state.sessionID != sessionID ||
            state.packageName.isBlank() ||
            state.packageName.length > 256 ||
            state.createdAtEpochMillis <= 0 ||
            state.expiresAtEpochMillis <= state.createdAtEpochMillis
        ) {
            throw DebugEnrollmentException.InvalidSession()
        }
        try {
            CredentialReferenceCodec.requireNamespace(state.namespace)
            CredentialReferenceCodec.requireReference(state.reference)
        } catch (error: CredentialStoreException) {
            throw DebugEnrollmentException.InvalidSession(error)
        }
        return state
    }

    private fun readBounded(file: File): ByteArray {
        val buffer = ByteArray(MAX_STATE_BYTES + 1)
        var length = 0
        try {
            FileInputStream(file).use { input ->
                while (length < buffer.size) {
                    val count = input.read(buffer, length, buffer.size - length)
                    if (count < 0) break
                    length += count
                }
            }
        } catch (error: IOException) {
            throw DebugEnrollmentException.InvalidSession(error)
        } catch (error: SecurityException) {
            throw DebugEnrollmentException.InvalidSession(error)
        }
        if (length == 0 || length > MAX_STATE_BYTES) {
            throw DebugEnrollmentException.InvalidSession()
        }
        return buffer.copyOf(length)
    }

    fun exists(context: Context, sessionID: String): Boolean {
        if (!SealedEnrollmentProtocol.isSessionId(sessionID)) return false
        val attributes = try {
            CredentialFileMetadata.attributesOrNull(stateFile(context, sessionID))
        } catch (error: CredentialStoreException) {
            throw DebugEnrollmentException.InvalidSession(error)
        } ?: return false
        if (attributes.isSymbolicLink || !attributes.isRegularFile) {
            throw DebugEnrollmentException.InvalidSession()
        }
        return true
    }

    fun delete(context: Context, sessionID: String) {
        val file = stateFile(context, sessionID)
        val attributes = try {
            CredentialFileMetadata.attributesOrNull(file)
        } catch (error: CredentialStoreException) {
            throw DebugEnrollmentException.SessionCleanupFailed(error)
        } ?: return
        if (attributes.isSymbolicLink || !attributes.isRegularFile) {
            throw DebugEnrollmentException.SessionCleanupFailed()
        }
        val deleted = try {
            file.delete()
        } catch (error: SecurityException) {
            throw DebugEnrollmentException.SessionCleanupFailed(error)
        }
        if (deleted) return
        val remaining = try {
            CredentialFileMetadata.attributesOrNull(file)
        } catch (error: CredentialStoreException) {
            throw DebugEnrollmentException.SessionCleanupFailed(error)
        }
        if (remaining != null) throw DebugEnrollmentException.SessionCleanupFailed()
    }

    /**
     * Durably records that this session's one successful import attempt has
     * started. This marker is written atomically after the envelope is
     * authenticated and before the credential store is touched.
     */
    fun consume(context: Context, sessionID: String) {
        val marker = consumedFile(context, sessionID)
        val existing = try {
            CredentialFileMetadata.attributesOrNull(marker)
        } catch (error: CredentialStoreException) {
            throw DebugEnrollmentException.SessionConsumptionFailed(error)
        }
        if (existing != null) throw DebugEnrollmentException.SessionConsumed()
        try {
            AtomicRecordFile.replace(marker) { output -> output.write(CONSUMED_MARKER) }
        } catch (error: CredentialStoreException) {
            throw DebugEnrollmentException.SessionConsumptionFailed(error)
        }
    }

    fun isConsumed(context: Context, sessionID: String): Boolean {
        val marker = consumedFile(context, sessionID)
        val attributes = try {
            CredentialFileMetadata.attributesOrNull(marker)
        } catch (error: CredentialStoreException) {
            throw DebugEnrollmentException.SessionConsumptionFailed(error)
        } ?: return false
        if (attributes.isSymbolicLink || !attributes.isRegularFile) {
            throw DebugEnrollmentException.SessionConsumptionFailed()
        }
        return true
    }

    /** Best effort after state/key cleanup; the session is already unusable. */
    fun deleteConsumedMarker(context: Context, sessionID: String) {
        runCatching {
            val marker = consumedFile(context, sessionID)
            val attributes = CredentialFileMetadata.attributesOrNull(marker)
                ?: return@runCatching
            if (!attributes.isSymbolicLink && attributes.isRegularFile) {
                marker.delete()
            }
        }
    }

    fun list(context: Context): List<File> {
        val files = directory(context).listFiles() ?: return emptyList()
        return files
            .filter { it.isFile && it.name.endsWith(SUFFIX) }
            .sortedBy { it.name }
    }
}

internal fun ByteArray.toHex(): String {
    val alphabet = "0123456789abcdef"
    val chars = CharArray(size * 2)
    forEachIndexed { index, byte ->
        val value = byte.toInt() and 0xFF
        chars[index * 2] = alphabet[value ushr 4]
        chars[index * 2 + 1] = alphabet[value and 0x0F]
    }
    return String(chars)
}
