// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.floe.android.credentials.debug.DebugCredentialStoreAccess
import com.floe.android.credentials.debug.DebugEnrollmentException
import com.floe.android.credentials.debug.DebugSealedEnrollment
import com.floe.android.credentials.debug.DebugSealedEnrollmentTestHooks
import com.floe.android.credentials.debug.EnrollmentDescriptor
import com.floe.android.credentials.debug.SealedEnrollmentProtocol
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SealedEnrollmentInstrumentedTest {
    private val context = CredentialTestSupport.context()
    private val namespace = CredentialTestSupport.namespace("qa.sealed")
    private val tracked = mutableListOf<String>()
    private val sessions = mutableListOf<String>()

    private fun newReference(prefix: String): String =
        CredentialTestSupport.reference(prefix).also { tracked += it }

    private fun begin(reference: String, ttlMillis: Long = SealedEnrollmentProtocol.DEFAULT_SESSION_TTL_MILLIS): EnrollmentDescriptor =
        DebugSealedEnrollment.begin(context, namespace, reference, ttlMillis).also {
            sessions += it.sessionID
        }

    private fun read(reference: String): ByteArray? = CredentialTestSupport.runSuspendBlocking {
        AndroidKeystoreCredentialStore(context, namespace).read(reference)
    }

    private fun import(sealed: ByteArray) = CredentialTestSupport.runSuspendBlocking {
        DebugSealedEnrollment.importSealed(context, sealed)
    }

    @After
    fun cleanUp() {
        sessions.forEach { sessionID ->
            runCatching { DebugSealedEnrollment.cancel(context, sessionID) }
        }
        val store = AndroidKeystoreCredentialStore(context, namespace)
        tracked.forEach { reference ->
            runCatching {
                CredentialTestSupport.runSuspendBlocking { store.delete(reference) }
            }
        }
        runCatching { DebugCredentialStoreAccess.deleteNamespace(context, namespace) }
    }

    @Test
    fun sealedImportSucceedsOnceAndDeletesSessionMaterial() {
        val reference = newReference("sealed-success")
        val marker = CredentialTestSupport.marker()
        val payload = marker + " 中文".toByteArray(Charsets.UTF_8)
        val descriptor = begin(reference)
        val sealed = DebugSealedEnrollment.seal(descriptor, payload)
        assertTrue(
            sealed.size in SealedEnrollmentProtocol.MIN_SEALED_BYTES..SealedEnrollmentProtocol.MAX_SEALED_BYTES,
        )

        val result = import(sealed)
        assertEquals(reference, result.reference)
        assertEquals(payload.size, result.byteCount)
        CredentialTestSupport.assertBytesEqual("sealed payload", payload, read(reference))
        assertFalse(DebugSealedEnrollment.sessionStateExists(context, descriptor.sessionID))
        assertFalse(DebugSealedEnrollment.sessionKeyExists(descriptor.sessionID))
        assertThrows(DebugEnrollmentException.SessionUnknown::class.java) { import(sealed) }
        assertFalse(CredentialTestSupport.containsBytes(context.noBackupFilesDir, marker))
        assertFalse(CredentialTestSupport.containsBytes(context.filesDir, marker))
        assertFalse(CredentialTestSupport.containsBytes(context.cacheDir, marker))
        Log.i("FloeCredentialQA", "PASS sealed-import-one-shot")
    }

    @Test
    fun tamperedEnvelopeIsRejectedAndDoesNotConsumeSession() {
        val reference = newReference("sealed-tamper")
        val payload = "tamper-payload".toByteArray(Charsets.UTF_8)
        val descriptor = begin(reference)
        val sealed = DebugSealedEnrollment.seal(descriptor, payload)
        val tampered = sealed.copyOf()
        tampered[tampered.lastIndex] = (tampered.last().toInt() xor 0x01).toByte()

        assertThrows(DebugEnrollmentException.SealedEnvelopeRejected::class.java) { import(tampered) }
        assertNull(read(reference))
        assertTrue(DebugSealedEnrollment.sessionStateExists(context, descriptor.sessionID))

        import(sealed)
        CredentialTestSupport.assertBytesEqual("payload after rejected retry", payload, read(reference))
        assertFalse(DebugSealedEnrollment.sessionStateExists(context, descriptor.sessionID))
        Log.i("FloeCredentialQA", "PASS sealed-tamper-retry")
    }

    @Test
    fun wrongReferenceIsRejectedByAadBinding() {
        val referenceA = newReference("sealed-wrong-ref-a")
        val referenceB = newReference("sealed-wrong-ref-b")
        val payload = "wrong-reference-payload".toByteArray(Charsets.UTF_8)
        val descriptor = begin(referenceA)
        val sealed = DebugSealedEnrollment.seal(descriptor.copy(reference = referenceB), payload)

        assertThrows(DebugEnrollmentException.SealedEnvelopeRejected::class.java) { import(sealed) }
        assertNull(read(referenceA))
        assertNull(read(referenceB))
        assertTrue(DebugSealedEnrollment.sessionStateExists(context, descriptor.sessionID))

        DebugSealedEnrollment.cancel(context, descriptor.sessionID)
        assertFalse(DebugSealedEnrollment.sessionStateExists(context, descriptor.sessionID))
        assertFalse(DebugSealedEnrollment.sessionKeyExists(descriptor.sessionID))
        Log.i("FloeCredentialQA", "PASS sealed-wrong-reference")
    }

    @Test
    fun wrongPackageIsRejectedByAadBinding() {
        val reference = newReference("sealed-wrong-package")
        val payload = "wrong-package-payload".toByteArray(Charsets.UTF_8)
        val descriptor = begin(reference)
        val sealed = DebugSealedEnrollment.seal(
            descriptor.copy(packageName = "com.example.not-the-floe-test-package"),
            payload,
        )

        assertThrows(DebugEnrollmentException.SealedEnvelopeRejected::class.java) { import(sealed) }
        assertNull(read(reference))
        DebugSealedEnrollment.cancel(context, descriptor.sessionID)
        Log.i("FloeCredentialQA", "PASS sealed-wrong-package")
    }

    @Test
    fun expiredSessionIsRejectedWithoutWritingCredential() {
        val reference = newReference("sealed-expired")
        val payload = "expired-payload".toByteArray(Charsets.UTF_8)
        val descriptor = begin(reference, ttlMillis = 1)
        Thread.sleep(25)
        val sealed = DebugSealedEnrollment.seal(descriptor, payload)

        assertThrows(DebugEnrollmentException.SessionExpired::class.java) { import(sealed) }
        assertNull(read(reference))
        DebugSealedEnrollment.cancel(context, descriptor.sessionID)
        assertFalse(DebugSealedEnrollment.sessionStateExists(context, descriptor.sessionID))
        assertFalse(DebugSealedEnrollment.sessionKeyExists(descriptor.sessionID))
        Log.i("FloeCredentialQA", "PASS sealed-expired")
    }

    @Test
    fun oversizePayloadIsRejectedBeforeSealing() {
        val reference = newReference("sealed-oversize")
        val descriptor = begin(reference)
        assertThrows(DebugEnrollmentException.InvalidPayload::class.java) {
            DebugSealedEnrollment.seal(
                descriptor,
                ByteArray(SealedEnrollmentProtocol.MAX_PAYLOAD_BYTES + 1),
            )
        }
        assertNull(read(reference))
        DebugSealedEnrollment.cancel(context, descriptor.sessionID)
        Log.i("FloeCredentialQA", "PASS sealed-oversize")
    }

    @Test
    fun consumptionMarkerIsDurableBeforeCredentialMutation() {
        val reference = newReference("sealed-write-failure")
        val payload = "write-failure-payload".toByteArray(Charsets.UTF_8)
        val descriptor = begin(reference)
        val sealed = DebugSealedEnrollment.seal(descriptor, payload)

        // Make the credential namespace directory path a regular file. The
        // marker store is a separate directory, so import reaches the durable
        // consumption step and then fails the credential write.
        val blocker = DebugCredentialStoreAccess.storageDirectory(context, namespace)
        blocker.parentFile?.mkdirs()
        assertTrue(blocker.createNewFile())
        try {
            assertThrows(CredentialStoreException.StorageFailure::class.java) {
                import(sealed)
            }
        } finally {
            blocker.delete()
        }

        assertNull(read(reference))
        assertThrows(DebugEnrollmentException.SessionConsumed::class.java) { import(sealed) }
        assertNull(read(reference))

        DebugSealedEnrollment.cancel(context, descriptor.sessionID)
        assertFalse(DebugSealedEnrollment.sessionStateExists(context, descriptor.sessionID))
        assertFalse(DebugSealedEnrollment.sessionKeyExists(descriptor.sessionID))
        Log.i("FloeCredentialQA", "PASS sealed-consume-before-write")
    }

    @Test
    fun cleanupFailureLeavesSessionConsumedAndBlocksReplacementOverwrite() {
        val reference = newReference("sealed-cleanup-failure")
        val firstPayload = "first-payload".toByteArray(Charsets.UTF_8)
        val replacement = "replacement-payload".toByteArray(Charsets.UTF_8)
        val descriptor = begin(reference)
        val sealed = DebugSealedEnrollment.seal(descriptor, firstPayload)

        DebugSealedEnrollmentTestHooks.failNextSessionCleanup = true
        try {
            assertThrows(DebugEnrollmentException.SessionCleanupFailed::class.java) {
                import(sealed)
            }
        } finally {
            DebugSealedEnrollmentTestHooks.failNextSessionCleanup = false
        }

        CredentialTestSupport.assertBytesEqual("first import", firstPayload, read(reference))
        assertTrue(DebugSealedEnrollment.sessionStateExists(context, descriptor.sessionID))

        val store = AndroidKeystoreCredentialStore(context, namespace)
        CredentialTestSupport.runSuspendBlocking { store.write(reference, replacement) }
        CredentialTestSupport.assertBytesEqual("replacement", replacement, read(reference))

        assertThrows(DebugEnrollmentException.SessionConsumed::class.java) { import(sealed) }
        CredentialTestSupport.assertBytesEqual(
            "replay must not overwrite the replacement",
            replacement,
            read(reference),
        )

        DebugSealedEnrollment.cancel(context, descriptor.sessionID)
        assertFalse(DebugSealedEnrollment.sessionStateExists(context, descriptor.sessionID))
        assertFalse(DebugSealedEnrollment.sessionKeyExists(descriptor.sessionID))
        Log.i("FloeCredentialQA", "PASS sealed-cleanup-replay-blocked")
    }

    @Test
    fun concurrentImportsSucceedAtMostOnceAcrossThreads() {
        val reference = newReference("sealed-concurrent")
        val payload = "concurrent-payload".toByteArray(Charsets.UTF_8)
        val descriptor = begin(reference)
        val sealed = DebugSealedEnrollment.seal(descriptor, payload)

        val start = CountDownLatch(1)
        val done = CountDownLatch(2)
        val successes = ConcurrentLinkedQueue<Unit>()
        val failures = ConcurrentLinkedQueue<Throwable>()
        val pool = Executors.newFixedThreadPool(2)
        repeat(2) {
            pool.execute {
                try {
                    start.await()
                    CredentialTestSupport.runSuspendBlocking {
                        DebugSealedEnrollment.importSealed(context, sealed)
                    }
                    successes.add(Unit)
                } catch (error: Throwable) {
                    failures.add(error)
                } finally {
                    done.countDown()
                }
            }
        }
        start.countDown()
        try {
            assertTrue("concurrent imports timed out", done.await(90, TimeUnit.SECONDS))
        } finally {
            pool.shutdown()
        }
        assertTrue(
            "concurrent import workers did not stop",
            pool.awaitTermination(30, TimeUnit.SECONDS),
        )

        assertEquals("exactly one import must succeed", 1, successes.size)
        assertEquals("exactly one import must fail", 1, failures.size)
        val failure = failures.first()
        assertTrue(
            "unexpected concurrent failure: ${failure.javaClass.simpleName}",
            failure is DebugEnrollmentException.SessionUnknown ||
                failure is DebugEnrollmentException.SessionConsumed,
        )
        CredentialTestSupport.assertBytesEqual("concurrent payload", payload, read(reference))
        assertFalse(DebugSealedEnrollment.sessionStateExists(context, descriptor.sessionID))
        assertFalse(DebugSealedEnrollment.sessionKeyExists(descriptor.sessionID))
        Log.i("FloeCredentialQA", "PASS sealed-concurrent-import")
    }
}
