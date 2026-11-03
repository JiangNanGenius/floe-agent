// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Deterministic policy regressions for the native guard binding and the
 * crash-recovery journal. These are pure host tests; no root service, helper,
 * process or Android device is used.
 */
class RootCaptureGuardPolicyTest {

    private val captureId = "11111111-2222-3333-4444-555555555555"
    private val outputPath = "${RootCaptureHelper.WORK_ROOT}/capture-$captureId.pcap"
    private val helperPath = "/data/app/~~abc==/com.floe.agent.full-xyz==/lib/arm64/libfloecapture_helper.so"
    private val helperSha = "a".repeat(64)

    private fun journal(
        owner: RootCaptureSessions.OwnerIdentity? = RootCaptureSessions.OwnerIdentity(
            taskId = "task-1",
            runId = "run-1",
            epoch = 7L,
        ),
        maxMillis: Long = 300_000L,
        maxBytes: Long = 128L * 1024L * 1024L,
        guardSchema: String = RootCaptureGuardPolicy.GUARD_SCHEMA,
    ): CaptureJournal = CaptureJournal(
        captureId = captureId,
        requestId = "capture:request-1",
        owner = owner,
        daemonPid = 1234L,
        daemonStartTicks = 5000L,
        bootId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        helperPid = 4321L,
        helperStartTicks = 7777L,
        helperPath = helperPath,
        helperSha256 = helperSha,
        outputPath = outputPath,
        startedAtMillis = 1_000_000L,
        deadlineMillis = 1_000_000L + maxMillis,
        maxMillis = maxMillis,
        maxBytes = maxBytes,
        guardSchema = guardSchema,
        guardVersion = RootCaptureGuardPolicy.GUARD_VERSION,
    )

    @Test
    fun journalRoundTripsWithOwner() {
        val original = journal()
        val text = RootCaptureGuardPolicy.encodeJournal(original)
        assertNotNull(text)
        assertEquals(original, RootCaptureGuardPolicy.parseJournal(text!!))
    }

    @Test
    fun journalRoundTripsWithoutOwnerForLegacyBinder() {
        val original = journal(owner = null)
        val text = RootCaptureGuardPolicy.encodeJournal(original)
        assertNotNull(text)
        val parsed = RootCaptureGuardPolicy.parseJournal(text!!)
        assertNotNull(parsed)
        assertNull(parsed!!.owner)
        assertEquals(original, parsed)
    }

    @Test
    fun journalRejectsMalformedOrUnboundRecords() {
        val valid = RootCaptureGuardPolicy.encodeJournal(journal())!!
        val invalid = listOf(
            valid.replace("schema=floe.capture-journal.v1", "schema=other"),
            valid.replace("captureId=$captureId", "captureId=not-a-uuid"),
            valid.replace(outputPath, "/data/local/tmp/capture-$captureId.pcap"),
            valid.replace("helperSha256=$helperSha", "helperSha256=" + "a".repeat(63)),
            valid.replace("helperStartTicks=7777", "helperStartTicks=0"),
            valid.replace("guardSchema=${RootCaptureGuardPolicy.GUARD_SCHEMA}", "guardSchema=other"),
            valid.replace("guardVersion=1", "guardVersion=2"),
            valid.replace("maxMillis=300000", "maxMillis=600001"),
            valid.replace("maxBytes=134217728", "maxBytes=4095"),
            valid.replace("ownerTaskId=task-1\n", ""),
            valid.replace("ownerRunId=run-1\n", ""),
            valid + "unknownKey=value\n",
            valid.replace("requestId=capture:request-1", "requestId=capture:req\u0001uest"),
            valid + "captureId=$captureId\n",
        )
        for (candidate in invalid) {
            assertNull(RootCaptureGuardPolicy.parseJournal(candidate))
        }
        assertNull(RootCaptureGuardPolicy.parseJournal(""))
        assertNull(RootCaptureGuardPolicy.parseJournal("x".repeat(9_000)))
    }

