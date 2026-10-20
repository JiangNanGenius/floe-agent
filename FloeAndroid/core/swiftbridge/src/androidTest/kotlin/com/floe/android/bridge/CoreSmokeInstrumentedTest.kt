// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Device smoke over the REAL Android runtime: the vendored SQLite/GRDB
 * authority, the exact 46-migration chain, the MEASURED unicode61 FTS
 * contract, monotonic run-event cursors, a file-backed WAL database whose
 * sqlite3_snapshot_{get,cmp,free,open} calls prove the previously-undefined
 * probe symbols now execute on device, durable reopen, and the ACTUAL JSON
 * primitive kinds behind the DesignCanvasMetadata Android Bool branch.
 * Nothing here registers a binder, grant or task authority; the temporary
 * database directory is deleted by the seam. Full business flows, Keystore,
 * process-kill durability and App UI acceptance remain later gates.
 */
@RunWith(AndroidJUnit4::class)
class CoreSmokeInstrumentedTest {
    private companion object {
        const val TAG = "FloeQualification"
    }

    private fun failuresOf(report: JSONObject): String =
        report.optJSONArray("failures")?.let { values ->
            (0 until values.length()).map(values::getString).joinToString("; ")
        }.orEmpty()

    @Test
    fun realDatabaseMigrationsFTSAndWalSnapshotOnDevice() {
        val cacheDir = InstrumentationRegistry.getInstrumentation()
            .targetContext.cacheDir.absolutePath
        val report = JSONObject(QualificationNative.nativeDbSmoke(cacheDir))
        Log.i(TAG, "db-smoke: $report")
        assertTrue("db smoke failures: ${failuresOf(report)}", report.getBoolean("ok"))
        assertEquals(46, report.getInt("schemaVersion"))
        assertEquals(46, report.getInt("coreSchemaVersion"))
        assertEquals(46, report.getInt("appliedMigrationCount"))
        assertTrue(report.getBoolean("appliedContainsV1"))
        assertTrue(report.getBoolean("appliedContainsV46"))
        assertTrue(report.getBoolean("ftsTablePresent"))
        assertEquals(1, report.getInt("ftsEnglishHits"))
        assertEquals(0, report.getInt("ftsCjkSubstringHits"))
        assertEquals(1, report.getInt("ftsWholeRunPhraseHits"))
        assertEquals(1, report.getInt("ftsWildcardHits"))
        assertEquals(listOf(1, 2, 3), report.getJSONArray("runEventSequences").toIntList())
        assertTrue(report.getBoolean("cursorAfterOne"))
        assertTrue(report.getBoolean("upsertSingleRow"))
        assertEquals(46, report.getInt("fileSchemaVersion"))
        assertEquals("wal", report.getString("journalMode"))
        // Symbol-closure runtime proof: get/cmp must execute successfully on
        // the file WAL DB. snapshot_open is a hard gate, not an observation:
        // the Swift smoke fails report.ok when it is not SQLITE_OK (0), and
        // this test asserts 0 explicitly as well. The row read is logged for
        // the record (the previous hardware run observed 1).
        assertEquals(0, report.getInt("snapshotGetCode"))
        assertEquals(0, report.getInt("snapshotCmpEqualSnapshots"))
        assertEquals(0, report.getInt("snapshotOpenCode"))
        Log.i(TAG, "snapshotOpenCode=${report.getInt("snapshotOpenCode")} " +
            "rows=${report.getInt("snapshotOpenRowRead")} " +
            "memoryGetCode=${report.getInt("snapshotGetOnMemoryCode")}")
        assertTrue(report.getBoolean("durableReopenOK"))
        assertEquals("durable", report.getString("durableReopenTitle"))
        // The seam deletes its directory under the cache dir.
        val leftovers = File(cacheDir).listFiles { file ->
            file.isDirectory && file.name.startsWith("floe-native-smoke-")
        }.orEmpty()
        assertEquals("smoke DB not cleaned up: ${leftovers.map { it.name }}", 0, leftovers.size)
    }

    @Test
    fun dbSmokeRejectsInvalidCachePaths() {
        assertThrows(IllegalArgumentException::class.java) {
            QualificationNative.nativeDbSmoke("relative/path")
        }
        assertThrows(IllegalArgumentException::class.java) {
            QualificationNative.nativeDbSmoke("")
        }
        // A syntactically absolute but escaping path is rejected by Swift;
        // JNI accepts it, the seam must answer with a typed error and NOT
        // touch the filesystem outside the cache.
        val verdict = JSONObject(QualificationNative.nativeDbSmoke("/../../etc"))
        assertTrue(verdict.has("error") || !verdict.getBoolean("ok"))
    }

