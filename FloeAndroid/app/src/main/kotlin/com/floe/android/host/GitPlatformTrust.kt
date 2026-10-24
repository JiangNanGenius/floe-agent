// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.Context
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.util.Base64
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/**
 * GitPlatformTrust — pure Android platform-trust bundle adapter for the
 * FloeGit native remote-operation seam (lane job-f74b2a485e9a4434).
 *
 * WHY THIS EXISTS (and nothing bigger):
 *  * Android 14+ ships its root trust anchors in the updatable Conscrypt
 *    APEX plus the system partition (official note:
 *    https://source.android.com/docs/core/ota/modular-system/conscrypt).
 *    A compile-time fixed path like /system/etc/security/cacerts is NOT
 *    proof of matching the currently configured OS trust on every device
 *    this app supports (old Samsung API 33 through new API 37).
 *  * The stable, public app-visible interface to the ACTUAL configured
 *    platform trust is javax.net.ssl/java.security:
 *    TrustManagerFactory.getInstance(getDefaultAlgorithm()) + init(null)
 *    yields the default X509TrustManager whose acceptedIssuers reflect
 *    this device's current OS trust store at call time (including
 *    user-added CA certificates wherever the platform exposes them to
 *    the app's default trust manager — the same visibility iOS gives).
 *  * libgit2's mbedTLS overlay cannot reach that framework object
 *    in-process, and the pinned backend never reads http.sslCAInfo/
 *    sslCAPath from any config (verified in lane against the vendored
 *    1.9.2 source), so the only supported native entry point is
 *    GIT_OPT_SET_SSL_CERT_LOCATIONS — installed by FloeGit through the
 *    Floe-authored C shim after this adapter exports the issuer set as
 *    PEM. This file performs that export; it is a platform adapter only:
 *    no business logic, no network stack, no libgit2/JNI binding, no UI.
 *    Core/Main composes the bridge (export at new service/root binding,
 *    hand the immutable [GitTrustBundle] to the typed native install
 *    port) in a later integration; nothing here opens a socket, requests
 *    a permission or stores a credential.
 *
 * CONTRACT (mirrored and re-checked independently on the native side in
 * shared/Sources/FloeGit/GitRemoteTrust.swift):
 *  * Deterministic derivation: certificates are deduplicated by their
 *    SHA-256 DER fingerprint and sorted by that fingerprint, so the SAME
 *    OS trust state always exports the SAME bytes, digest and bundle id.
 *  * Bounded: at most [MAX_CERTIFICATES] certificates and
 *    [MAX_BUNDLE_BYTES] bytes; at least one certificate. Violations fail
 *    closed — never a truncated or partial bundle.
 *  * Atomic + fsync + read-back: bytes are written to a temp file in the
 *    app-private trust directory, fsynced, renamed over the final
 *    location, then re-read: digest, size and PEM certificate count are
 *    recomputed from the REAL file and must match what was written or the
 *    file is deleted and the export fails.
 *  * Cancellable: [isCancelled] is checked before every certificate; a
 *    cancellation leaves no published bundle (temp removed, no record).
 *  * Storage: only under the actual Context app-private root
 *    (filesDir/floe-git-trust/platform-trust-bundle.pem — the exact leaf
 *    name the native verifier requires). No external storage, no shared
 *    locations, no symlinked destination.
 *  * Refresh semantics: each call re-derives from the LIVE platform
 *    trust. The in-memory record is the last successfully exported one;
 *    [isPlatformTrustUnchanged] compares a fresh derivation's digest
 *    against a record without touching disk. A stale file on disk is
 *    never assumed valid — the native side re-verifies it on every
 *    remote operation and revokes on any change.
 *  * Trust model: this bundle reproduces the platform's own trust
 *    decisions. It is never merged with baked-in roots, never widened
 *    (no trust-all path exists here), and an empty issuer set is a hard
 *    error rather than an "accept everything" default.
 */
object GitPlatformTrust {

