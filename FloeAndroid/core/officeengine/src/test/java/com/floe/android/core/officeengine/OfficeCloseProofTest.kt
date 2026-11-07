// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import org.junit.Assert.*
import org.junit.Test

class OfficeCloseProofTest {
    private val sha = "a".repeat(64)
    private fun receipt(dirty: Int = 0, discarded: Int = 0, reason: String = "user-back") =
        OfficeCloseProof.validate("mount", 5, 9, reason, dirty, discarded, sha, 17)

    @Test fun identicalBytesWithoutWriterDeathAreNotProof() {
        val sealed = receipt()!!
        assertFalse(OfficeCloseProof.matchesClosedFile(sealed, false, sha, 17))
        assertTrue(OfficeCloseProof.matchesClosedFile(sealed, true, sha, 17))
    }

    @Test fun closeProofNeverAcceptsInternalTeardownOrMalformedFacts() {
        assertNull(receipt(reason = "presentation replaced"))
        assertNull(receipt(dirty = -1))
        assertNull(receipt(discarded = 2))
        assertNull(OfficeCloseProof.validate("mount", 0, 9, "user-back", 0, 0, sha, 17))
        assertNull(OfficeCloseProof.validate("mount", 5, 9, "user-back", 0, 0, "hash", 17))
        assertNull(OfficeCloseProof.validate("mount", 5, 9, "user-back", 0, 0, sha, 0))
    }

    @Test fun unknownDestinationOrNativeDirtyStatePreservesUnsavedBytes() {
        val sealed = receipt()!!
        assertFalse(OfficeCloseProof.hasUnsavedBytes(sealed, sha, 17))
        assertTrue(OfficeCloseProof.hasUnsavedBytes(sealed, "b".repeat(64), 17))
        assertTrue(OfficeCloseProof.hasUnsavedBytes(sealed, null, 17))
        assertTrue(OfficeCloseProof.hasUnsavedBytes(receipt(dirty = 1)!!, sha, 17))
        assertTrue(receipt(dirty = 1, discarded = 1)!!.discarded)
    }
}
