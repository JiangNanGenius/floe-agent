// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials.hostinterop

import android.content.Context
import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import com.floe.android.credentials.AndroidKeystoreCredentialStore
import com.floe.android.credentials.CredentialTestSupport
import com.floe.android.credentials.debug.DebugCredentialStoreAccess
import com.floe.android.credentials.debug.DebugSealedEnrollment
import com.floe.android.credentials.debug.EnrollmentDescriptor
import com.floe.android.credentials.debug.SealedEnrollmentProtocol
import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes
import java.security.KeyStore
import org.json.JSONObject

/**
 * Test-owned host -> Android sealed-enrollment interop fixture.
 *
 * Phase 1 exports only the public descriptor to
 * `noBackupFilesDir/floe-qa-host-interop/descriptor.json`. The host sealer
 * reads that descriptor through `run-as`, seals the fixed synthetic [PAYLOAD]
 * in host memory and writes only ciphertext to `sealed.bin`. Phase 2 imports it
 * with the real [DebugSealedEnrollment.importSealed].
 *
 * Every path here is inside the test package's app-private no-backup storage.
 * No plaintext payload is written, logged or passed in an instrumentation
 * argument.
 */
internal object HostInteropTestSupport {
    const val NAMESPACE = "qa.host.interop"
    const val REFERENCE = "qa.host.interop.v1"
    const val PHASE_ARGUMENT = "floeHostInteropPhase"
    const val DIRECTORY = "floe-qa-host-interop"
    const val DESCRIPTOR_FILE = "descriptor.json"
    const val SEALED_FILE = "sealed.bin"

    /**
     * Fixed synthetic payload. Its exact UTF-8 bytes and SHA-256 are recorded
     * in the private handoff so Main can feed the same bytes to the host
     * sealer without any file, argv or environment transport of plaintext.
     */
    val PAYLOAD: ByteArray =
        "Floe host->Android interop payload v1 2026-10-18 中文".toByteArray(StandardCharsets.UTF_8)

    private const val MAX_DESCRIPTOR_BYTES = 8 * 1024
    private const val MAX_STATE_BYTES = 4 * 1024

    fun phase(): String? = InstrumentationRegistry.getArguments().getString(PHASE_ARGUMENT)

    fun directory(context: Context): File = File(context.noBackupFilesDir, DIRECTORY)

    fun descriptorFile(context: Context): File = File(directory(context), DESCRIPTOR_FILE)

    fun sealedFile(context: Context): File = File(directory(context), SEALED_FILE)

