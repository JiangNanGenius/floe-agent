// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

import android.os.Process
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.SecureRandom
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Bounded API 37 qualification of the RB-1 runtime lifecycle through the
 * ACTUAL JNI/Core surfaces in the dedicated `com.floe.android.bridge.test`
 * self-target APK (never the product App UID):
 *
 *  * trusted start opens the ORIGINAL file-backed DatabaseManager in an
 *    app-private root and really applies the pinned migration chain (46);
 *  * the v3 `effect.poll` entry returns the committed terminal through the
 *    real JNI exchange, and an acknowledged cursor yields an honest empty
 *    page;
 *  * exact-epoch/token stop, wrong-epoch and wrong-token refusals, real
 *    post-close readability of the retired terminal, a real close (phase
 *    stopped / store closed), restart with a newer epoch, and old-receipt
 *    isolation from the new generation.
 *
 * The Product-UID coordinator/gateway path stays a Main device gate; this
 * component host proves the lifecycle + wire truth it depends on.
 */
@RunWith(AndroidJUnit4::class)
class RuntimeBootstrapInstrumentedTest {

    private val json = Json { ignoreUnknownKeys = true; isLenient = false }
    private val ownedRoots = mutableListOf<File>()

    @org.junit.After
    fun cleanOnlyTestOwnedData() {
        // The test APK owns this app-private directory. Remove exactly the
        // subdirectories this test created; never touch product App data.
        for (root in ownedRoots) {
            try {
                if (root.exists()) root.deleteRecursively()
            } catch (_: Throwable) {
                // Best-effort cleanup; the assertion evidence is already
                // captured. Never fail the test for stale test-owned files.
            }
        }
        ownedRoots.clear()
    }

    private fun context() = InstrumentationRegistry.getInstrumentation().targetContext

    private fun token(): String {
        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }

    private fun effectEnvelope(correlation: String, receipt: String,
                               sequence: Long): String =
        """{"version":3,"operation":"effect.poll","requestID":"$correlation",""" +
            """"envelope":{"schema":"floe.effect-cursor/3",""" +
            """"scope":"applicationConfiguration","configurationScope":"system",""" +
            """"command":"effect.poll","stateful":false,""" +
            """"correlationID":"$correlation",""" +
            """"effect":{"operationReceiptID":"$receipt","sequence":$sequence}}}"""

    private fun poll(receipt: String, sequence: Long = 0): JsonObject {
        val raw = SwiftCore.exchange(effectEnvelope(
            "rb1-dev-${System.nanoTime()}", receipt, sequence))
        return json.parseToJsonElement(raw).jsonObject
    }

    private fun status(): JsonObject =
        json.parseToJsonElement(RuntimeCoreNative.runtimeStatus()!!).jsonObject

    private fun awaitTerminal(receipt: String): JsonObject {
        val deadline = System.currentTimeMillis() + 30_000
        while (System.currentTimeMillis() < deadline) {
            val page = poll(receipt)
            if (page["ok"]?.jsonPrimitive?.booleanOrNull == true) {
                val effects = page["effects"]?.jsonArray
                if (effects != null) {
                    val terminal = effects.map { it.jsonObject }.lastOrNull {
                        it["kind"]?.jsonPrimitive?.content in
                            setOf("accepted", "failed", "rejected", "cancelled",
                                  "replaced", "closed")
                    }
                    if (terminal != null) return terminal
                }
            } else {
                val reason = page["reason"]?.jsonPrimitive?.content
                if (reason != "effectReceiptNotFound" &&
                    reason != "effectPumpUnbound") {
                    throw AssertionError("effect.poll refused: $page")
                }
            }
            Thread.sleep(50)
        }
        throw AssertionError("terminal never readable for $receipt")
    }

