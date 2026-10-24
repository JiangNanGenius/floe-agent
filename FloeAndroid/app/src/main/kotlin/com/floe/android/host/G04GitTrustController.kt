// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.Context
import com.floe.android.bridge.GitTrustNative
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject

/** One immutable platform trust export per native Root. Export/install and
 * retirement are serialized; there is no fallback CA bundle or permissive
 * verifier. Changed OS trust revokes this generation until a fresh Root,
 * rather than replacing a file under an in-flight native Git operation. */
internal class G04GitTrustController(context: Context, private val currentEpoch: () -> Long?) {
    private val context = context.applicationContext
    private val lock = Mutex()
    @Volatile private var epoch: Long? = null
    fun boundEpoch(): Long? = epoch
    private var bundle: GitPlatformTrust.GitTrustBundle? = null
    private var revoked = false

    suspend fun ensureBound(expectedEpoch: Long): Boolean = withContext(Dispatchers.IO) {
        lock.withLock {
            if (expectedEpoch <= 0 || currentEpoch() != expectedEpoch) return@withLock false
            if (epoch == expectedEpoch) {
                val record = bundle ?: return@withLock false
                if (revoked) return@withLock false
                if (GitPlatformTrust.isPlatformTrustUnchanged(record)) return@withLock true
                try { GitTrustNative.retire(expectedEpoch) } catch (_: LinkageError) { }
                revoked = true
                return@withLock false
            }
            // An old export is kept until its Root's confirmed Stopped event
            // retires it. A newer generation cannot overwrite that live file.
            epoch?.let { old ->
                // A currently accepted NEW native Root proves the old
                // native owner drained, even if StateFlow conflated its
                // intermediate Stopped observation.
                val retired = try { GitTrustNative.retire(old) == 0 } catch (_: LinkageError) { false }
                if (!retired || !runCatching { GitPlatformTrust.clearBundle(context) }.getOrDefault(false)) return@withLock false
                epoch = null; bundle = null; revoked = false
            }
            val record = try {
                GitPlatformTrust.exportPlatformTrustBundle(context) { currentEpoch() != expectedEpoch }
            } catch (_: GitPlatformTrust.GitPlatformTrustException) { return@withLock false }
            val bytes = JSONObject().apply {
                put("bundleID", record.bundleID); put("bundleFilePath", record.bundleFilePath)
                put("privateRootPath", record.privateRootPath); put("sha256Hex", record.sha256Hex)
                put("certificateCount", record.certificateCount); put("byteCount", record.byteCount)
                put("exportedAtUnixMillis", record.exportedAtUnixMillis)
            }.toString().toByteArray(Charsets.UTF_8)
            val accepted = try { currentEpoch() == expectedEpoch && GitTrustNative.install(expectedEpoch, bytes) == 0 }
                catch (_: LinkageError) { false }
            if (!accepted || currentEpoch() != expectedEpoch) {
                try { GitTrustNative.retire(expectedEpoch) } catch (_: LinkageError) { }
                runCatching { GitPlatformTrust.clearBundle(context) }
                return@withLock false
            }
            epoch = expectedEpoch; bundle = record; revoked = false
            true
        }
    }

    /** Called after the ORIGINAL native Root has drained and stopped. */
    suspend fun retireStopped(expectedEpoch: Long): Boolean = withContext(Dispatchers.IO) {
        lock.withLock {
            if (epoch != expectedEpoch) return@withLock epoch == null
            val retired = try { GitTrustNative.retire(expectedEpoch) == 0 } catch (_: LinkageError) { false }
            if (!retired) return@withLock false
            if (runCatching { GitPlatformTrust.clearBundle(context) }.getOrDefault(false)) {
                epoch = null; bundle = null; revoked = false; true
            } else false
        }
    }
}