    @Test
    fun jsonKindSmokeReportsActualPrimitivesAndCanvasMapping() {
        val report = JSONObject(QualificationNative.nativeJsonKindSmoke())
        Log.i(TAG, "json-kind: $report")
        assertTrue("json-kind failures: ${failuresOf(report)}", report.getBoolean("ok"))
        assertTrue("foundation-object Canvas contract must hold on Android",
            report.getBoolean("foundationMappingContractHolds"))
        assertTrue("strict Codable ordering must hold on Android",
            report.getBoolean("decoderMappingContractHolds"))
        val values = report.getJSONArray("foundationValues")
        assertEquals(7, values.length())
        val byLabel = (0 until values.length())
            .map(values::getJSONObject).associateBy { it.getString("label") }
        // These raw reports are the parity EVIDENCE (logged for capture):
        listOf("true", "false", "int1", "int0", "frac", "string", "null").forEach { label ->
            val entry = byLabel.getValue(label)
            Log.i(TAG, "json-kind[$label] type=${entry.optString("typeName")} " +
                "typeOfEqualsBoolSelf=${entry.optBoolean("typeOfEqualsBoolSelf")} " +
                "isNSNumber=${entry.optBoolean("isNSNumber")} " +
                "objCType=${entry.optString("numberObjCType")} case=${entry.getString("designCase")}")
        }
        assertEquals("bool", byLabel.getValue("true").getString("designCase"))
        assertEquals("bool", byLabel.getValue("false").getString("designCase"))
        assertEquals("integer", byLabel.getValue("int1").getString("designCase"))
        assertEquals("integer", byLabel.getValue("int0").getString("designCase"))
        // Exact CF runtime identity, not the Swift dynamic type: booleans are
        // CFBoolean; JSON 1/0 and 1.5 are CFNumber even though as? Bool succeeds.
        assertTrue(byLabel.getValue("true").getBoolean("cfTypeIsBoolean"))
        assertTrue(byLabel.getValue("false").getBoolean("cfTypeIsBoolean"))
        assertFalse(byLabel.getValue("int1").getBoolean("cfTypeIsBoolean"))
        assertFalse(byLabel.getValue("int0").getBoolean("cfTypeIsBoolean"))
        assertFalse(byLabel.getValue("frac").getBoolean("cfTypeIsBoolean"))
        assertTrue(listOf("decimal", "number")
            .contains(byLabel.getValue("frac").getString("designCase")))
        assertEquals("string", byLabel.getValue("string").getString("designCase"))
        assertEquals("null", byLabel.getValue("null").getString("designCase"))
        val decoderCases = report.getJSONArray("decoderCases")
        assertEquals(
            listOf("integer", "integer", "bool", "bool"),
            (0 until 4).map(decoderCases::getString))
        assertTrue(listOf("decimal", "number").contains(decoderCases.getString(4)))
        assertEquals("[1,0,true,false,1.5]", report.getString("decoderRoundTrip"))
    }

    @Test
    fun jsonKindSmokeDistinguishesConstructedNarrowNSNumbers() {
        val report = JSONObject(QualificationNative.nativeJsonKindSmoke())
        Log.i(TAG, "json-kind-narrow: $report")
        assertTrue("json-kind failures: ${failuresOf(report)}", report.getBoolean("ok"))
        assertTrue("constructed NSNumber mapping contract",
            report.getBoolean("narrowNumbersContractHolds"))
        val values = report.getJSONArray("narrowNumbers")
        assertEquals(14, values.length())
        val expected = mapOf(
            "int8-1" to "integer",
            "int8-0" to "integer",
            "int8-neg1" to "integer",
            "uint8-1" to "integer",
            "int16-1" to "integer",
            "uint16-1" to "integer",
            "int32-1" to "integer",
            "uint32-1" to "integer",
            "int64-1" to "integer",
            "uint64-1" to "integer",
            "int64-max" to "integer",
            "uint64-max" to "unsigned",
            "bool-true" to "bool",
            "bool-false" to "bool",
        )
        val byLabel = (0 until values.length())
            .map(values::getJSONObject).associateBy { it.getString("label") }
        assertEquals(expected.keys, byLabel.keys)
        for ((label, designCase) in expected) {
            val entry = byLabel.getValue(label)
            assertEquals(label, designCase, entry.getString("designCase"))
            // CFBoolean identity is the discriminator; Int8's objCType is "c"
            // and as? Bool also succeeds, so neither can decide this.
            assertEquals(label, designCase == "bool", entry.getBoolean("cfTypeIsBoolean"))
        }
        assertFalse(byLabel.getValue("int8-1").getBoolean("cfTypeIsBoolean"))
        assertTrue(byLabel.getValue("bool-true").getBoolean("cfTypeIsBoolean"))
    }

    private fun JSONArray.toIntList(): List<Int> = (0 until length()).map(::getInt)
}
