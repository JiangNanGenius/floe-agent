// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials.hostinterop

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.floe.android.credentials.CredentialTestSupport
import com.floe.android.credentials.debug.DebugSealedEnrollment
import com.floe.android.credentials.debug.SealedEnrollmentProtocol
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Phase 1 of the host -> Android interop proof. Run alone with
 * `-e floeHostInteropPhase 1`, then let the instrumentation process end. The
 * session and its AndroidKeyStore private key intentionally survive for the
 * host sealer and [HostInteropPhase2Test].
 */
@RunWith(AndroidJUnit4::class)
class HostInteropPhase1Test {
    @Test
    fun prepareDescriptorAndRetainSession() {
        assumeTrue(
            "run with -e ${HostInteropTestSupport.PHASE_ARGUMENT} 1",
            HostInteropTestSupport.phase() == "1",
        )
        val context = CredentialTestSupport.context()
        HostInteropTestSupport.cleanup(context)
        val descriptor = DebugSealedEnrollment.begin(
            context,
            HostInteropTestSupport.NAMESPACE,
            HostInteropTestSupport.REFERENCE,
            SealedEnrollmentProtocol.MAX_SESSION_TTL_MILLIS,
        )
        try {
            HostInteropTestSupport.writeDescriptor(context, descriptor)
            val restored = HostInteropTestSupport.readDescriptor(context)
            assertEquals(
                descriptor.sessionID,
                HostInteropTestSupport.sessionId(restored),
            )
            assertEquals(
                descriptor.expiresAtEpochMillis,
                restored.getLong("expiresAtEpochMillis"),
            )
            assertTrue(
                "owned session state is missing",
                DebugSealedEnrollment.sessionStateExists(context, descriptor.sessionID),
            )
            assertTrue(
                "owned session key is missing",
                DebugSealedEnrollment.sessionKeyExists(descriptor.sessionID),
            )
            Log.i("FloeCredentialQA", "PASS host-interop-phase1 descriptor-written")
        } catch (error: Throwable) {
            runCatching { HostInteropTestSupport.cleanup(context) }
            throw error
        }
    }
}
