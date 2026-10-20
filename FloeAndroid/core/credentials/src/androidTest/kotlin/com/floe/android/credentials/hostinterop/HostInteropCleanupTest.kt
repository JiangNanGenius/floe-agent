// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials.hostinterop

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.floe.android.credentials.AndroidKeystoreCredentialStore
import com.floe.android.credentials.CredentialTestSupport
import com.floe.android.credentials.debug.DebugSealedEnrollment
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Explicit cleanup for an interrupted host-interop run. Select it with
 * `-e floeHostInteropPhase cleanup` after either phase fails or the device is
 * disconnected. It removes only this fixture's namespace, reference, owned
 * session state/key and `noBackupFilesDir/floe-qa-host-interop` directory.
 */
@RunWith(AndroidJUnit4::class)
class HostInteropCleanupTest {
    @Test
    fun cleanupInterruptedRun() {
        assumeTrue(
            "run with -e ${HostInteropTestSupport.PHASE_ARGUMENT} cleanup",
            HostInteropTestSupport.phase() == "cleanup",
        )
        val context = CredentialTestSupport.context()
        val removed = HostInteropTestSupport.cleanup(context)
        val store = AndroidKeystoreCredentialStore(context, HostInteropTestSupport.NAMESPACE)

        assertFalse(
            "host-interop directory remains",
            HostInteropTestSupport.directory(context).exists(),
        )
        assertFalse(
            "public descriptor remains",
            HostInteropTestSupport.descriptorFile(context).exists(),
        )
        assertFalse(
            "sealed ciphertext remains",
            HostInteropTestSupport.sealedFile(context).exists(),
        )
        assertNull(
            "owned credential remains",
            CredentialTestSupport.runSuspendBlocking {
                store.read(HostInteropTestSupport.REFERENCE)
            },
        )
        removed.forEach { sessionID ->
            assertFalse(
                "owned session state remains",
                DebugSealedEnrollment.sessionStateExists(context, sessionID),
            )
            assertFalse(
                "owned session key remains",
                DebugSealedEnrollment.sessionKeyExists(sessionID),
            )
        }
        assertFalse(
            "fixed plaintext payload found in no-backup storage",
            CredentialTestSupport.containsBytes(
                context.noBackupFilesDir,
                HostInteropTestSupport.PAYLOAD,
            ),
        )
        Log.i("FloeCredentialQA", "PASS host-interop-cleanup")
    }
}
