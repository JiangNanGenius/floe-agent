// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials.restart

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.floe.android.credentials.AndroidKeystoreCredentialStore
import com.floe.android.credentials.CredentialTestSupport
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Phase 1 of the real process-restart proof. Run alone with
 * `-e floeRestartPhase 1`, then force-stop the test package and run
 * [RestartPhase2Test] with `-e floeRestartPhase 2`.
 */
@RunWith(AndroidJUnit4::class)
class RestartPhase1Test {
    @Test
    fun writeDurableRecordAndProcessToken() {
        assumeTrue("run with -e floeRestartPhase 1", RestartTestSupport.phase() == "1")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = AndroidKeystoreCredentialStore(context, RestartTestSupport.NAMESPACE)

        CredentialTestSupport.runSuspendBlocking { store.delete(RestartTestSupport.REFERENCE) }
        CredentialTestSupport.runSuspendBlocking {
            store.write(RestartTestSupport.REFERENCE, RestartTestSupport.PAYLOAD)
        }
        val restored = CredentialTestSupport.runSuspendBlocking {
            store.read(RestartTestSupport.REFERENCE)
        }
        assertTrue("record was not readable in phase 1", restored != null)
        CredentialTestSupport.assertBytesEqual("restart payload", RestartTestSupport.PAYLOAD, restored)

        val token = RestartTestSupport.tokenFile(context)
        token.parentFile?.mkdirs()
        token.writeText(RestartTestSupport.PROCESS_TOKEN, Charsets.UTF_8)
        Log.i("FloeCredentialQA", "PASS restart-phase1 record-written")
    }
}
