// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.security.MessageDigest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Device gate for the packaged security corpus. The APK asset must be the
 * byte-exact upstream resource; the runtime seam must load it through the
 * SAME Codable shape and regex compile path as the iOS bundle loader, block
 * a known destructive string (classification only — nothing is ever executed)
 * and still leave a benign command clear. Any tampered, truncated, empty or
 * re-encoded corpus must be REJECTED (handle 0); the production fallback is
 * the gate's own match-everything failClosed, never an empty pattern set.
 */
@RunWith(AndroidJUnit4::class)
class SecurityCorpusInstrumentedTest {
    private companion object {
        const val PINNED_SHA256 =
            "b20667f2d9713961231327c931188cc74474cdbd294593c6071c804edf0c038b"
        const val TAG = "FloeQualification"
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }

    private fun packagedCorpus(): ByteArray =
        InstrumentationRegistry.getInstrumentation().context.assets
            .open("security/catastrophic-patterns.json").use { it.readBytes() }

    @Test
    fun packagedCorpusIsByteExactAndLoadsVerifiedGate() {
        val corpus = packagedCorpus()
        assertEquals(PINNED_SHA256, sha256(corpus))
        val handle = QualificationNative.nativeGateCreateFromCorpus(corpus)
        assertNotEquals(0L, handle)
        try {
            val stopped = JSONObject(
                QualificationNative.nativeGateEvaluate(handle, "rm -rf / --no-preserve-root"))
            Log.i(TAG, "destructive-verdict: $stopped")
            assertTrue(stopped.getBoolean("ok"))
            assertTrue("known destructive string must be stopped", stopped.getBoolean("stopped"))
            assertEquals("rm-rf-root", stopped.getString("matchedPatternID"))
            val clear = JSONObject(
                QualificationNative.nativeGateEvaluate(handle, "ls -la"))
            Log.i(TAG, "benign-verdict: $clear")
            assertTrue(clear.getBoolean("ok"))
            assertFalse("corpus must stay precise, not match-everything", clear.getBoolean("stopped"))
            assertTrue(clear.isNull("matchedPatternID"))
        } finally {
            QualificationNative.nativeGateRelease(handle)
        }
    }

    @Test
    fun tamperedTruncatedOrReencodedCorpusIsRejectedNeverEmpty() {
        val corpus = packagedCorpus()
        assertEquals(0L, QualificationNative.nativeGateCreateFromCorpus(ByteArray(0)))
        assertEquals(0L, QualificationNative.nativeGateCreateFromCorpus(
            corpus.copyOfRange(0, corpus.size - 16)))
        val tampered = corpus.copyOf()
        tampered[corpus.size - 2] = (tampered[corpus.size - 2].toInt() xor 0x41).toByte()
        assertEquals(0L, QualificationNative.nativeGateCreateFromCorpus(tampered))
        // Byte-different but structurally valid JSON: the hash pin must reject
        // it, so untrusted content can never replace the trusted corpus.
        val reencoded = JSONObject(String(corpus, Charsets.UTF_8)).toString()
            .toByteArray(Charsets.UTF_8)
        assertNotEquals(PINNED_SHA256, sha256(reencoded))
        assertEquals(0L, QualificationNative.nativeGateCreateFromCorpus(reencoded))
    }

    @Test
    fun failClosedGateStopsEvenBenignCommands() {
        val handle = QualificationNative.nativeGateCreateFailClosed("qualification-test-fallback")
        assertNotEquals(0L, handle)
        try {
            val verdict = JSONObject(QualificationNative.nativeGateEvaluate(handle, "ls -la"))
            Log.i(TAG, "failClosed-verdict: $verdict")
            assertTrue(verdict.getBoolean("ok"))
            assertTrue(verdict.getBoolean("stopped"))
            assertEquals("gate-unavailable", verdict.getString("matchedPatternID"))
        } finally {
            QualificationNative.nativeGateRelease(handle)
        }
    }

    @Test
    fun invalidHandleEvaluationsFailClosed() {
        val verdict = JSONObject(QualificationNative.nativeGateEvaluate(0L, "ls -la"))
        assertFalse(verdict.getBoolean("ok"))
        assertEquals("invalidHandle", verdict.getString("error"))
    }
}