    @Test
    fun realLifecycleAcrossJniAndWireKeepsRetiredTerminalsHonest() {
        val ctx = context()
        val rootFile = File(ctx.filesDir, "rb1-inst-${System.nanoTime()}")
        ownedRoots += rootFile
        val root = rootFile.absolutePath
        val owner = token()
        val epoch = System.currentTimeMillis()

        // 1) Trusted start through the real JNI ABI.
        val receipt = RuntimeCoreNative.runtimeOwnerStart(root, owner, epoch)
        assertTrue("receipt must be opaque: $receipt",
            receipt.startsWith("op:v1:") && receipt.length == 38)

        // 2) The committed terminal is learned through the ACTUAL v3 entry.
        val accepted = awaitTerminal(receipt)
        assertEquals("accepted", accepted["kind"]?.jsonPrimitive?.content)
        val ready = status()
        assertEquals(1L, ready["version"]?.jsonPrimitive?.longOrNull)
        assertEquals("starting", ready["phase"]?.jsonPrimitive?.content)
        assertEquals(epoch, ready["generation"]?.jsonPrimitive?.longOrNull)
        assertEquals(true, ready["ownedStoreReady"]?.jsonPrimitive?.booleanOrNull)
        assertEquals("ready", ready["ownedStorePhase"]?.jsonPrimitive?.content)
        assertEquals(46L, ready["schemaVersion"]?.jsonPrimitive?.longOrNull)
        assertEquals(false, ready["domainRuntimeReady"]?.jsonPrimitive?.booleanOrNull)
        assertEquals("blocked",
            ready["ordinaryRuntimeAdmission"]?.jsonPrimitive?.content)
        // The ORIGINAL store file really exists under the trusted root.
        val dbFile = File(root, "floe.sqlite")
        assertTrue("migrated original DB must exist", dbFile.isFile)
        assertTrue("migrated DB must have content", dbFile.length() > 0)

        // 3) The acknowledged cursor is an honest empty page, not a re-emit.
        val page = poll(receipt)
        val cursor = page["cursor"]!!.jsonObject["sequence"]!!
            .jsonPrimitive.longOrNull!!
        val afterAck = poll(receipt, cursor)
        assertEquals(0, afterAck["effects"]?.jsonArray?.size)
        assertEquals(false, afterAck["hasMore"]?.jsonPrimitive?.booleanOrNull)

        // 4) Identity fences: same-epoch replay is idempotent; a wrong token
        //    and a STALE epoch are typed refusals (never a second owner).
        // Idempotent replay of the SAME accepted start returns the SAME
        // receipt (status idempotentOk), never a second owner/job.
        assertEquals(receipt, RuntimeCoreNative.runtimeOwnerStart(root, owner, epoch))
        try {
            RuntimeCoreNative.runtimeOwnerStart(root, token(), epoch)
            throw AssertionError("wrong owner token must be refused")
        } catch (error: RuntimeNativeException) {
            assertEquals(-204, error.status)
        }
        try {
            RuntimeCoreNative.runtimeOwnerStop(epoch - 1, owner)
            throw AssertionError("stale stop proof must be refused")
        } catch (error: RuntimeNativeException) {
            assertTrue(error.status in setOf(-203, -204))
        }

        // 5) Real stop: accepted receipt, terminal only after the close.
        val stopReceipt = RuntimeCoreNative.runtimeOwnerStop(epoch, owner)
        val stop = awaitTerminal(stopReceipt)
        assertEquals("accepted", stop["kind"]?.jsonPrimitive?.content)
        val stopped = status()
        assertEquals("stopped", stopped["phase"]?.jsonPrimitive?.content)
        assertEquals("closed", stopped["ownedStorePhase"]?.jsonPrimitive?.content)
        assertEquals(false, stopped["ownedStoreReady"]?.jsonPrimitive?.booleanOrNull)
        assertEquals(true, stopped["effectPollAvailable"]?.jsonPrimitive?.booleanOrNull)

        // 6) Post-close: the retired terminal stays readable via the ACTUAL
        //    entry, and a never-seen receipt is typed notFound.
        val retired = awaitTerminal(stopReceipt)
        assertEquals("accepted", retired["kind"]?.jsonPrimitive?.content)
        val foreign = poll("op:v1:" + "0".repeat(32))
        assertEquals("runtimeUnavailable",
            foreign["error"]?.jsonPrimitive?.content)
        assertEquals("effectReceiptNotFound",
            foreign["reason"]?.jsonPrimitive?.content)

        // 7) Restart with a strictly newer epoch: the OLD receipt never
        //    resurfaces in the new generation's pump, while the retired route
        //    still answers it honestly.
        val newEpoch = epoch + 1
        val restartReceipt = RuntimeCoreNative.runtimeOwnerStart(root, owner, newEpoch)
        assertEquals("accepted", awaitTerminal(restartReceipt)["kind"]
            ?.jsonPrimitive?.content)
        val restartStatus = status()
        assertEquals(newEpoch, restartStatus["generation"]?.jsonPrimitive?.longOrNull)
        val oldAgain = awaitTerminal(stopReceipt)
        assertEquals("accepted", oldAgain["kind"]?.jsonPrimitive?.content)
        val stoppedAgain = RuntimeCoreNative.runtimeOwnerStop(newEpoch, owner)
        assertEquals("accepted", awaitTerminal(stoppedAgain)["kind"]
            ?.jsonPrimitive?.content)
        assertFalse(File(root).listFiles().isNullOrEmpty())
    }

