// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine
import org.junit.Assert.assertTrue

internal object CredentialTestSupport {
    fun context(): Context = InstrumentationRegistry.getInstrumentation().targetContext

    fun uniqueSuffix(): String = UUID.randomUUID().toString()

    fun namespace(prefix: String = "qa"): String = "$prefix.${uniqueSuffix()}"

    fun reference(prefix: String = "ref"): String = "$prefix.${uniqueSuffix()}"

    fun marker(): ByteArray = "FLOE-QA-PLAINTEXT-${uniqueSuffix()}".toByteArray(Charsets.UTF_8)

    /**
     * Runs a suspend operation on the current instrumentation thread without
     * adding a coroutine test dependency. The adapter resumes on its own I/O
     * thread, so the latch blocks only the test thread.
     */
    fun <T> runSuspendBlocking(timeoutSeconds: Long = 30, block: suspend () -> T): T {
        val latch = CountDownLatch(1)
        var outcome: Result<T>? = null
        block.startCoroutine(object : Continuation<T> {
            override val context: kotlin.coroutines.CoroutineContext = EmptyCoroutineContext
            override fun resumeWith(result: Result<T>) {
                outcome = result
                latch.countDown()
            }
        })
        assertTrue("suspend operation timed out", latch.await(timeoutSeconds, TimeUnit.SECONDS))
        return outcome!!.getOrThrow()
    }

    /** Fails without printing the expected or actual secret bytes. */
    fun assertBytesEqual(label: String, expected: ByteArray, actual: ByteArray?) {
        if (actual == null) throw AssertionError("$label: missing value")
        if (!expected.contentEquals(actual)) {
            throw AssertionError("$label: content mismatch (lengths ${expected.size}/${actual.size})")
        }
    }

    /** Scans a bounded test-owned directory tree for a synthetic marker. */
    fun containsBytes(root: File, marker: ByteArray): Boolean {
        if (!root.exists()) return false
        if (root.isFile) {
            return root.length() <= MAX_SCAN_FILE_BYTES && root.readBytes().containsSubsequence(marker)
        }
        for (file in root.walkTopDown()) {
            if (!file.isFile || file.length() > MAX_SCAN_FILE_BYTES) continue
            if (file.readBytes().containsSubsequence(marker)) return true
        }
        return false
    }

    private fun ByteArray.containsSubsequence(needle: ByteArray): Boolean {
        if (needle.isEmpty()) return true
        if (needle.size > size) return false
        outer@ for (start in 0..size - needle.size) {
            for (index in needle.indices) {
                if (this[start + index] != needle[index]) continue@outer
            }
            return true
        }
        return false
    }

    private const val MAX_SCAN_FILE_BYTES = 4L * 1024 * 1024
}
