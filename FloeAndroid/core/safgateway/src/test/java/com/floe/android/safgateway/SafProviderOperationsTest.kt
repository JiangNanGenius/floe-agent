// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Bounded lazy directory scans, exact capability gating, stream bounds and
 * cancellation, virtual-document honesty, and returned-URI identity.
 */
class SafProviderOperationsTest {

    private class Harness(val fake: FakeSafBackend, val gateway: SafGrantGateway, val ops: SafProviderOperations)

    private fun harness(treeFlags: Int = FakeSafBackend().dirFlags()): Harness {
        val fake = FakeSafBackend()
        val tree = fake.treeUri()
        fake.seedRoot(tree, treeFlags)
        val gateway = SafGrantGateway(fake.backend)
        fake.session[tree.uriString] = setOf(SafAccessFlag.READ, SafAccessFlag.WRITE)
        val accept = gateway.acceptPickResult(
            gateway.pickerForTree(),
            tree.uriString,
            SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.GRANT_WRITE or SafGrantFlagBits.PERSISTABLE,
        )
        assertTrue(accept is PickAcceptResult.Accepted)
        return Harness(fake, gateway, SafProviderOperations(fake.backend, gateway, SafLimits(chunkBytes = 4096)))
    }

    @Test
    fun duplicateNamesSurviveCursorPagingWithoutLossOrDuplication() {
        val h = harness()
        repeat(4) { h.fake.seedDoc(h.fake.treeUri(), "same.txt", content = byteArrayOf(it.toByte())) }
        h.fake.seedDoc(h.fake.treeUri(), "other.txt", content = byteArrayOf(9))
        h.fake.seedDoc(h.fake.treeUri(), "same.txt", content = byteArrayOf(7))
        val tree = h.fake.treeUri()
        val collected = ArrayList<SafDocument>()
        var token: String? = null
        var pages = 0
        while (pages < 10) {
            val scan = h.ops.listTreePage(tree, null, PageRequest(2, token), SafCancelToken())
            assertTrue(scan is SafOutcome.Success)
            val value = (scan as SafOutcome.Success).value
            collected += value.documents
            pages++
            token = value.nextCursorToken
            if (token == null) {
                assertFalse(value.truncatedByLimit)
                break
            }
        }
        assertEquals(6, collected.size)
        assertEquals(5, collected.count { it.displayName == "same.txt" })
        assertEquals(6, collected.map { it.ref.uri.uriString }.distinct().size) // exact identities, no dupes
    }

    @Test
    fun truncatedPageReportsHonestLimitAndContinues() {
        val h = harness()
        val tree = h.fake.treeUri()
        repeat(3) { h.fake.seedDoc(tree, "n$it", content = ByteArray(1)) }
        val first = h.ops.listTreePage(tree, null, PageRequest(2), SafCancelToken())
        val scan1 = (first as SafOutcome.Success).value
        assertEquals(2, scan1.documents.size)
        assertTrue(scan1.truncatedByLimit)
        assertNotNull(scan1.nextCursorToken)
        val second = h.ops.listTreePage(tree, null, PageRequest(2, scan1.nextCursorToken), SafCancelToken())
        val scan2 = (second as SafOutcome.Success).value
        assertEquals(1, scan2.documents.size)
        assertNull(scan2.nextCursorToken)
        assertEquals(
            scan1.documents.map { it.ref.uri.uriString } + scan2.documents.map { it.ref.uri.uriString },
            (scan1.documents + scan2.documents).map { it.ref.uri.uriString },
        )
    }

    @Test
    fun expiredCursorIsReportedAsRestartNotSilentMerge() {
        val h = harness()
        val tree = h.fake.treeUri()
        repeat(3) { h.fake.seedDoc(tree, "n$it", content = ByteArray(1)) }
        val first = (h.ops.listTreePage(tree, null, PageRequest(2), SafCancelToken()) as SafOutcome.Success).value
        assertNotNull(first.nextCursorToken)
        h.fake.expireLeases()
        val resume = (h.ops.listTreePage(tree, null, PageRequest(2, first.nextCursorToken), SafCancelToken()) as SafOutcome.Success).value
        assertNotNull(resume.note)
        assertTrue(resume.note!!.contains("expired"))
        // Restart from the beginning: caller must reconcile, no silent splice.
        assertEquals("n0", resume.documents.first().displayName)
    }