    @Test
    fun guardConfigLineIsExactAndFailsClosed() {
        assertEquals(
            "floe-guard-v1 300000 134217728 $outputPath\n",
            RootCaptureGuardPolicy.guardConfigLine(300_000L, 128L * 1024L * 1024L, outputPath),
        )
        assertNull(RootCaptureGuardPolicy.guardConfigLine(0L, 128L * 1024L * 1024L, outputPath))
        assertNull(RootCaptureGuardPolicy.guardConfigLine(600_001L, 128L * 1024L * 1024L, outputPath))
        assertNull(RootCaptureGuardPolicy.guardConfigLine(300_000L, 4_095L, outputPath))
        assertNull(
            RootCaptureGuardPolicy.guardConfigLine(
                300_000L,
                256L * 1024L * 1024L + 1L,
                outputPath,
            ),
        )
        assertNull(RootCaptureGuardPolicy.guardConfigLine(300_000L, 1_048_576L, "relative.pcap"))
        assertNull(
            RootCaptureGuardPolicy.guardConfigLine(
                300_000L,
                1_048_576L,
                "/data/local/floe-capture/work/capture-x.pcap\n",
            ),
        )
    }

    @Test
    fun readyRecordRequiresExactSchemaVersionAndPid() {
        val text = "ready schema=${RootCaptureGuardPolicy.GUARD_SCHEMA} version=1 pid=99 " +
            "max_millis=300000 max_bytes=1048576\n" +
            "stop schema=${RootCaptureGuardPolicy.GUARD_SCHEMA} reason=durationLimit forced=0 pid=99\n"
        assertTrue(RootCaptureGuardPolicy.readyRecord(text, 99L, 300_000L, 1_048_576L))
        assertFalse(RootCaptureGuardPolicy.readyRecord(text, 100L, 300_000L, 1_048_576L))
        assertFalse(RootCaptureGuardPolicy.readyRecord(text, 99L, 299_999L, 1_048_576L))
        assertFalse(RootCaptureGuardPolicy.readyRecord(text, 99L, 300_000L, 1_048_577L))
        assertFalse(
            RootCaptureGuardPolicy.readyRecord(
                "ready schema=other version=1 pid=99 max_millis=300000 max_bytes=1048576\n",
                99L,
                300_000L,
                1_048_576L,
            ),
        )
        assertFalse(
            RootCaptureGuardPolicy.readyRecord(
                "ready pid=99 max_millis=300000 max_bytes=1048576\n",
                99L,
                300_000L,
                1_048_576L,
            ),
        )
    }

    @Test
    fun stopReasonUsesLastKnownReasonAndRejectsUnknownValues() {
        val text = "ready schema=x version=1 pid=1\n" +
            "stop reason=durationLimit forced=0\n" +
            "hard_stop reason=sizeLimit forced=1\n"
        assertEquals("sizeLimit", RootCaptureGuardPolicy.stopReason(text))
        assertEquals(
            "daemonLost",
            RootCaptureGuardPolicy.stopReason("stop reason=daemonLost forced=0\n"),
        )
        assertNull(RootCaptureGuardPolicy.stopReason("stop reason=madeUp forced=0\n"))
        assertNull(RootCaptureGuardPolicy.stopReason("hard_stop forced=1\n"))
        assertNull(RootCaptureGuardPolicy.stopReason("ready schema=x\n"))
    }

    @Test
    fun statParsingHandlesSpacesAndParenthesesInComm() {
        val fields = (1..18).joinToString(" ")
        val stat = "999 (tcpdump (weird) name) S $fields 424242\n"
        assertEquals(424_242L, RootCaptureGuardPolicy.parseStartTimeTicks(stat))
        assertEquals(1L, RootCaptureGuardPolicy.parentPid(stat))
        assertNull(RootCaptureGuardPolicy.parseStartTimeTicks("not a stat line"))
        assertNull(RootCaptureGuardPolicy.parseStartTimeTicks("1 (x) S 1 2"))
    }

    @Test
    fun commandMatchIsBoundToHelperAndExactOutputPath() {
        val args = listOf(
            helperPath, "-i", "any", "-s", "65535", "-w", outputPath, "-U",
        )
        assertTrue(RootCaptureGuardPolicy.commandMatches(args, helperPath, outputPath))
        assertFalse(
            RootCaptureGuardPolicy.commandMatches(
                args.toMutableList().also { it[6] = "$outputPath.other" },
                helperPath,
                outputPath,
            ),
        )
        assertFalse(
            RootCaptureGuardPolicy.commandMatches(
                args.toMutableList().also { it[0] = "/system/bin/tcpdump" },
                helperPath,
                outputPath,
            ),
        )
        assertFalse(RootCaptureGuardPolicy.commandMatches(args.dropLast(1), helperPath, outputPath))
        assertFalse(RootCaptureGuardPolicy.commandMatches(emptyList(), helperPath, outputPath))
    }

