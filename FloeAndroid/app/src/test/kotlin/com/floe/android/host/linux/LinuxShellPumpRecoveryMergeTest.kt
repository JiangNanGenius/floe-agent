// SPDX-License-Identifier: MPL-2.0
// Focused identity/binding regressions for the OPTIONAL per-execution
// recovery projection merge in LinuxShellPump (job-5b987a08b1df40b2).
// Author-written against the 951f2f68/bacbaf91 baseline; intended for the
// existing app JVM unit-test source set (kotlinx-serialization-json is
// already a production dependency; org.json is NOT used here on purpose).
// NOT executed by this lane.
package com.floe.android.host.linux

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private val KEY = "ab".repeat(16) // 32 hex
private const val RUN = "A1B2C3D4-0000-4000-9000-000000000004"
private const val RUN_LOWER = "a1b2c3d4-0000-4000-9000-000000000004"
private val D64a = "a".repeat(64)
private val D64b = "b".repeat(64)

class LinuxShellPumpRecoveryMergeTest {
    private fun obj(text: String): JsonObject = Json.parseToJsonElement(text).jsonObject

    private fun page(
        sessionKey: String = KEY,
        runID: String = RUN,
        preserved: String = """[{"path":"r3cas/marker.txt","action":"swappedPreserved",
            "preservedSha256":"$D64a","preservedBytes":30,
            "installedBaselineSha256":"$D64b","installedBaselineBytes":27}]""",
        export: String = """{"failureCode":"budgetExceeded","stagedPreserved":true}""",
    ): JsonObject = obj("""
        {"sessionKey":"$sessionKey","runID":"$runID",
         "import":{"outcome":"swappedPreserved","created":0,"replacedSynced":1,"preservedUnsynced":1,
                   "unchanged":2,"appliedBytes":57,"preserved":$preserved},
         "export":$export}
    """.trimIndent())

    @Test fun legacyPageWithoutRecoveryStaysAbsent() {
        assertNull(LinuxShellPump.mergeWorkspaceRecovery(null, null, KEY, RUN))
        assertNull(LinuxShellPump.mergeWorkspaceRecovery(page(), null, null, RUN))
    }

    @Test fun foreignSessionOrForeignRunDropsEverything() {
        assertNull(LinuxShellPump.mergeWorkspaceRecovery(page(sessionKey = "cd".repeat(16)), null, KEY, RUN))
        assertNull(LinuxShellPump.mergeWorkspaceRecovery(page(runID = "B1B2C3D4-0000-4000-9000-000000000004"),
                                                         null, KEY, RUN))
        // Missing run echo is unbound -> dropped, never attached to this run.
        assertNull(LinuxShellPump.mergeWorkspaceRecovery(
            obj("""{"sessionKey":"$KEY","import":{"outcome":"clean","created":0,"replacedSynced":0,
                 "preservedUnsynced":0,"unchanged":1,"appliedBytes":0},"export":{"result":"synced"}}"""),
            null, KEY, RUN))
    }

    @Test fun coreCaseRunUUIDStillBindsToJavaNormalizedRun() {
        // Core echoes the UPPER-case canonical UUID; the pump stores the
        // Java-normalised lower-case string. Identity must match anyway.
        val merged = LinuxShellPump.mergeWorkspaceRecovery(page(), null, KEY, RUN_LOWER)
        assertTrue(merged != null)
        assertEquals(KEY, merged!!.getString("sessionKey"))
    }

    @Test fun noCoreReceiptKeepsRuntimeTypedViewUntouched() {
        val merged = LinuxShellPump.mergeWorkspaceRecovery(page(), null, KEY, RUN)!!
        val export = merged["export"]!!.jsonObject
        assertEquals("budgetExceeded", export.getString("failureCode"))
        assertNull(export["source"])
    }

    @Test fun coreReceiptBecomesAuthoritativeExportSection() {
        val reply = obj("""
            {"ok":true,"result":"aborted",
             "applied":{"created":0,"replaced":0,"directories":0,"deleted":0,"links":0},
             "counts":{"failed":0,"stagedRefusals":0},
             "preview":{"conflicts":[{"path":"r3cas/other.txt","kind":"file","artifact":true}],"truncated":false},
             "recovery":{"sessionKey":"$KEY","indexDigest":"$D64a"}}
        """.trimIndent())
        val merged = LinuxShellPump.mergeWorkspaceRecovery(page(), reply, KEY, RUN)!!
        val export = merged["export"]!!.jsonObject
        assertEquals("aborted", export.getString("result"))
        assertEquals("core-export-finish", export.getString("source"))
        assertEquals(D64a, export.getString("indexDigest"))
        assertEquals("r3cas/other.txt", export["conflicts"]!!.jsonArray[0].jsonObject.getString("path"))
        assertEquals(KEY, merged.getString("sessionKey"))
        // The import half (runtime-measured custody facts) survives intact.
        val preserved = merged["import"]!!.jsonObject["preserved"]!!.jsonArray
        assertEquals(D64a, preserved[0].jsonObject.getString("preservedSha256"))
    }

    @Test fun mismatchedCoreReceiptDoesNotOverwriteRuntimeView() {
        val foreign = "ee".repeat(16)
        val reply = obj("""{"ok":true,"result":"synced","recovery":{"sessionKey":"$foreign"}}""")
        val merged = LinuxShellPump.mergeWorkspaceRecovery(page(), reply, KEY, RUN)!!
        assertEquals("budgetExceeded", merged["export"]!!.jsonObject.getString("failureCode"))
    }

    @Test fun malformedCoreExportFieldsAreDroppedNotForwarded() {
        val reply = obj("""
            {"ok":true,"result":"synced","applied":{"created":5},
             "recovery":{"sessionKey":"$KEY","indexDigest":"not-hex"}}
        """.trimIndent())
        val export = LinuxShellPump.mergeWorkspaceRecovery(page(), reply, KEY, RUN)!!["export"]!!.jsonObject
        assertEquals("synced", export.getString("result"))
        assertNull("a non-hex index digest must never be forwarded", export["indexDigest"])
        assertEquals(5L, export["applied"]!!.jsonObject.longAt("created"))
    }

    // small local helpers (test-side only; production merge has its own)
    private fun JsonObject.getString(key: String): String? = (this[key]?.jsonPrimitive?.content)
    private fun JsonObject.longAt(key: String): Long? = this[key]?.jsonPrimitive?.content?.toLongOrNull()
}
