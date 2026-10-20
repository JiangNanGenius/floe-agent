// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials.hostinterop

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.floe.android.credentials.AndroidKeystoreCredentialStore
import com.floe.android.credentials.CredentialTestSupport
import com.floe.android.credentials.debug.DebugEnrollmentException
import com.floe.android.credentials.debug.DebugSealedEnrollment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Phase 2 of the host -> Android interop proof. Run with
 * `-e floeHostInteropPhase 2` after the host sealer wrote `sealed.bin`. The
 * session was created by [HostInteropPhase1Test] in an earlier process.
 */
@RunWith(AndroidJUnit4::class)
class HostInteropPhase2Test {
    @Test
    fun importHostSealedPayload() {
        assumeTrue(
            "run with -e ${HostInteropTestSupport.PHASE_ARGUMENT} 2",
            HostInteropTestSupport.phase() == "2",
        )
        val context = CredentialTestSupport.context()
        val descriptor = HostInteropTestSupport.readDescriptor(context)
        val sessionID = HostInteropTestSupport.sessionId(descriptor)
        assertEquals(
            "descriptor package does not match the test package",
            context.packageName,
            descriptor.getString("packageName"),
        )
        val sealed = HostInteropTestSupport.readSealed(context)
        val store = AndroidKeystoreCredentialStore(context, HostInteropTestSupport.NAMESPACE)

        try {
            val result = CredentialTestSupport.runSuspendBlocking {
                DebugSealedEnrollment.importSealed(context, sealed)
            }
            assertEquals(sessionID, result.sessionID)
            assertEquals(HostInteropTestSupport.REFERENCE, result.reference)
            assertEquals(HostInteropTestSupport.PAYLOAD.size, result.byteCount)

            val restored = CredentialTestSupport.runSuspendBlocking {
                store.read(HostInteropTestSupport.REFERENCE)
            }
            CredentialTestSupport.assertBytesEqual(
                "host-sealed interop payload",
                HostInteropTestSupport.PAYLOAD,
                restored,
            )
            assertFalse(
                "session state remains after a successful import",
                DebugSealedEnrollment.sessionStateExists(context, sessionID),
            )
            assertFalse(
                "session key remains after a successful import",
                DebugSealedEnrollment.sessionKeyExists(sessionID),
            )
            assertThrows(DebugEnrollmentException.SessionUnknown::class.java) {
                CredentialTestSupport.runSuspendBlocking {
                    DebugSealedEnrollment.importSealed(context, sealed)
                }
            }
            assertFalse(
                "fixed plaintext payload found in no-backup storage",
                CredentialTestSupport.containsBytes(
                    context.noBackupFilesDir,
                    HostInteropTestSupport.PAYLOAD,
                ),
            )
            assertFalse(
                "fixed plaintext payload found in files storage",
                CredentialTestSupport.containsBytes(
                    context.filesDir,
                    HostInteropTestSupport.PAYLOAD,
                ),
            )
            assertFalse(
                "fixed plaintext payload found in cache storage",
                CredentialTestSupport.containsBytes(
                    context.cacheDir,
                    HostInteropTestSupport.PAYLOAD,
                ),
            )
            Log.i("FloeCredentialQA", "PASS host-interop-phase2 sealed-import")
        } finally {
            HostInteropTestSupport.cleanup(context)
        }
    }
}
