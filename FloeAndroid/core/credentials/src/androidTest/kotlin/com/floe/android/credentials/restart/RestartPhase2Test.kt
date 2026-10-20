// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials.restart

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.floe.android.credentials.AndroidKeystoreCredentialStore
import com.floe.android.credentials.CredentialTestSupport
import com.floe.android.credentials.debug.DebugCredentialStoreAccess
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Phase 2 of the real process-restart proof. It fails if the process token is
 * unchanged, so running both phases inside one instrumentation process cannot
 * pass as a fake restart.
 */
@RunWith(AndroidJUnit4::class)
class RestartPhase2Test {
    @Test
    fun readKeystoreRecordAfterRealProcessRestart() {
        assumeTrue("run with -e floeRestartPhase 2", RestartTestSupport.phase() == "2")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val token = RestartTestSupport.tokenFile(context)
        assertTrue("phase 1 token is missing; run RestartPhase1Test first", token.isFile)
        val phaseOneToken = token.readText(Charsets.UTF_8)
        assertNotEquals(
            "phase 2 ran in the phase 1 process; force-stop between phases",
            phaseOneToken,
            RestartTestSupport.PROCESS_TOKEN,
        )

        val store = AndroidKeystoreCredentialStore(context, RestartTestSupport.NAMESPACE)
        val restored = CredentialTestSupport.runSuspendBlocking {
            store.read(RestartTestSupport.REFERENCE)
        }
        assertTrue("committed record did not survive the process restart", restored != null)
        CredentialTestSupport.assertBytesEqual("restart payload", RestartTestSupport.PAYLOAD, restored)

        CredentialTestSupport.runSuspendBlocking { store.delete(RestartTestSupport.REFERENCE) }
        assertNull(CredentialTestSupport.runSuspendBlocking { store.read(RestartTestSupport.REFERENCE) })
        assertFalse(
            DebugCredentialStoreAccess.hasKey(
                RestartTestSupport.NAMESPACE,
                RestartTestSupport.REFERENCE,
            ),
        )
        token.delete()
        Log.i("FloeCredentialQA", "PASS restart-phase2 new-process-keystore-read")
    }
}