    /** Must equal native GitRemoteTrust.bundleFileName (single contract). */
    const val BUNDLE_FILE_NAME = "platform-trust-bundle.pem"

    /** Trust-bundle directory under Context.getFilesDir(). */
    const val BUNDLE_DIRECTORY_NAME = "floe-git-trust"

    /** Bounds mirrored by the native verifier (GitRemoteTrust). */
    const val MAX_CERTIFICATES = 4096
    const val MAX_BUNDLE_BYTES = 4L * 1024L * 1024L

    /**
     * Immutable identity of one successfully exported, fsynced and
     * read-back-verified trust bundle. Primitive-shaped fields keep the
     * later JNI bridge trivial; the native side validates every field
     * again (form, ownership against [privateRootPath], digest, count)
     * before it will install anything.
     */
    data class GitTrustBundle(
        /** Content-derived id: "gtb-" + first 16 hex of [sha256Hex]. */
        val bundleID: String,
        /** Canonical absolute path of the final bundle file. */
        val bundleFilePath: String,
        /** Canonical app-private root the bundle lives under. */
        val privateRootPath: String,
        /** Lowercase SHA-256 hex of the exact bundle bytes. */
        val sha256Hex: String,
        /** Deduplicated platform issuers written into the bundle. */
        val certificateCount: Int,
        /** Exact byte count of the file after rename + read-back. */
        val byteCount: Int,
        /** Wall clock ms of the successful export (diagnostic only). */
        val exportedAtUnixMillis: Long,
    )

    /** Typed, content-free failure reasons (never a socket or file body). */
    enum class Reason {
        EMPTY_TRUST_STORE,
        NO_X509_TRUST_MANAGER,
        CERTIFICATE_LIMIT_EXCEEDED,
        SIZE_LIMIT_EXCEEDED,
        ENCODE_FAILED,
        WRITE_FAILED,
        READBACK_MISMATCH,
        CANCELLED,
        RETIRE_FAILED,
    }

    class GitPlatformTrustException(val reason: Reason) :
        Exception("git platform trust export failed: $reason")

    private val currentRecord = AtomicReference<GitTrustBundle?>()

    /** Last successfully exported record for this process, if any. */
    fun currentBundle(): GitTrustBundle? = currentRecord.get()

    /**
     * Reads the ACTUAL default platform trust (public
     * [TrustManagerFactory] path), derives the canonical PEM bundle and
     * publishes it atomically. Synchronous: Core/Main calls it from its
     * own worker at service/root binding time and forwards the returned
     * record to the native install port.
     *
     * @param isCancelled cooperative cancellation checked before every
     *   certificate; a cancellation removes the temp file and throws
     *   [Reason.CANCELLED] without publishing anything.
     */
    @Synchronized
    fun exportPlatformTrustBundle(
        context: Context,
        isCancelled: () -> Boolean = { false },
    ): GitTrustBundle {
        val issuers = livePlatformIssuers()

        val deduped = sortedSetOf(compareBy<X509Certificate> { it.hexFingerprint() })
        for (certificate in issuers) {
            if (isCancelled()) {
                throw GitPlatformTrustException(Reason.CANCELLED)
            }
            deduped.add(certificate)
        }
        if (deduped.isEmpty()) {
            throw GitPlatformTrustException(Reason.EMPTY_TRUST_STORE)
        }
        if (deduped.size > MAX_CERTIFICATES) {
            throw GitPlatformTrustException(Reason.CERTIFICATE_LIMIT_EXCEEDED)
        }

        val root = context.filesDir
        val directory = File(root, BUNDLE_DIRECTORY_NAME)
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw GitPlatformTrustException(Reason.WRITE_FAILED)
        }
        val finalFile = File(directory, BUNDLE_FILE_NAME)
        val tempFile = File(directory, "$BUNDLE_FILE_NAME.${System.nanoTime()}.tmp")

        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            FileOutputStream(tempFile).use { raw ->
                BufferedOutputStream(raw).use { buffered ->
                    for (certificate in deduped) {
                        if (isCancelled()) {
                            throw GitPlatformTrustException(Reason.CANCELLED)
                        }
                        val block = pemBlock(certificate)
                        if (total + block.size > MAX_BUNDLE_BYTES) {
                            throw GitPlatformTrustException(Reason.SIZE_LIMIT_EXCEEDED)
                        }
                        buffered.write(block)
                        digest.update(block)
                        total += block.size
                    }
                    buffered.flush()
                    raw.fd.sync()
                }
            }
            val expectedDigest = digest.digest()