    @Test
    fun unknownSizeStaysUnknownNeverZero() {
        val h = harness()
        val tree = h.fake.treeUri()
        val doc = h.fake.seedDoc(tree, "mystery.bin", content = ByteArray(10))
        // sizeRaw null => provider unknown
        val meta = h.ops.metadata(h.fake.refOf(tree, doc), SafCancelToken())
        assertTrue(meta is SafOutcome.Success)
        assertEquals(SafSize.Unknown, (meta as SafOutcome.Success).value.size)
        doc.sizeRaw = -1L // providers also use -1
        val meta2 = h.ops.metadata(h.fake.refOf(tree, doc), SafCancelToken()) as SafOutcome.Success
        assertEquals(SafSize.Unknown, meta2.value.size)
        doc.sizeRaw = 0L
        val meta3 = h.ops.metadata(h.fake.refOf(tree, doc), SafCancelToken()) as SafOutcome.Success
        assertEquals(SafSize.Known(0), meta3.value.size) // genuine zero stays zero
    }

    @Test
    fun byteLimitStopsPassAndNeverReportsComplete() {
        val h = harness()
        val tree = h.fake.treeUri()
        val doc = h.fake.seedDoc(tree, "big.bin", content = ByteArray(10_000) { (it % 251).toByte() })
        var sunk = 0
        val outcome = h.ops.streamRead(h.fake.refOf(tree, doc), byteLimit = 5_000, typedAcceptMime = null, SafCancelToken()) { _, n -> sunk += n }
        assertTrue(outcome is SafOutcome.Failure)
        val failure = (outcome as SafOutcome.Failure).failure
        assertTrue(failure is SafFailure.SizeLimitExceeded)
        assertEquals(5_000L, (failure as SafFailure.SizeLimitExceeded).limitBytes)
        assertTrue(sunk <= 5_000)
    }

    @Test
    fun midStreamCancellationStopsAndCloses() {
        val h = harness()
        val tree = h.fake.treeUri()
        val doc = h.fake.seedDoc(tree, "slow.bin", content = ByteArray(100_000))
        val token = SafCancelToken()
        h.fake.onNthRead = { n -> if (n == 3) token.cancel() }
        val outcome = h.ops.streamRead(h.fake.refOf(tree, doc), byteLimit = null, typedAcceptMime = null, token) { _, _ -> }
        assertTrue(outcome is SafOutcome.Failure)
        assertTrue((outcome as SafOutcome.Failure).failure is SafFailure.Cancelled)
        assertEquals(1, h.fake.closedStreams) // stream was closed on the cancelled pass
    }

    @Test
    fun virtualDocumentNeedsTypedSupportAndReportsOfferedTypes() {
        val h = harness()
        val tree = h.fake.treeUri()
        val doc = h.fake.seedDoc(
            tree,
            "drawing.vec",
            mime = "application/x-vnd.vector",
            flags = SafProviderFlagBits.VIRTUAL_DOCUMENT or SafProviderFlagBits.SUPPORTS_DELETE,
            content = ByteArray(0),
        )
        doc.streamTypes += "image/png"
        val ref = h.fake.refOf(tree, doc)
        val rawAttempt = h.ops.streamRead(ref, null, null, SafCancelToken()) { _, _ -> }
        assertTrue(rawAttempt is SafOutcome.Failure)
        val unsupported = (rawAttempt as SafOutcome.Failure).failure
        assertTrue(unsupported is SafFailure.Unsupported)
        assertTrue((unsupported as SafFailure.Unsupported).hint.contains("image/png"))
        val typed = h.ops.streamRead(ref, null, "image/png", SafCancelToken()) { _, _ -> }
        // Fake has zero-length content for the typed pass; opening succeeded.
        assertEquals(1, h.fake.typedReadCount)
        assertTrue(typed is SafOutcome.Success)
    }

