// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.floe.android.credentials.debug.DebugCredentialStoreAccess
import java.io.File
import java.nio.file.Files
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.coroutines.Continuation
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CredentialStoreInstrumentedTest {
    private val context = CredentialTestSupport.context()
    private val namespace = CredentialTestSupport.namespace("qa.cred")
    private val tracked = mutableListOf<Pair<String, String>>()

    private fun store(storeNamespace: String = namespace): AndroidKeystoreCredentialStore =
        AndroidKeystoreCredentialStore(context, storeNamespace)

    private fun track(prefix: String, trackNamespace: String = namespace): String {
        val reference = CredentialTestSupport.reference(prefix)
        tracked += trackNamespace to reference
        return reference
    }

    @After
    fun cleanUp() {
        tracked.groupBy({ it.first }, { it.second }).forEach { (trackedNamespace, references) ->
            val store = AndroidKeystoreCredentialStore(context, trackedNamespace)
            references.forEach { reference ->
                runCatching {
                    CredentialTestSupport.runSuspendBlocking { store.delete(reference) }
                }
            }
            runCatching { DebugCredentialStoreAccess.deleteNamespace(context, trackedNamespace) }
        }
    }

    @Test
    fun missingReadReturnsNullAndInvalidReferencesFailClosed() {
        val store = store()
        val reference = track("missing")
        assertNull(CredentialTestSupport.runSuspendBlocking { store.read(reference) })
        assertThrows(CredentialStoreException.InvalidReference::class.java) {
            CredentialTestSupport.runSuspendBlocking { store.read("../escape") }
        }
        assertThrows(CredentialStoreException.InvalidReference::class.java) {
            CredentialTestSupport.runSuspendBlocking { store.write("a/b", byteArrayOf(1)) }
        }
        assertNull(CredentialTestSupport.runSuspendBlocking { store.read(reference) })
    }

    @Test
    fun roundTripReplaceDeleteAndInputPreservation() {
        val store = store()
        val reference = track("roundtrip")
        val value = "中文 🧊".toByteArray(Charsets.UTF_8) +
            byteArrayOf(0, (-1).toByte(), 127, 0)
        val original = value.copyOf()

        CredentialTestSupport.runSuspendBlocking { store.write(reference, value) }
        CredentialTestSupport.assertBytesEqual("input preservation", original, value)
        CredentialTestSupport.assertBytesEqual("round trip", value, CredentialTestSupport.runSuspendBlocking { store.read(reference) })
        assertTrue(DebugCredentialStoreAccess.hasKey(namespace, reference))
        assertEquals(1, DebugCredentialStoreAccess.recordFiles(context, namespace).size)

        CredentialTestSupport.runSuspendBlocking { store.write(reference, ByteArray(0)) }
        val empty = CredentialTestSupport.runSuspendBlocking { store.read(reference) }
        assertNotNull(empty)
        assertEquals(0, empty!!.size)

        val replacement = "replacement".toByteArray(Charsets.UTF_8)
        CredentialTestSupport.runSuspendBlocking { store.write(reference, replacement) }
        CredentialTestSupport.assertBytesEqual("replacement", replacement, CredentialTestSupport.runSuspendBlocking { store.read(reference) })
        assertEquals(1, DebugCredentialStoreAccess.recordFiles(context, namespace).size)

        CredentialTestSupport.runSuspendBlocking { store.delete(reference) }
        assertNull(CredentialTestSupport.runSuspendBlocking { store.read(reference) })
        assertFalse(DebugCredentialStoreAccess.hasKey(namespace, reference))
        assertEquals(0, DebugCredentialStoreAccess.recordFiles(context, namespace).size)
        // Idempotent delete: absent record and absent key are both fine.
        CredentialTestSupport.runSuspendBlocking { store.delete(reference) }
    }

    @Test
    fun namespacesAndReferencesAreIsolated() {
        val firstNamespace = namespace
        val secondNamespace = CredentialTestSupport.namespace("qa.cred.second")
        val first = store(firstNamespace)
        val second = store(secondNamespace)
        val referenceA = track("ref-a", firstNamespace)
        val referenceB = track("ref-b", firstNamespace)
        val referenceC = track("ref-a", secondNamespace)
        val valueA = "first-a".toByteArray(Charsets.UTF_8)
        val valueB = "first-b".toByteArray(Charsets.UTF_8)
        val valueC = "second-a".toByteArray(Charsets.UTF_8)

        CredentialTestSupport.runSuspendBlocking { first.write(referenceA, valueA) }
        CredentialTestSupport.runSuspendBlocking { first.write(referenceB, valueB) }
        CredentialTestSupport.runSuspendBlocking { second.write(referenceC, valueC) }

        CredentialTestSupport.assertBytesEqual("namespace A", valueA, CredentialTestSupport.runSuspendBlocking { first.read(referenceA) })
        CredentialTestSupport.assertBytesEqual("namespace B", valueB, CredentialTestSupport.runSuspendBlocking { first.read(referenceB) })
        CredentialTestSupport.assertBytesEqual("namespace C", valueC, CredentialTestSupport.runSuspendBlocking { second.read(referenceC) })

        CredentialTestSupport.runSuspendBlocking { first.delete(referenceA) }
        assertNull(CredentialTestSupport.runSuspendBlocking { first.read(referenceA) })
        CredentialTestSupport.assertBytesEqual("namespace B", valueB, CredentialTestSupport.runSuspendBlocking { first.read(referenceB) })
        CredentialTestSupport.assertBytesEqual("namespace C", valueC, CredentialTestSupport.runSuspendBlocking { second.read(referenceC) })
        assertFalse(DebugCredentialStoreAccess.hasKey(firstNamespace, referenceA))
        assertTrue(DebugCredentialStoreAccess.hasKey(secondNamespace, referenceC))

        val recordName = DebugCredentialStoreAccess.recordFile(context, firstNamespace, referenceB).name
        assertFalse(recordName.contains(referenceB))
        assertFalse(DebugCredentialStoreAccess.storageDirectory(context, firstNamespace).name.contains(firstNamespace))
    }

    @Test
    fun tamperAndCrossReferenceSwapFailClosed() {
        val store = store()
        val referenceA = track("tamper-a")
        val referenceB = track("tamper-b")
        val valueA = "value-a-${CredentialTestSupport.uniqueSuffix()}".toByteArray(Charsets.UTF_8)
        val valueB = "value-b-${CredentialTestSupport.uniqueSuffix()}".toByteArray(Charsets.UTF_8)
        CredentialTestSupport.runSuspendBlocking { store.write(referenceA, valueA) }
        CredentialTestSupport.runSuspendBlocking { store.write(referenceB, valueB) }

        val tampered = DebugCredentialStoreAccess.recordFile(context, namespace, referenceA).readBytes()
        tampered[tampered.lastIndex] = (tampered.last().toInt() xor 0x01).toByte()
        DebugCredentialStoreAccess.overwriteRecord(context, namespace, referenceA, tampered)
        val error = assertThrows(CredentialStoreException.AuthenticationFailed::class.java) {
            CredentialTestSupport.runSuspendBlocking { store.read(referenceA) }
        }
        assertFalse(error.message.orEmpty().contains(referenceA))
        assertFalse(error.message.orEmpty().contains(valueA.toString(Charsets.UTF_8)))

        CredentialTestSupport.runSuspendBlocking { store.write(referenceA, valueA) }
        CredentialTestSupport.assertBytesEqual("reference A", valueA, CredentialTestSupport.runSuspendBlocking { store.read(referenceA) })

        val ciphertextB = DebugCredentialStoreAccess.readRecordBytes(context, namespace, referenceB)
        DebugCredentialStoreAccess.overwriteRecord(context, namespace, referenceA, ciphertextB)
        assertThrows(CredentialStoreException.AuthenticationFailed::class.java) {
            CredentialTestSupport.runSuspendBlocking { store.read(referenceA) }
        }
        CredentialTestSupport.assertBytesEqual("other reference", valueB, CredentialTestSupport.runSuspendBlocking { store.read(referenceB) })

        DebugCredentialStoreAccess.overwriteRecord(context, namespace, referenceA, ByteArray(0))
        assertThrows(CredentialStoreException.CorruptRecord::class.java) {
            CredentialTestSupport.runSuspendBlocking { store.read(referenceA) }
        }

        CredentialTestSupport.runSuspendBlocking { store.write(referenceA, valueA) }
        CredentialTestSupport.assertBytesEqual("reference A", valueA, CredentialTestSupport.runSuspendBlocking { store.read(referenceA) })
    }

    @Test
    fun missingKeyIsTypedAndRecoverablePerReference() {
        val store = store()
        val referenceA = track("key-loss-a")
        val referenceB = track("key-loss-b")
        val valueA = "key-loss-a".toByteArray(Charsets.UTF_8)
        val valueB = "key-loss-b".toByteArray(Charsets.UTF_8)
        CredentialTestSupport.runSuspendBlocking { store.write(referenceA, valueA) }
        CredentialTestSupport.runSuspendBlocking { store.write(referenceB, valueB) }

        DebugCredentialStoreAccess.deleteKey(namespace, referenceA)
        assertFalse(DebugCredentialStoreAccess.hasKey(namespace, referenceA))
        assertThrows(CredentialStoreException.KeyUnavailable::class.java) {
            CredentialTestSupport.runSuspendBlocking { store.read(referenceA) }
        }
        CredentialTestSupport.assertBytesEqual("other reference", valueB, CredentialTestSupport.runSuspendBlocking { store.read(referenceB) })

        val replacement = "replacement-after-key-loss".toByteArray(Charsets.UTF_8)
        CredentialTestSupport.runSuspendBlocking { store.write(referenceA, replacement) }
        CredentialTestSupport.assertBytesEqual("key-loss replacement", replacement, CredentialTestSupport.runSuspendBlocking { store.read(referenceA) })
        CredentialTestSupport.assertBytesEqual("other reference", valueB, CredentialTestSupport.runSuspendBlocking { store.read(referenceB) })

        CredentialTestSupport.runSuspendBlocking { store.delete(referenceA) }
        assertNull(CredentialTestSupport.runSuspendBlocking { store.read(referenceA) })
        CredentialTestSupport.assertBytesEqual("other reference", valueB, CredentialTestSupport.runSuspendBlocking { store.read(referenceB) })
        assertTrue(DebugCredentialStoreAccess.hasKey(namespace, referenceB))
    }

    @Test
    fun failedWritePreservesPreviousRecord() {
        val store = store()
        val reference = track("atomic")
        val original = "stable-value".toByteArray(Charsets.UTF_8)
        CredentialTestSupport.runSuspendBlocking { store.write(reference, original) }

        assertThrows(CredentialStoreException.InvalidValue::class.java) {
            CredentialTestSupport.runSuspendBlocking {
                store.write(reference, ByteArray(CredentialLimits.MAX_SECRET_BYTES + 1))
            }
        }
        CredentialTestSupport.assertBytesEqual("previous record", original, CredentialTestSupport.runSuspendBlocking { store.read(reference) })

        assertThrows(CredentialStoreException.InvalidReference::class.java) {
            CredentialTestSupport.runSuspendBlocking { store.write("../bad", "ignored".toByteArray()) }
        }
        CredentialTestSupport.assertBytesEqual("previous record", original, CredentialTestSupport.runSuspendBlocking { store.read(reference) })

        val directory = DebugCredentialStoreAccess.storageDirectory(context, namespace)
        val revoked = runCatching { directory.setWritable(false, false) }.getOrDefault(false)
        try {
            assumeTrue(
                "filesystem did not enforce directory write revocation",
                revoked && !directory.canWrite(),
            )
            assertThrows(CredentialStoreException.StorageFailure::class.java) {
                CredentialTestSupport.runSuspendBlocking {
                    store.write(reference, "must-not-replace".toByteArray(Charsets.UTF_8))
                }
            }
            CredentialTestSupport.assertBytesEqual("previous record", original, CredentialTestSupport.runSuspendBlocking { store.read(reference) })
            assertTrue(DebugCredentialStoreAccess.hasKey(namespace, reference))
        } finally {
            directory.setWritable(true, false)
        }
    }

    @Test
    fun concurrentInstancesAndReadsNeverExposePartialRecords() {
        val stores = List(4) { store() }
        val reference = track("concurrent")
        val payloads = List(8) { index ->
            "payload-$index-${CredentialTestSupport.uniqueSuffix()}".toByteArray(Charsets.UTF_8)
        }
        val start = CountDownLatch(1)
        val errors = ConcurrentLinkedQueue<Throwable>()
        val pool = Executors.newFixedThreadPool(10)
        try {
            repeat(8) { writer ->
                pool.execute {
                    try {
                        start.await()
                        val store = stores[writer % stores.size]
                        repeat(6) { iteration ->
                            val value = payloads[(writer + iteration) % payloads.size]
                            CredentialTestSupport.runSuspendBlocking { store.write(reference, value) }
                        }
                    } catch (error: Throwable) {
                        errors.add(error)
                    }
                }
            }
            repeat(2) { reader ->
                pool.execute {
                    try {
                        start.await()
                        val store = stores[reader % stores.size]
                        repeat(30) {
                            val value = CredentialTestSupport.runSuspendBlocking { store.read(reference) }
                            if (value != null) {
                                assertTrue(payloads.any { it.contentEquals(value) })
                            }
                        }
                    } catch (error: Throwable) {
                        errors.add(error)
                    }
                }
            }
        } finally {
            start.countDown()
            pool.shutdown()
            assertTrue("concurrent workers timed out", pool.awaitTermination(90, TimeUnit.SECONDS))
        }
        if (errors.isNotEmpty()) {
            throw AssertionError("concurrent credential operation failed", errors.first())
        }
        val finalValue = CredentialTestSupport.runSuspendBlocking { stores[0].read(reference) }
        assertNotNull(finalValue)
        assertTrue(payloads.any { it.contentEquals(finalValue!!) })
        assertEquals(1, DebugCredentialStoreAccess.recordFiles(context, namespace).size)
    }

    @Test
    fun concurrentDeleteAndWriteLeaveNullOrCompleteRecord() {
        val first = store()
        val second = store()
        val reference = track("delete-race")
        val values = List(4) { index ->
            "race-$index-${CredentialTestSupport.uniqueSuffix()}".toByteArray(Charsets.UTF_8)
        }
        val start = CountDownLatch(1)
        val errors = ConcurrentLinkedQueue<Throwable>()
        val pool = Executors.newFixedThreadPool(5)
        try {
            repeat(2) { writer ->
                pool.execute {
                    try {
                        start.await()
                        val store = if (writer == 0) first else second
                        repeat(10) { iteration ->
                            CredentialTestSupport.runSuspendBlocking {
                                store.write(reference, values[(writer + iteration) % values.size])
                            }
                        }
                    } catch (error: Throwable) {
                        errors.add(error)
                    }
                }
            }
            repeat(2) { deleter ->
                pool.execute {
                    try {
                        start.await()
                        val store = if (deleter == 0) first else second
                        repeat(10) {
                            CredentialTestSupport.runSuspendBlocking { store.delete(reference) }
                        }
                    } catch (error: Throwable) {
                        errors.add(error)
                    }
                }
            }
            pool.execute {
                try {
                    start.await()
                    repeat(30) {
                        val value = CredentialTestSupport.runSuspendBlocking { first.read(reference) }
                        if (value != null) {
                            assertTrue(values.any { it.contentEquals(value) })
                        }
                    }
                } catch (error: Throwable) {
                    errors.add(error)
                }
            }
        } finally {
            start.countDown()
            pool.shutdown()
            assertTrue("delete/write workers timed out", pool.awaitTermination(90, TimeUnit.SECONDS))
        }
        if (errors.isNotEmpty()) {
            throw AssertionError("concurrent delete/write failed", errors.first())
        }
        val finalValue = CredentialTestSupport.runSuspendBlocking { first.read(reference) }
        if (finalValue != null) {
            assertTrue(values.any { it.contentEquals(finalValue) })
        }
        assertEquals(
            if (finalValue == null) 0 else 1,
            DebugCredentialStoreAccess.recordFiles(context, namespace).size,
        )

        CredentialTestSupport.runSuspendBlocking { first.write(reference, values[0]) }
        CredentialTestSupport.assertBytesEqual("post-race write", values[0], CredentialTestSupport.runSuspendBlocking { first.read(reference) })
        CredentialTestSupport.runSuspendBlocking { first.delete(reference) }
        assertNull(CredentialTestSupport.runSuspendBlocking { first.read(reference) })
    }

    @Test
    fun onlyCiphertextIsPersistedUnderNoBackupStorage() {
        val store = store()
        val reference = track("plaintext")
        val marker = CredentialTestSupport.marker()
        val value = marker + byteArrayOf(1, 2, 3, 4)
        CredentialTestSupport.runSuspendBlocking { store.write(reference, value) }

        val record = DebugCredentialStoreAccess.recordFile(context, namespace, reference)
        assertTrue(record.isFile)
        assertFalse(CredentialTestSupport.containsBytes(record, marker))
        assertFalse(CredentialTestSupport.containsBytes(DebugCredentialStoreAccess.moduleRoot(context), marker))
        assertFalse(CredentialTestSupport.containsBytes(context.noBackupFilesDir, marker))
        assertFalse(CredentialTestSupport.containsBytes(context.filesDir, marker))
        assertFalse(CredentialTestSupport.containsBytes(context.cacheDir, marker))
        assertEquals(1, DebugCredentialStoreAccess.recordFiles(context, namespace).size)
    }

    @Test
    fun deleteRemovesKeyEvenWhenRecordFileIsAlreadyGone() {
        val store = store()
        val reference = track("orphan")
        CredentialTestSupport.runSuspendBlocking { store.write(reference, "orphan-key".toByteArray()) }
        val record = DebugCredentialStoreAccess.recordFile(context, namespace, reference)
        assertTrue(record.delete())
        assertTrue(DebugCredentialStoreAccess.hasKey(namespace, reference))

        CredentialTestSupport.runSuspendBlocking { store.delete(reference) }
        assertFalse(DebugCredentialStoreAccess.hasKey(namespace, reference))
        assertNull(CredentialTestSupport.runSuspendBlocking { store.read(reference) })
    }

    @Test
    fun writeFreezesCallerBufferBeforeDispatch() {
        val reader = store()
        val reference = track("frozen-input")
        val executor = QueueingExecutor()
        val controlled = DebugCredentialStoreAccess.storeWithControlledIo(
            context,
            namespace,
            executor,
        )
        val original = CredentialTestSupport.marker()
        val caller = original.copyOf()
        var outcome: Result<Unit>? = null
        val done = CountDownLatch(1)

        val block: suspend () -> Unit = { controlled.write(reference, caller) }
        block.startCoroutine(object : Continuation<Unit> {
            override val context: CoroutineContext = EmptyCoroutineContext

            override fun resumeWith(result: Result<Unit>) {
                outcome = result
                done.countDown()
            }
        })

        // write() must have copied the caller array synchronously before it
        // suspended at the I/O dispatch boundary.
        assertEquals("write must suspend before touching AndroidKeyStore", 1, executor.queuedCount())
        caller.fill(0x5A.toByte())
        val mutated = caller.copyOf()
        assertFalse(original.contentEquals(caller))

        executor.runNext()
        assertTrue("queued write did not complete", done.await(30, TimeUnit.SECONDS))
        outcome!!.getOrThrow()
        assertArrayEquals("store must not modify the caller array", mutated, caller)
        CredentialTestSupport.assertBytesEqual(
            "frozen input",
            original,
            CredentialTestSupport.runSuspendBlocking { reader.read(reference) },
        )
    }

    @Test
    fun readReturnsNullOnlyForActualAbsenceAndFailsClosedOnPathErrors() {
        val store = store()
        val reference = track("strict-read")
        assertNull(CredentialTestSupport.runSuspendBlocking { store.read(reference) })

        // A namespace path that is a regular file is an I/O/layout error, not
        // an absent credential.
        val brokenNamespace = CredentialTestSupport.namespace("qa.cred.broken")
        val brokenStore = AndroidKeystoreCredentialStore(context, brokenNamespace)
        val brokenDirectory = DebugCredentialStoreAccess.storageDirectory(context, brokenNamespace)
        brokenDirectory.parentFile?.mkdirs()
        assertTrue(brokenDirectory.createNewFile())
        try {
            assertThrows(CredentialStoreException.StorageFailure::class.java) {
                CredentialTestSupport.runSuspendBlocking {
                    brokenStore.read(CredentialTestSupport.reference("missing"))
                }
            }
        } finally {
            brokenDirectory.delete()
            brokenDirectory.parentFile?.delete()
        }

        CredentialTestSupport.runSuspendBlocking {
            store.write(reference, "strict-read-value".toByteArray(Charsets.UTF_8))
        }
        val record = DebugCredentialStoreAccess.recordFile(context, namespace, reference)
        assertTrue(record.delete())
        assertTrue(record.mkdirs())
        try {
            // A non-regular file at the record path must not read as "absent".
            assertThrows(CredentialStoreException.StorageFailure::class.java) {
                CredentialTestSupport.runSuspendBlocking { store.read(reference) }
            }
        } finally {
            record.delete()
        }
    }

    @Test
    fun unreadableRecordFailsClosedInsteadOfReportingAbsent() {
        val store = store()
        val reference = track("strict-permissions")
        val value = "permission-value".toByteArray(Charsets.UTF_8)
        CredentialTestSupport.runSuspendBlocking { store.write(reference, value) }
        val record = DebugCredentialStoreAccess.recordFile(context, namespace, reference)
        val revoked = runCatching { record.setReadable(false, false) }.getOrDefault(false)
        try {
            assumeTrue(
                "filesystem did not enforce file read revocation",
                revoked && !record.canRead(),
            )
            assertThrows(CredentialStoreException.StorageFailure::class.java) {
                CredentialTestSupport.runSuspendBlocking { store.read(reference) }
            }
        } finally {
            runCatching { record.setReadable(true, false) }
        }
        CredentialTestSupport.assertBytesEqual(
            "permission restored",
            value,
            CredentialTestSupport.runSuspendBlocking { store.read(reference) },
        )
    }

    @Test
    fun deleteFailsClosedAndKeepsKeyWhenRecordCannotBeRemoved() {
        val store = store()
        val reference = track("strict-delete")
        CredentialTestSupport.runSuspendBlocking {
            store.write(reference, "delete-value".toByteArray(Charsets.UTF_8))
        }
        val directory = DebugCredentialStoreAccess.storageDirectory(context, namespace)
        val record = DebugCredentialStoreAccess.recordFile(context, namespace, reference)
        val revoked = runCatching { directory.setWritable(false, false) }.getOrDefault(false)
        try {
            assumeTrue(
                "filesystem did not enforce directory write revocation",
                revoked && !directory.canWrite(),
            )
            assertThrows(CredentialStoreException.DeleteFailed::class.java) {
                CredentialTestSupport.runSuspendBlocking { store.delete(reference) }
            }
            assertTrue(record.isFile)
            assertTrue(DebugCredentialStoreAccess.hasKey(namespace, reference))
        } finally {
            runCatching { directory.setWritable(true, false) }
        }
        CredentialTestSupport.runSuspendBlocking { store.delete(reference) }
        assertNull(CredentialTestSupport.runSuspendBlocking { store.read(reference) })
        assertFalse(DebugCredentialStoreAccess.hasKey(namespace, reference))
    }

    @Test
    fun symlinkedRecordPathFailsClosed() {
        val store = store()
        val reference = track("strict-symlink")
        val directory = DebugCredentialStoreAccess.storageDirectory(context, namespace)
        directory.mkdirs()
        val link = DebugCredentialStoreAccess.recordFile(context, namespace, reference)
        val target = File(context.cacheDir, "floe-qa-symlink-${CredentialTestSupport.uniqueSuffix()}")
        target.writeBytes("symlink-target".toByteArray(Charsets.UTF_8))
        val created = runCatching {
            Files.createSymbolicLink(link.toPath(), target.toPath())
        }.isSuccess
        try {
            assumeTrue("filesystem does not permit symlinks in app storage", created)
            assertThrows(CredentialStoreException.CorruptRecord::class.java) {
                CredentialTestSupport.runSuspendBlocking { store.read(reference) }
            }
        } finally {
            link.delete()
            target.delete()
        }
    }
}

private class QueueingExecutor : Executor {
    private val queued = LinkedBlockingQueue<Runnable>()

    override fun execute(command: Runnable) {
        queued.add(command)
    }

    fun queuedCount(): Int = queued.size

    fun runNext() {
        val command = queued.poll(10, TimeUnit.SECONDS)
            ?: throw AssertionError("queued credential I/O did not appear")
        command.run()
    }
}