            if (!tempFile.renameTo(finalFile) &&
                !(finalFile.delete() && tempFile.renameTo(finalFile))
            ) {
                throw GitPlatformTrustException(Reason.WRITE_FAILED)
            }

            // Read the REAL published file back; digest, size and PEM
            // certificate counts must match what we just derived. Any
            // mismatch deletes the file and fails closed — the native
            // side would reject it anyway, and a half-written bundle
            // must never be advertised as platform trust.
            val bytes = finalFile.readBytesBounded(MAX_BUNDLE_BYTES)
                ?: run {
                    finalFile.delete()
                    throw GitPlatformTrustException(Reason.SIZE_LIMIT_EXCEEDED)
                }
            val readBack = MessageDigest.getInstance("SHA-256").digest(bytes)
            val observedCertificates = countPemBlocks(bytes)
            if (bytes.size.toLong() != total ||
                !readBack.contentEquals(expectedDigest) ||
                observedCertificates != deduped.size
            ) {
                finalFile.delete()
                throw GitPlatformTrustException(Reason.READBACK_MISMATCH)
            }

            val sha256Hex = readBack.joinToString("") { "%02x".format(it) }
            val record = GitTrustBundle(
                bundleID = "gtb-" + sha256Hex.substring(0, 16),
                bundleFilePath = finalFile.canonicalPath,
                privateRootPath = root.canonicalPath,
                sha256Hex = sha256Hex,
                certificateCount = deduped.size,
                byteCount = bytes.size,
                exportedAtUnixMillis = System.currentTimeMillis(),
            )
            currentRecord.set(record)
            return record
        } catch (failure: GitPlatformTrustException) {
            throw failure
        } catch (_: java.io.IOException) {
            // Any unexpected IO failure is a write failure: fail closed.
            // The finally removes the temp file; if a rename already
            // happened the published file is removed too, so the last
            // returned record can never describe bytes that are not the
            // live platform trust. The native per-operation digest check
            // would catch the same divergence; deleting here keeps file
            // and record consistent without relying on it.
            runCatching { if (finalFile.exists()) finalFile.delete() }
            throw GitPlatformTrustException(Reason.WRITE_FAILED)
        } finally {
            runCatching { if (tempFile.exists()) tempFile.delete() }
        }
    }

    /**
     * Removes the published bundle file and the process record (used by
     * Main when the native side retires a trust identity). The native
     * binding is revoked separately through GitRemoteTrust.retire; either
     * side alone already makes remote Git fail closed.
     */
    @Synchronized
    fun clearBundle(context: Context): Boolean {
        val directory = File(context.filesDir, BUNDLE_DIRECTORY_NAME)
        val file = File(directory, BUNDLE_FILE_NAME)
        val goneOrDeleted = !file.exists() || file.delete()
        if (!goneOrDeleted) {
            throw GitPlatformTrustException(Reason.RETIRE_FAILED)
        }
        currentRecord.set(null)
        return true
    }

    /**
     * True when a FRESH derivation from the live platform trust produces
     * the same digest as [bundle] — i.e. the OS trust has not changed
     * since it was exported. In-memory only; touches no file.
     */
    fun isPlatformTrustUnchanged(bundle: GitTrustBundle): Boolean {
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        val issuers = try {
            deriveSortedIssuers()
        } catch (_: GitPlatformTrustException) {
            return false
        }
        for (certificate in issuers) {
            val block = try {
                pemBlock(certificate)
            } catch (_: GitPlatformTrustException) {
                return false
            }
            if (total + block.size > MAX_BUNDLE_BYTES) return false
            digest.update(block)
            total += block.size
        }
        val hex = digest.digest().joinToString("") { "%02x".format(it) }
        return hex == bundle.sha256Hex && total == bundle.byteCount.toLong()
    }

    // ── internals ────────────────────────────────────────────────────────

    /**
     * Default X509TrustManager accepted issuers — the CURRENT platform
     * trust as the OS exposes it through the public JSSE interface.
     * Failure to find one is a hard error (fail closed); an empty issuer
     * set is treated as a broken/unusable trust store, never as "no
     * trust needed".
     */
    private fun livePlatformIssuers(): Array<X509Certificate> {
        val trustManager = platformTrustManagerOrNull()
            ?: throw GitPlatformTrustException(Reason.NO_X509_TRUST_MANAGER)
        val issuers = trustManager.acceptedIssuers
        if (issuers.isEmpty()) {
            throw GitPlatformTrustException(Reason.EMPTY_TRUST_STORE)
        }
        return issuers
    }

    private fun deriveSortedIssuers(): List<X509Certificate> {
        val issuers = livePlatformIssuers()
        val deduped = sortedSetOf(compareBy<X509Certificate> { it.hexFingerprint() })
        deduped.addAll(issuers)
        if (deduped.size > MAX_CERTIFICATES) {
            throw GitPlatformTrustException(Reason.CERTIFICATE_LIMIT_EXCEEDED)
        }
        return deduped.toList()
    }

    private fun platformTrustManagerOrNull(): X509TrustManager? {
        return try {
            val factory = TrustManagerFactory.getInstance(
                TrustManagerFactory.getDefaultAlgorithm()
            )
            factory.init(null as java.security.KeyStore?)
            factory.trustManagers.firstOrNull { it is X509TrustManager } as? X509TrustManager
        } catch (_: Exception) {
            null
        }
    }

    private fun X509Certificate.hexFingerprint(): String = try {
        MessageDigest.getInstance("SHA-256").digest(encoded)
            .joinToString("") { "%02x".format(it) }
    } catch (_: Exception) {
        // Unencodable certificate: fail closed at the encode step below.
        ""
    }

    private fun pemBlock(certificate: X509Certificate): ByteArray = try {
        val base64 = Base64.getEncoder().encodeToString(certificate.encoded)
        val builder = StringBuilder(256 + base64.length)
        builder.append("-----BEGIN CERTIFICATE-----\n")
        var offset = 0
        while (offset < base64.length) {
            builder.append(base64, offset, minOf(offset + 64, base64.length))
            builder.append('\n')
            offset += 64
        }
        builder.append("-----END CERTIFICATE-----\n")
        builder.toString().toByteArray(java.nio.charset.StandardCharsets.US_ASCII)
    } catch (_: Exception) {
        throw GitPlatformTrustException(Reason.ENCODE_FAILED)
    }

    /** Bounded streaming read of our own published file; null if larger. */
    private fun File.readBytesBounded(limit: Long): ByteArray? {
        inputStream().use { stream ->
            val output = java.io.ByteArrayOutputStream()
            val chunk = ByteArray(64 * 1024)
            var read = stream.read(chunk)
            while (read >= 0) {
                if (output.size().toLong() + read > limit) {
                    return null
                }
                output.write(chunk, 0, read)
                read = stream.read(chunk)
            }
            return output.toByteArray()
        }
    }

    private fun countPemBlocks(bytes: ByteArray): Int {
        val marker = "-----BEGIN CERTIFICATE-----".toByteArray(java.nio.charset.StandardCharsets.US_ASCII)
        var count = 0
        var index = 0
        while (index + marker.size <= bytes.size) {
            var matched = true
            for (offset in marker.indices) {
                if (bytes[index + offset] != marker[offset]) {
                    matched = false
                    break
                }
            }
            if (matched) {
                count += 1
                index += marker.size
            } else {
                index += 1
            }
        }
        return count
    }
}
