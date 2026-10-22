// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import org.junit.Assert.*
import org.junit.Test

/**
 * G03-R3 (job-7e9db10b801940c2): the typed CURRENT-CONNECTION proof used to
 * stamp real cleanup receipts must be strictly shaped, must never tolerate
 * a non-distinct UID, and the RuntimeWire v1 allowlist gains ONLY the exact
 * additive internal controls.
 */
class RuntimePeerProofTest {
    @Test fun wireV1PreservesLegacyAndThreeInternalControls() {
        assertEquals(1, RuntimeWire.VERSION)
        assertEquals("runtimeWorkspaceCopies.clear", RuntimeWire.CLEANUP)
        assertTrue(RuntimeWire.operations.contains(RuntimeWire.CLEANUP))
        // every pre-existing operation remains admitted unchanged
        for (operation in setOf("status", "request.status", "install.start", "install.cancel",
                "install.status", "environment.list", "shell.start", "shell.poll", "shell.input",
                "shell.resize", "shell.cancel")) {
            assertTrue("missing $operation", RuntimeWire.operations.contains(operation))
        }
        // Exactly the reviewed internal controls; no model tool or extra operation.
        assertEquals(setOf("status", "request.status", "install.start", "install.cancel",
            "install.status", "environment.list", "shell.start", "shell.poll", "shell.input",
            "shell.resize", "shell.cancel", RuntimeWire.CLEANUP, RuntimeWire.PREFLIGHT,
            RuntimeWire.PREFLIGHT_CANCEL), RuntimeWire.operations)
        assertEquals(14, RuntimeWire.operations.size)
    }

    @Test fun asciiTokensRejectSpacesControlCharsAndOversize() {
        assertTrue(RuntimePeerProof.asciiToken("runtime-binder:u10123:x1a2b3:g1", 128))
        assertFalse(RuntimePeerProof.asciiToken("", 128))
        assertFalse("spaces break the receipt token grammar", RuntimePeerProof.asciiToken("a b", 8))
        assertFalse(RuntimePeerProof.asciiToken("a\u0000b", 8))
        assertFalse(RuntimePeerProof.asciiToken("x".repeat(129), 128))
    }

    @Test fun hex64DigestShapeIsExact() {
        assertTrue(RuntimePeerProof.isHex64("ab".repeat(32)))
        assertFalse(RuntimePeerProof.isHex64("AB".repeat(32))) // lower-case only
        assertFalse(RuntimePeerProof.isHex64("ab".repeat(31)))
        assertFalse(RuntimePeerProof.isHex64("g".repeat(64)))
    }

    @Test fun versionTokenAlwaysFitsTheReceiptGrammar() {
        assertEquals("1.2.0/42", RuntimePeerProof.versionToken("1.2.0", 42))
        // a versionName that is NOT a bounded ASCII token degrades to the
        // honest versionCode string; it is never whitespace or oversize
        val spaced = RuntimePeerProof.versionToken("1.2 beta", 7)
        assertEquals("7", spaced)
        assertTrue(RuntimePeerProof.asciiToken(RuntimePeerProof.versionToken(null, 9), 96))
        val huge = RuntimePeerProof.versionToken("x".repeat(200), 5)
        assertEquals("5", huge)
        assertTrue(RuntimePeerProof.asciiToken(huge, 96))
    }

    @Test fun binderIdentityTracksEndpointAndGeneration() {
        val a = RuntimePeerProof.binderIdentityToken(10123, 0x1A2B3C4D.toInt(), 1)
        val b = RuntimePeerProof.binderIdentityToken(10123, 0x1A2B3C4D.toInt(), 2)
        val c = RuntimePeerProof.binderIdentityToken(10123, 0x0BADF00D.toInt(), 1)
        assertNotEquals(a, b) // reconnect generation is visible
        assertNotEquals(a, c) // endpoint object identity is visible
        assertTrue(RuntimePeerProof.asciiToken(a, 128))
    }

    @Test fun proofRefusesSameUidAndMalformedIdentity() {
        val good = RuntimePeerProof(
            peerPackage = "com.floe.agent.runtime",
            peerUid = 10123,
            packageVersion = "0.3/42",
            certificateDigest = "ab".repeat(32),
            binderIdentity = RuntimePeerProof.binderIdentityToken(10123, 0x10, 1),
        )
        assertTrue(good.wellFormed(10001))
        assertFalse("a same-UID claim can never prove runtime-side IO", good.wellFormed(10123))
        assertFalse(good.copy(peerUid = -1).wellFormed(10001))
        assertFalse(good.copy(certificateDigest = "nothex").wellFormed(10001))
        assertFalse(good.copy(packageVersion = "with space").wellFormed(10001))
        assertFalse(good.copy(binderIdentity = "").wellFormed(10001))
    }
}
