// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge.tlsqualification

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Product-UID default-system-trust probe (job-b1709c36b200442c).
 *
 * Runs the SAME unauthenticated public HTTPS positive as the component T1,
 * but inside the instrumentation of the installed debug product App, i.e. in
 * a process carrying the real product UID (com.floe.agent.full.dev /
 * com.floe.agent.dev). This closes the testUID -> productUID distinction for
 * the trust path: the App manifest's INTERNET grant, SELinux domain and UID
 * state are the product ones, while the trust behavior (DEFAULT system CA,
 * chain + hostname verification) must be identical to the component result.
 *
 * Hard rules: DEFAULT trust only (the native entry itself refuses to run if
 * any CA override or the INSECURE_SSL_NO_VERIFY escape is present in this
 * process), no fixture material, no payload, no credentials, no user data.
 * This is one positive probe + environment guard, not App/UI acceptance and
 * not a G02 completion claim.
 */
@RunWith(AndroidJUnit4::class)
class ProductDefaultTLSProbeInstrumentedTest {
    private companion object {
        const val TAG = "FloeQualification"
    }

    @Test
    fun productUIDPublicPositiveUsesDefaultTrust() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val target = instrumentation.targetContext
        val uid = android.os.Process.myUid()
        Log.i(
            TAG,
            "transport-tls product uid=$uid package=${target.packageName}",
        )
        assertTrue(
            "instrumentation must run under the product UID namespace",
            target.packageName.startsWith("com.floe.agent"),
        )

        // Environment guard in the PRODUCT process: no lever, no escape.
        assertNull(
            "no CA override may exist in the product process",
            System.getenv("URLSessionCertificateAuthorityInfoFile"),
        )
        assertNull(
            "INSECURE_SSL_NO_VERIFY must never be set",
            System.getenv("INSECURE_SSL_NO_VERIFY"),
        )

        val report = JSONObject(
            com.floe.android.bridge.QualificationNative.nativeTLSQualification(
                JSONObject().put("scenario", "t1PublicPositive").toString(),
            ),
        )
        Log.i(TAG, "transport-tls product-t1: $report")
        assertTrue("product public positive failed: $report", report.getBoolean("ok"))
        assertFalse(report.optBoolean("overrideLeverPresent", false))
        val probes = report.getJSONArray("probes")
        var matchedCount = 0
        for (index in 0 until probes.length()) {
            val item = probes.getJSONObject(index)
            if (item.optBoolean("statusMatched")) matchedCount += 1
            Log.i(
                TAG,
                "transport-tls product-t1 ${item.getString("url")} status=" +
                    "${item.optInt("status", -1)} matched=${item.optBoolean("statusMatched")}",
            )
        }
        assertTrue("at least one public probe must verify cleanly", matchedCount >= 1)
        assertEquals(2, probes.length())
    }
}
