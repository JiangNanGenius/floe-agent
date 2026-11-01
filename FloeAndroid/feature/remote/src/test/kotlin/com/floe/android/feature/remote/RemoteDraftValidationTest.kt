// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RemoteDraftValidationTest {
    private fun valid() = RemoteHostDraft(
        displayName = "Lab",
        address = "server.example",
        port = "22",
        user = "operator",
        authKind = RemoteHostDraft.AUTH_PASSWORD,
        hostKeyPolicy = RemoteHostDraft.POLICY_TOFU,
    )

    @Test fun acceptsValidPasswordProfile() {
        assertNull(validateRemoteHostDraft(valid()))
    }

    @Test fun rejectsBadFieldsWithStableCodes() {
        assertEquals("displayNameRequired", validateRemoteHostDraft(valid().copy(displayName = " ")))
        assertEquals("addressRequired", validateRemoteHostDraft(valid().copy(address = "")))
        assertEquals("addressInvalid", validateRemoteHostDraft(valid().copy(address = "host name")))
        assertEquals("portInvalid", validateRemoteHostDraft(valid().copy(port = "0")))
        assertEquals("portInvalid", validateRemoteHostDraft(valid().copy(port = "70000")))
        assertEquals("portInvalid", validateRemoteHostDraft(valid().copy(port = "x")))
        assertEquals("userRequired", validateRemoteHostDraft(valid().copy(user = "")))
    }

    @Test fun pinnedPolicyNeedsSha256Shape() {
        val pinned = valid().copy(
            hostKeyPolicy = RemoteHostDraft.POLICY_PINNED,
            pinnedFingerprint = "",
        )
        assertEquals("fingerprintRequired", validateRemoteHostDraft(pinned))
        assertEquals(
            "fingerprintInvalid",
            validateRemoteHostDraft(pinned.copy(pinnedFingerprint = "abc")),
        )
        assertNull(
            validateRemoteHostDraft(
                pinned.copy(
                    pinnedFingerprint = "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=",
                )
            )
        )
    }

    @Test fun fingerprintNormalizationAcceptsDisplayVariants() {
        assertEquals(
            "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0",
            normalizeFingerprint(" SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0= "),
        )
    }

    @Test fun tunnelTargetIsBoundedAndLoopbackOnlyAtTheListener() {
        assertNull(validateTunnelTarget("127.0.0.1", "5900"))
        assertNull(validateTunnelTarget("remote.internal", "443"))
        assertEquals("tunnelHostRequired", validateTunnelTarget(" ", "5900"))
        assertEquals("tunnelHostInvalid", validateTunnelTarget("bad host", "5900"))
        assertEquals("tunnelPortInvalid", validateTunnelTarget("127.0.0.1", "0"))
        assertEquals("tunnelPortInvalid", validateTunnelTarget("127.0.0.1", "x"))
    }

    @Test fun draftRoundTripsFromSummaryWithoutSecret() {
        val summary = RemoteHostSummaryUi(
            id = "00000000-0000-4000-8000-000000000001",
            displayName = "Lab",
            address = "server.example",
            port = 2222,
            user = "operator",
            auth = RemoteAuthUi("importedKey", "ed25519", "floe.ssh.test.key"),
            hostKeyPolicy = RemoteHostDraft.POLICY_TOFU,
            pinnedFingerprint = null,
            allowsLegacyAlgorithms = true,
            jumpHopCount = 2,
            vncEndpointCount = 0,
            auxiliaryConnectionCount = 0,
        )
        val draft = RemoteHostDraft.from(
            RemoteHostDetailUi(summary, listOf("jump1", "jump2"), 0, 0)
        )
        assertEquals("server.example", draft.address)
        assertEquals("2222", draft.port)
        assertEquals(RemoteHostDraft.AUTH_KEY, draft.authKind)
        assertEquals(RemoteHostDraft.KEY_ED25519, draft.keyType)
        assertEquals(true, draft.allowsLegacyAlgorithms)
    }

    @Test fun unknownRemoteStateIsNeverReportedAsStopped() {
        assertEquals("unknown", sessionStatusLabel("connected", connected = false))
        assertEquals("unknown", sessionStatusLabel("unknown", connected = true))
        assertEquals("connected", sessionStatusLabel("connected", connected = true))
        assertEquals("closed", sessionStatusLabel("closed", connected = false))
    }
}
