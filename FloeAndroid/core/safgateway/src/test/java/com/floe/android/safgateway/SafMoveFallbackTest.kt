// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.MessageDigest

/**
 * Move ladder honesty: native move, verified copy-then-delete (never
 * delete-on-start), explicit caller authorization for the source delete step,
 * and the bounded relay path when the provider supports neither move nor copy.
 */
class SafMoveFallbackTest {

    private class Ctx(
        val fake: FakeSafBackend,
        val sourceTree: SafUriRef,
        val destTree: SafUriRef,
        val ops: SafProviderOperations,
    )

    private fun ctx(): Ctx {
        val fake = FakeSafBackend()
        val sourceTree = fake.treeUri("src")
        val destTree = fake.treeUri("dst")
        fake.seedRoot(sourceTree)
        fake.seedRoot(destTree)
        val gateway = SafGrantGateway(fake.backend)
        for (tree in listOf(sourceTree, destTree)) {
            fake.session[tree.uriString] = setOf(SafAccessFlag.READ, SafAccessFlag.WRITE)
            val accept = gateway.acceptPickResult(
                gateway.pickerForTree(),
                tree.uriString,
                SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.GRANT_WRITE or SafGrantFlagBits.PERSISTABLE,
            )
            assertTrue(accept is PickAcceptResult.Accepted)
        }
        return Ctx(fake, sourceTree, destTree, SafProviderOperations(fake.backend, gateway, SafLimits(chunkBytes = 4096)))
    }

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    @Test
    fun nativeMoveWhenProviderSupportsIt() {
        val c = ctx()
        val doc = c.fake.seedDoc(c.sourceTree, "file.txt", content = "data".toByteArray())
        val result = c.ops.moveWithVerifiedCopyFallback(
            c.fake.refOf(c.sourceTree, doc), c.destTree, null, null,
            allowSourceDelete = true, byteLimit = 1L shl 20, cancel = SafCancelToken(),
        )
        assertTrue(result is SafOutcome.Success)
        val move = (result as SafOutcome.Success).value
        assertEquals(MoveMode.NATIVE_MOVE, move.mode)
        assertNotNull(move.finalRef)
        assertEquals(c.destTree, move.finalRef!!.tree)
        // Native move: the doc physically reparented; NO delete step ran.
        assertFalse(move.sourceDeleted)
        assertEquals("data", String(c.fake.docs[doc.uriString]!!.content))
        assertNull(move.copy)
    }

    @Test
    fun verifiedCopyThenExplicitSourceDelete() {
        val c = ctx()
        // No MOVE flag -> native move fails; COPY + DELETE present.
        val doc = c.fake.seedDoc(
            c.sourceTree,
            "file.txt",
            content = "keepme".toByteArray(),
            flags = SafProviderFlagBits.SUPPORTS_WRITE or SafProviderFlagBits.SUPPORTS_COPY or SafProviderFlagBits.SUPPORTS_DELETE,
        )
        val result = c.ops.moveWithVerifiedCopyFallback(
            c.fake.refOf(c.sourceTree, doc), c.destTree, null, null,
            allowSourceDelete = true, byteLimit = 1L shl 20, cancel = SafCancelToken(),
        ) as SafOutcome.Success
        val move = result.value
        assertEquals(MoveMode.VERIFIED_COPY_PLUS_DELETE, move.mode)
        assertTrue(move.copy!!.byteIdentical)
        assertEquals(sha("keepme".toByteArray()), move.copy!!.sourceSha256)
        assertNull(c.fake.docs[doc.uriString]) // source deleted only AFTER verification
        assertEquals("keepme", String(c.fake.docs[move.copy!!.destination.uri.uriString]!!.content))
    }

    @Test
    fun sourceDeleteNeverHappensWithoutCallerAuthorization() {
        val c = ctx()
        val doc = c.fake.seedDoc(
            c.sourceTree,
            "file.txt",
            content = "both".toByteArray(),
            flags = SafProviderFlagBits.SUPPORTS_WRITE or SafProviderFlagBits.SUPPORTS_COPY or SafProviderFlagBits.SUPPORTS_DELETE,
        )
        val move = (c.ops.moveWithVerifiedCopyFallback(
            c.fake.refOf(c.sourceTree, doc), c.destTree, null, null,
            allowSourceDelete = false, byteLimit = 1L shl 20, cancel = SafCancelToken(),
        ) as SafOutcome.Success).value
        assertEquals(MoveMode.VERIFIED_COPY_SOURCE_RETAINED, move.mode)
        assertNotNull(c.fake.docs[doc.uriString]) // source still present
        assertEquals("both", String(c.fake.docs[doc.uriString]!!.content))
        assertEquals("both", String(c.fake.docs[move.copy!!.destination.uri.uriString]!!.content))
    }

    @Test
    fun relayPathWhenProviderSupportsNeitherMoveNorCopy() {
        val c = ctx()
        val doc = c.fake.seedDoc(
            c.sourceTree,
            "orphan.txt",
            content = ByteArray(10_000) { (it % 7).toByte() },
            flags = SafProviderFlagBits.SUPPORTS_WRITE or SafProviderFlagBits.SUPPORTS_DELETE, // no MOVE, no COPY
        )
        val scratch = FakeSafBackend.stagingDir("relay")
        val move = (c.ops.moveWithVerifiedCopyFallback(
            c.fake.refOf(c.sourceTree, doc), c.destTree, null, scratch,
            allowSourceDelete = true, byteLimit = 1L shl 20, cancel = SafCancelToken(),
        ) as SafOutcome.Success).value
        assertEquals(MoveMode.VERIFIED_COPY_PLUS_DELETE, move.mode)
        assertTrue(move.copy!!.byteIdentical)
        assertEquals(sha(doc.snapshot()), move.copy!!.destinationSha256)
        assertNull(c.fake.docs[doc.uriString])
    }