    @Test
    fun failedBootstrapIsTypedAndDoesNotFabricateReadiness() {
        val ctx = context()
        // A regular FILE where the trusted root directory should be makes the
        // real open fail typed (no fallback path, no RAM store).
        val base = File(ctx.filesDir, "rb1-bad-${System.nanoTime()}")
        ownedRoots += base
        base.parentFile?.mkdirs()
        base.writeText("not-a-directory")
        val badRoot = File(base, "sub").absolutePath
        val owner = token()
        val epoch = System.currentTimeMillis()
        val receipt = RuntimeCoreNative.runtimeOwnerStart(badRoot, owner, epoch)
        val terminal = awaitTerminal(receipt)
        assertEquals("failed", terminal["kind"]?.jsonPrimitive?.content)
        assertNotNull(terminal["code"]?.jsonPrimitive?.content)
        val failed = status()
        assertEquals(false, failed["ownedStoreReady"]?.jsonPrimitive?.booleanOrNull)
        assertEquals("blocked",
            failed["ordinaryRuntimeAdmission"]?.jsonPrimitive?.content)
        // A failed generation never mints a second owner; the supported retry
        // needs a strictly newer epoch after the real retirement.
        try {
            RuntimeCoreNative.runtimeOwnerStart(badRoot, owner, epoch)
            throw AssertionError("replay while retiring must refuse")
        } catch (error: RuntimeNativeException) {
            // Typed refusal only: the failed generation either still owns its
            // retirement (-205/-210), or it already retired and the reused
            // epoch is stale (-203), or nothing is installed (-207). The
            // contract asserted here is "never a second owner", not one
            // specific race winner.
            assertTrue("unexpected status ${error.status}",
                error.status in setOf(-203, -205, -207, -210))
        }
    }
    @Test
    fun isolatedTestTargetRunsInItsOwnUidAndNeverTheProductApp() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val target = instrumentation.targetContext
        val targetPackage = target.packageName
        val instrumentationPackage = instrumentation.context.packageName
        val targetUid = target.applicationInfo.uid
        val processUid = Process.myUid()
        // The manifest targetPackage is checked independently from the built
        // APK. Here the runtime proof: the instrumentation process IS the
        // test target's own UID, not a product-App UID.
        assertEquals("com.floe.android.bridge.test", targetPackage)
        assertEquals("com.floe.android.bridge.test", instrumentationPackage)
        assertEquals(targetUid, processUid)
        assertTrue("test data must live under the test target: ${target.filesDir}",
            target.filesDir.absolutePath.contains("com.floe.android.bridge.test"))
        assertFalse(targetPackage == "com.floe.agent" ||
            targetPackage == "com.floe.agent.full" ||
            targetPackage == "com.floe.agent.full.dev" ||
            targetPackage == "com.floe.agent.play" ||
            targetPackage == "com.floe.agent.play.dev")
    }

}