    @Test
    fun readOnlyAccessGatesWritesBeforeAnyProviderCall() {
        val fake = FakeSafBackend()
        val tree = fake.treeUri()
        fake.seedRoot(tree)
        val gateway = SafGrantGateway(fake.backend)
        fake.session[tree.uriString] = setOf(SafAccessFlag.READ)
        gateway.acceptPickResult(gateway.pickerForTree(), tree.uriString, SafGrantFlagBits.GRANT_READ)
        val ops = SafProviderOperations(fake.backend, gateway, SafLimits.DEFAULT)
        val before = fake.docs.size
        val created = ops.createDocument(tree, null, "text/plain", "nope.txt", SafCancelToken())
        assertTrue(created is SafOutcome.Failure)
        assertTrue((created as SafOutcome.Failure).failure is SafFailure.ReadOnly)
        assertEquals(before, fake.docs.size) // no provider mutation attempted
    }

    @Test
    fun missingWriteCapabilityBlocksDeleteWithoutProviderCall() {
        val h = harness()
        val tree = h.fake.treeUri()
        val doc = h.fake.seedDoc(tree, "locked.txt", flags = SafProviderFlagBits.SUPPORTS_RENAME, content = ByteArray(1))
        val deleted = h.ops.deleteDocument(h.fake.refOf(tree, doc), SafCancelToken())
        assertTrue(deleted is SafOutcome.Failure)
        assertTrue((deleted as SafOutcome.Failure).failure is SafFailure.Unsupported)
        assertNotNull(h.fake.docs[doc.uriString]) // untouched
    }

    @Test
    fun lyingDeleteIsDetectedAsConflict() {
        val h = harness()
        val tree = h.fake.treeUri()
        h.fake.seedDoc(tree, "ghost.txt", content = ByteArray(1))
        h.fake.deleteLies = true
        val doc = h.fake.docs.values.last()
        val deleted = h.ops.deleteDocument(h.fake.refOf(tree, doc), SafCancelToken())
        assertTrue(deleted is SafOutcome.Failure)
        assertTrue((deleted as SafOutcome.Failure).failure is SafFailure.Conflict)
    }

    @Test
    fun membershipFailureSurfacesAmbiguousIdentityNotGuessing() {
        val h = harness()
        val tree = h.fake.treeUri()
        h.fake.breakMembership = true
        val created = h.ops.createDocument(tree, null, "text/plain", "orphan.txt", SafCancelToken())
        assertTrue(created is SafOutcome.Failure)
        assertTrue((created as SafOutcome.Failure).failure is SafFailure.AmbiguousIdentity)
        // The provider DID create it; we simply refuse to bind a false identity.
        assertEquals(1, h.fake.docs.size - 1) // root + created
    }

    @Test
    fun returnedUriIsExactProviderUri() {
        val h = harness()
        val tree = h.fake.treeUri()
        val created = h.ops.createDocument(tree, null, "text/plain", "exact.txt", SafCancelToken())
        assertTrue(created is SafOutcome.Success)
        val ref = (created as SafOutcome.Success).value
        val providerDoc = h.fake.docs[ref.uri.uriString]
        assertNotNull("returned URI must be the exact provider-generated string", providerDoc)
        assertEquals(ref.uri.uriString, providerDoc!!.uriString)
        assertEquals("exact.txt", providerDoc.name)
        assertEquals(tree, ref.tree)
    }

    @Test
    fun providerOfflineMapsToTypedOutcome() {
        val h = harness()
        h.fake.offline = true
        val outcome = h.ops.listTreePage(h.fake.treeUri(), null, PageRequest(4), SafCancelToken())
        assertTrue(outcome is SafOutcome.Failure)
        assertTrue((outcome as SafOutcome.Failure).failure is SafFailure.ProviderOffline)
    }

    @Test
    fun readBoundedRejectsAbsentCapPolicy() {
        val h = harness()
        val tree = h.fake.treeUri()
        val doc = h.fake.seedDoc(tree, "x", content = ByteArray(10))
        val bad = h.ops.readBounded(h.fake.refOf(tree, doc), 0, null, SafCancelToken())
        assertTrue(bad is SafOutcome.Failure)
        assertEquals(0, h.fake.openReadCount) // validation happens before any open
    }
}