    @Test
    fun destinationHashMismatchKeepsSourceAndRefusesDelete() {
        val c = ctx()
        val doc = c.fake.seedDoc(
            c.sourceTree,
            "fragile.txt",
            content = "source".toByteArray(),
            flags = SafProviderFlagBits.SUPPORTS_WRITE or SafProviderFlagBits.SUPPORTS_COPY or SafProviderFlagBits.SUPPORTS_DELETE,
        )
        // Corrupt every copy destination right after the provider copy lands.
        c.fake.corruptNextCopies = true
        val result = c.ops.moveWithVerifiedCopyFallback(
            c.fake.refOf(c.sourceTree, doc), c.destTree, null, null,
            allowSourceDelete = true, byteLimit = 1L shl 20, cancel = SafCancelToken(),
        )
        assertTrue(result is SafOutcome.Failure)
        val failure = (result as SafOutcome.Failure).failure
        assertTrue(failure is SafFailure.Conflict)
        assertNotNull("source must survive a failed verification", c.fake.docs[doc.uriString])
        assertEquals("source", String(c.fake.docs[doc.uriString]!!.content))
    }

    @Test
    fun grantLossPropagatesTypedWithoutFallback() {
        val c = ctx()
        val doc = c.fake.seedDoc(c.sourceTree, "file.txt", content = "x".toByteArray())
        c.fake.session.clear()
        c.fake.persisted.clear()
        val result = c.ops.moveWithVerifiedCopyFallback(
            c.fake.refOf(c.sourceTree, doc), c.destTree, null, null,
            allowSourceDelete = true, byteLimit = 1L shl 20, cancel = SafCancelToken(),
        )
        assertTrue(result is SafOutcome.Failure)
        val failure = (result as SafOutcome.Failure).failure
        assertTrue("expected Revoked for a previously persisted grant", failure is SafFailure.Revoked)
    }

    @Test
    fun nativeMoveRefusesWithoutExplicitSourceParent() {
        val c = ctx()
        val doc = c.fake.seedDoc(c.sourceTree, "file.txt", content = "data".toByteArray())
        // Defect 2 (2026-10-24): moveDocument's real contract needs the SOURCE parent URI.
        // A ref without resolvable parent identity must be refused, never guessed.
        val orphan = doc.let { SafDocumentRef(c.sourceTree, it.documentIdFromUri(), null, SafUriRef(it.uriString)) }
        val result = c.ops.moveDocument(orphan, c.destTree, null, SafCancelToken())
        assertTrue(result is SafOutcome.Failure)
        assertTrue((result as SafOutcome.Failure).failure is SafFailure.Unsupported)
    }

    @Test
    fun fallbackDeleteRequiresFreshSourceRehashMatch() {
        val c = ctx()
        val doc = c.fake.seedDoc(
            c.sourceTree,
            "file.txt",
            content = "keepme".toByteArray(),
            flags = SafProviderFlagBits.SUPPORTS_WRITE or SafProviderFlagBits.SUPPORTS_COPY or SafProviderFlagBits.SUPPORTS_DELETE,
        )
        // Copy verification reads: #1 source hash, #2 destination hash.
        // Pre-delete recheck is read #3: mutate the source there (defect 5 fix).
        c.fake.mutateOnOpenReadNumber = 3 to "third-writer-changed-it".toByteArray()
        val move = (c.ops.moveWithVerifiedCopyFallback(
            c.fake.refOf(c.sourceTree, doc), c.destTree, null, null,
            allowSourceDelete = true, byteLimit = 1L shl 20, cancel = SafCancelToken(),
        ) as SafOutcome.Success).value
        assertEquals(MoveMode.VERIFIED_COPY_SOURCE_RETAINED, move.mode)
        assertFalse(move.sourceDeleted)
        assertTrue(move.note.contains("source changed"))
        // BOTH copies remain, exactly as reported.
        assertEquals("third-writer-changed-it", String(c.fake.docs[doc.uriString]!!.content))
        assertEquals("keepme", String(c.fake.docs[move.copy!!.destination.uri.uriString]!!.content))
    }

    @Test
    fun fallbackDeleteRefusesWhenSourceUnreadableAtRecheck() {
        val c = ctx()
        val doc = c.fake.seedDoc(
            c.sourceTree,
            "file.txt",
            content = "keepme".toByteArray(),
            flags = SafProviderFlagBits.SUPPORTS_WRITE or SafProviderFlagBits.SUPPORTS_COPY or SafProviderFlagBits.SUPPORTS_DELETE,
        )
        c.fake.throwOnOpenReadNumber = 3 // pre-delete recheck pass fails
        val move = (c.ops.moveWithVerifiedCopyFallback(
            c.fake.refOf(c.sourceTree, doc), c.destTree, null, null,
            allowSourceDelete = true, byteLimit = 1L shl 20, cancel = SafCancelToken(),
        ) as SafOutcome.Success).value
        assertEquals(MoveMode.VERIFIED_COPY_SOURCE_RETAINED, move.mode)
        assertFalse(move.sourceDeleted)
        assertTrue(move.note.contains("unreadable"))
        assertNotNull(c.fake.docs[doc.uriString])
        assertNotNull(c.fake.docs[move.copy!!.destination.uri.uriString])
    }
}
