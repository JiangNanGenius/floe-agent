// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import android.content.Context
import android.os.IBinder
import android.content.pm.PackageManager
import java.security.MessageDigest

/**
 * G03-R3 typed CURRENT-CONNECTION proof for one verified runtime peer, for
 * the trusted host (and only the trusted host) to stamp real execution
 * receipts. This is NOT a new authentication path: every field is observed
 * from the SAME authorities the connection already enforces —
 * `RuntimePeerVerifier.verifyPeer` (exact dedicated peer UID + matching
 * signature + allowlisted package pair) and the live `PackageManager`
 * installed-package facts — plus the identity of the Binder endpoint object
 * of the CURRENT connection generation. No model or IPC payload can mint a
 * proof; nothing here relaxes any UID/signature check.
 *
 * Cross-UID honesty rules baked into this type:
 *  * `peerUid` must be a real distinct UID (never the local process UID);
 *  * `certificateDigest` is the actual installed peer signing-chain SHA-256
 *    (lower-case hex 64), measured, never supplied by the peer's body;
 *  * `packageVersion` is the actual installed version token (bounded ASCII,
 *    no spaces — the receipt grammar's token class);
 *  * `binderIdentity` binds the proof to this connection's endpoint object
 *    and generation: after a disconnect/reconnect (or process restart) the
 *    token changes, so a receipt built from an old generation cannot be
 *    mistaken for the current one.
 */
data class RuntimePeerProof(
    val peerPackage: String,
    val peerUid: Int,
    val packageVersion: String,
    val certificateDigest: String,
    val binderIdentity: String,
) {
    /** True only when EVERY field is a real, well-formed identity token. */
    fun wellFormed(ownUid: Int): Boolean =
        peerUid != ownUid && peerUid >= 0 &&
            RuntimePeerProof.isHex64(certificateDigest) &&
            RuntimePeerProof.asciiToken(packageVersion, 96) &&
            RuntimePeerProof.asciiToken(binderIdentity, 128)

    companion object {
        private val HEX64 = Regex("^[0-9a-f]{64}$")

        fun isHex64(value: String): Boolean = HEX64.matches(value)

        /** Receipt-grammar ASCII token: printable non-space, bounded. */
        fun asciiToken(text: String, maximumBytes: Int): Boolean {
            if (text.isEmpty() || text.toByteArray(Charsets.UTF_8).size > maximumBytes) return false
            return text.all { it.code in 0x21..0x7e }
        }

        /** Lower-case hex SHA-256 over the concatenated chain bytes. */
        fun digestHex(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it) }

        /**
         * Deterministic installed-version token: `versionName/versionCode`
         * when the name is already a bounded ASCII token, else the bare
         * versionCode. Never whitespace, never invented.
         */
        fun versionToken(versionName: String?, versionCode: Long): String {
            val combined = versionName?.trim()?.takeIf { it.isNotEmpty() }?.let { "$it/$versionCode" }
            return if (combined != null && combined.length <= 96 && asciiToken(combined, 96)) combined
            else versionCode.toString()
        }

        /** Endpoint-object + generation token; pure so it is unit-testable. */
        fun binderIdentityToken(peerUid: Int, endpointHashCode: Int, generation: Long): String =
            "runtime-binder:u$peerUid:x${endpointHashCode.toUInt().toString(16)}:g$generation".take(128)

        /**
         * Measure the CURRENT peer through the existing authorities. Callers
         * must have an OPEN, verifier-admitted connection; this re-runs
         * `verifyPeer` (fail closed on drift) and reads the actual installed
         * package facts. Returns null (never a placeholder) when anything is
         * unobservable or the peer would not be distinct from this UID.
         */
        fun measure(context: Context, endpoint: IBinder, generation: Long): RuntimePeerProof? {
            if (generation <= 0L) return null
            val own = context.applicationContext.packageName
            return try {
                val packages = runCatching { RuntimePackages.forCore(own) }
                    .getOrElse { RuntimePackages.forRuntime(own) }
                val peerPackage = if (own == packages.core) packages.runtime else packages.core
                val peerUid = RuntimePeerVerifier(context.applicationContext).verifyPeer(peerPackage)
                if (peerUid == android.os.Process.myUid() || peerUid < 0) return null
                val info = context.applicationContext.packageManager
                    .getPackageInfo(peerPackage, PackageManager.GET_SIGNING_CERTIFICATES)
                val signers = info.signingInfo?.apkContentsSigners?.toList().orEmpty()
                if (signers.isEmpty()) return null
                val chain = ByteArray(signers.sumOf { it.toByteArray().size })
                var offset = 0
                for (signer in signers) {
                    val bytes = signer.toByteArray()
                    System.arraycopy(bytes, 0, chain, offset, bytes.size)
                    offset += bytes.size
                }
                val versionCode = if (android.os.Build.VERSION.SDK_INT >= 28)
                    info.longVersionCode else info.versionCode.toLong()
                RuntimePeerProof(
                    peerPackage = peerPackage,
                    peerUid = peerUid,
                    packageVersion = versionToken(info.versionName, versionCode),
                    certificateDigest = digestHex(chain),
                    binderIdentity = binderIdentityToken(peerUid, System.identityHashCode(endpoint), generation),
                )
            } catch (_: PackageManager.NameNotFoundException) { null }
              catch (_: SecurityException) { null }
              catch (_: Exception) { null }
        }
    }
}