    @Test
    fun executableIdentityAcceptsOnlyExactPathOrDeletedSuffix() {
        assertTrue(RootCaptureGuardPolicy.exeMatches(helperPath, helperPath))
        assertTrue(RootCaptureGuardPolicy.exeMatches("$helperPath (deleted)", helperPath))
        assertFalse(RootCaptureGuardPolicy.exeMatches("/system/bin/tcpdump", helperPath))
        assertFalse(RootCaptureGuardPolicy.exeMatches(null, helperPath))
    }

    @Test
    fun processIdentityNeverInfersDeathFromUnknownFacts() {
        val record = journal()
        val aliveFacts = RootCaptureGuardPolicy.ProcessFacts(
            present = true,
            startTicks = record.helperStartTicks,
            exe = helperPath,
            cmdline = listOf(helperPath, "-i", "any", "-s", "65535", "-w", outputPath, "-U"),
        )
        assertEquals(
            RootCaptureGuardPolicy.ProcessIdentity.ALIVE,
            RootCaptureGuardPolicy.identity(record, aliveFacts, record.bootId),
        )
        assertEquals(
            RootCaptureGuardPolicy.ProcessIdentity.ALIVE,
            RootCaptureGuardPolicy.identity(
                record,
                aliveFacts.copy(exe = "$helperPath (deleted)"),
                record.bootId,
            ),
        )
        assertEquals(
            RootCaptureGuardPolicy.ProcessIdentity.DEAD,
            RootCaptureGuardPolicy.identity(
                record,
                aliveFacts.copy(present = false),
                record.bootId,
            ),
        )
        assertEquals(
            RootCaptureGuardPolicy.ProcessIdentity.DEAD,
            RootCaptureGuardPolicy.identity(record, aliveFacts, "different-boot"),
        )
        assertEquals(
            RootCaptureGuardPolicy.ProcessIdentity.DEAD,
            RootCaptureGuardPolicy.identity(
                record,
                aliveFacts.copy(startTicks = 8888L),
                record.bootId,
            ),
        )
        assertEquals(
            RootCaptureGuardPolicy.ProcessIdentity.UNPROVEN,
            RootCaptureGuardPolicy.identity(
                record,
                aliveFacts.copy(startTicks = null),
                record.bootId,
            ),
        )
        assertEquals(
            RootCaptureGuardPolicy.ProcessIdentity.MISMATCH,
            RootCaptureGuardPolicy.identity(
                record,
                aliveFacts.copy(exe = "/system/bin/tcpdump"),
                record.bootId,
            ),
        )
        assertEquals(
            RootCaptureGuardPolicy.ProcessIdentity.MISMATCH,
            RootCaptureGuardPolicy.identity(
                record,
                aliveFacts.copy(cmdline = aliveFacts.cmdline.dropLast(1)),
                record.bootId,
            ),
        )
    }

    @Test
    fun guardManifestRequiresAllBuildHashes() {
        assertEquals("floe.root-capture-helper.v2", RootCaptureHelper.SCHEMA)
        assertEquals("floe.capture-guard.v1", RootCaptureHelper.GUARD_SCHEMA)
        assertNull(
            RootCaptureHelper.guardProblem(
                RootCaptureGuardPolicy.GUARD_SCHEMA,
                1,
                "arm64-v8a",
                "b".repeat(64),
                "c".repeat(64),
                "d".repeat(64),
            ),
        )
        assertNotNull(
            RootCaptureHelper.guardProblem("other", 1, "arm64-v8a", "b".repeat(64), "c".repeat(64), "d".repeat(64)),
        )
        assertNotNull(
            RootCaptureHelper.guardProblem(RootCaptureGuardPolicy.GUARD_SCHEMA, 2, "arm64-v8a", "b".repeat(64), "c".repeat(64), "d".repeat(64)),
        )
        assertNotNull(
            RootCaptureHelper.guardProblem(RootCaptureGuardPolicy.GUARD_SCHEMA, 1, "x86_64", "b".repeat(64), "c".repeat(64), "d".repeat(64)),
        )
        assertNotNull(
            RootCaptureHelper.guardProblem(RootCaptureGuardPolicy.GUARD_SCHEMA, 1, "arm64-v8a", "b".repeat(63), "c".repeat(64), "d".repeat(64)),
        )
    }
}