    /**
     * Writes the exact seven-key public descriptor mapping expected by
     * `FloeAndroid/scripts/seal-debug-credential.py`.
     */
    fun writeDescriptor(context: Context, descriptor: EnrollmentDescriptor) {
        val directory = directory(context)
        if (Files.isSymbolicLink(directory.toPath())) {
            throw AssertionError("host-interop directory is a symbolic link")
        }
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw AssertionError("host-interop directory could not be created")
        }
        val json = JSONObject()
            .put("protocolVersion", descriptor.protocolVersion)
            .put("sessionID", descriptor.sessionID)
            .put("packageName", descriptor.packageName)
            .put("namespace", descriptor.namespace)
            .put("reference", descriptor.reference)
            .put("expiresAtEpochMillis", descriptor.expiresAtEpochMillis)
            .put(
                "publicKeyDerBase64",
                Base64.encodeToString(descriptor.publicKeyDer, Base64.NO_WRAP),
            )
        val bytes = json.toString().toByteArray(StandardCharsets.UTF_8)
        if (bytes.size > MAX_DESCRIPTOR_BYTES) {
            throw AssertionError("public descriptor exceeds the bound")
        }
        val target = descriptorFile(context)
        val temporary = File(directory, "$DESCRIPTOR_FILE.tmp")
        temporary.writeBytes(bytes)
        try {
            Files.move(
                temporary.toPath(),
                target.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (error: AtomicMoveNotSupportedException) {
            Files.move(
                temporary.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
            )
        }
        if (!isBoundedRegularFile(target, MAX_DESCRIPTOR_BYTES)) {
            throw AssertionError("public descriptor was not written as a bounded regular file")
        }
    }

    fun readDescriptor(context: Context): JSONObject {
        val file = descriptorFile(context)
        if (!isBoundedRegularFile(file, MAX_DESCRIPTOR_BYTES)) {
            throw AssertionError("public descriptor is missing, symbolic or out of bounds")
        }
        return JSONObject(String(file.readBytes(), StandardCharsets.UTF_8))
    }

    fun sessionId(descriptor: JSONObject): String {
        if (descriptor.optInt("protocolVersion", -1) != SealedEnrollmentProtocol.VERSION) {
            throw AssertionError("public descriptor protocol version is not 1")
        }
        val sessionID = descriptor.optString("sessionID", "")
        if (!SealedEnrollmentProtocol.isSessionId(sessionID)) {
            throw AssertionError("public descriptor session id is invalid")
        }
        if (descriptor.optString("packageName", "").isBlank() ||
            descriptor.optString("namespace", "") != NAMESPACE ||
            descriptor.optString("reference", "") != REFERENCE ||
            descriptor.optLong("expiresAtEpochMillis", 0L) <= 0L ||
            descriptor.optString("publicKeyDerBase64", "").isEmpty()
        ) {
            throw AssertionError("public descriptor fields do not match the interop fixture")
        }
        return sessionID
    }

    /**
     * Reads `sealed.bin` only after checking its exact size against the wire
     * bounds. The real import repeats the structural bounds check.
     */
    fun readSealed(context: Context): ByteArray {
        val file = sealedFile(context)
        val attributes = attributesOrNull(file)
            ?: throw AssertionError("sealed.bin is missing; run the host sealer first")
        if (attributes.isSymbolicLink || !attributes.isRegularFile) {
            throw AssertionError("sealed.bin is not a regular file")
        }
        if (attributes.size() < SealedEnrollmentProtocol.MIN_SEALED_BYTES ||
            attributes.size() > SealedEnrollmentProtocol.MAX_SEALED_BYTES
        ) {
            throw AssertionError(
                "sealed.bin size ${attributes.size()} is outside " +
                    "${SealedEnrollmentProtocol.MIN_SEALED_BYTES}.." +
                    SealedEnrollmentProtocol.MAX_SEALED_BYTES,
            )
        }
        val bytes = file.readBytes()
        if (bytes.size.toLong() != attributes.size()) {
            throw AssertionError("sealed.bin changed while it was being read")
        }
        return bytes
    }

    /**
     * Removes only this fixture's credential reference, namespace, owned
     * session state/keys and app-private interop directory. It also removes
     * orphan debug-QA session keys whose state is absent (an interruption
     * between `begin` and the descriptor write); it never touches another
     * namespace's session, production credential keys or another package.
     */
    fun cleanup(context: Context): Set<String> {
        val appContext = context.applicationContext ?: context
        val removed = linkedSetOf<String>()
        removed += ownedSessionIds(appContext)
        removed.forEach { sessionID ->
            runCatching { DebugSealedEnrollment.cancel(appContext, sessionID) }
        }

        val store = AndroidKeystoreCredentialStore(appContext, NAMESPACE)
        runCatching {
            CredentialTestSupport.runSuspendBlocking { store.delete(REFERENCE) }
        }
        runCatching { DebugCredentialStoreAccess.deleteNamespace(appContext, NAMESPACE) }

        val stateDirectory = File(appContext.noBackupFilesDir, SealedEnrollmentProtocol.SESSION_DIRECTORY)
        listSessionAliases().forEach { alias ->
            val sessionID = alias.removePrefix(SealedEnrollmentProtocol.SESSION_KEY_PREFIX)
            if (!SealedEnrollmentProtocol.isSessionId(sessionID) || sessionID in removed) {
                return@forEach
            }
            val stateFile = File(stateDirectory, "$sessionID.json")
            val state = readBoundedJson(stateFile, MAX_STATE_BYTES)
            val belongsToFixture = state == null ||
                (state.optString("namespace") == NAMESPACE &&
                    state.optString("reference") == REFERENCE)
            if (belongsToFixture) {
                removed += sessionID
                runCatching { DebugSealedEnrollment.cancel(appContext, sessionID) }
            }
        }

        deleteOwnedDirectory(directory(appContext))

        removed.forEach { sessionID ->
            runCatching {
                if (DebugSealedEnrollment.sessionKeyExists(sessionID)) {
                    DebugCredentialStoreAccess.deleteAlias(
                        SealedEnrollmentProtocol.aliasFor(sessionID),
                    )
                }
            }
            File(stateDirectory, "$sessionID.json").delete()
            File(stateDirectory, "$sessionID.consumed").delete()
            if (DebugSealedEnrollment.sessionStateExists(appContext, sessionID)) {
                throw AssertionError("owned session state remains after cleanup")
            }
            if (DebugSealedEnrollment.sessionKeyExists(sessionID)) {
                throw AssertionError("owned session key remains after cleanup")
            }
        }
        if (directory(appContext).exists()) {
            throw AssertionError("host-interop directory remains after cleanup")
        }
        return removed
    }

    private fun ownedSessionIds(context: Context): Set<String> {
        val ids = linkedSetOf<String>()
        val descriptor = readBoundedJson(descriptorFile(context), MAX_DESCRIPTOR_BYTES)
        if (descriptor != null) {
            runCatching { sessionId(descriptor) }.getOrNull()?.let(ids::add)
        }
        val stateDirectory = File(context.noBackupFilesDir, SealedEnrollmentProtocol.SESSION_DIRECTORY)
        stateDirectory.listFiles()?.forEach { file ->
            val name = file.name
            if (!name.endsWith(".json")) return@forEach
            val sessionID = name.removeSuffix(".json")
            if (!SealedEnrollmentProtocol.isSessionId(sessionID)) return@forEach
            val state = readBoundedJson(file, MAX_STATE_BYTES) ?: return@forEach
            if (state.optString("namespace") == NAMESPACE &&
                state.optString("reference") == REFERENCE
            ) {
                ids += sessionID
            }
        }
        return ids
    }

    private fun listSessionAliases(): List<String> = try {
        val keyStore = KeyStore.getInstance(SealedEnrollmentProtocol.ANDROID_KEYSTORE)
            .apply { load(null) }
        java.util.Collections.list(keyStore.aliases())
            .filter { it.startsWith(SealedEnrollmentProtocol.SESSION_KEY_PREFIX) }
    } catch (error: Exception) {
        throw AssertionError("AndroidKeyStore session alias enumeration failed", error)
    }

    private fun readBoundedJson(file: File, maxBytes: Int): JSONObject? {
        if (!isBoundedRegularFile(file, maxBytes)) return null
        return runCatching {
            JSONObject(String(file.readBytes(), StandardCharsets.UTF_8))
        }.getOrNull()
    }

    private fun isBoundedRegularFile(file: File, maxBytes: Int): Boolean {
        val attributes = attributesOrNull(file) ?: return false
        return !attributes.isSymbolicLink && attributes.isRegularFile &&
            attributes.size() > 0L && attributes.size() <= maxBytes.toLong()
    }

    private fun attributesOrNull(file: File): BasicFileAttributes? = try {
        Files.readAttributes(
            file.toPath(),
            BasicFileAttributes::class.java,
            LinkOption.NOFOLLOW_LINKS,
        )
    } catch (error: java.io.IOException) {
        null
    }

    private fun deleteOwnedDirectory(directory: File) {
        if (!directory.exists()) return
        if (Files.isSymbolicLink(directory.toPath())) {
            Files.deleteIfExists(directory.toPath())
        } else {
            directory.deleteRecursively()
        }
        if (directory.exists()) {
            throw AssertionError("host-interop directory could not be removed")
        }
    }
}
