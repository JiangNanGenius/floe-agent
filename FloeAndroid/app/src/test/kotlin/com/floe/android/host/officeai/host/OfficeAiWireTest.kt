// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import java.util.UUID
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Ticket-grammar regressions for the Office AI host wire (Main host20,
 * AUTHORED NOTRUN — Main runs the composed batch). The parser mirrors the
 * delivered Swift authority (`OfficeAIHostContract.swift` closed allowlists +
 * the fixed Main Amendment/2 ADDITIVE verify keys, terminal shared-19):
 * a key outside the set, a non-string value, a control char, an over-budget
 * descriptor or an epoch mismatch must refuse the WHOLE ticket and can never
 * be silently tolerated. Also pins the bounded reply envelopes and the
 * Amendment/2 literal codec.
 */
class OfficeAiWireTest {

    private val epoch = 77L
    private val task = UUID.randomUUID().toString()
    private val workspace = UUID.randomUUID().toString()
    private val sessionToken = "sess-0123456789abcdef"

    private fun json(pairs: List<Pair<String, String>>): ByteArray =
        pairs.joinToString(",", "{", "}") { (k, v) -> "\"$k\":\"$v\"" }.toByteArray(Charsets.UTF_8)

    private fun json(vararg pairs: Pair<String, String>): ByteArray = json(pairs.toList())

    private fun parse(bytes: ByteArray): OfficeAiWire.Ticket =
        OfficeAiWire.parseDescriptor(bytes, epoch)

    private fun refusal(bytes: ByteArray): String = try {
        OfficeAiWire.parseDescriptor(bytes, epoch)
        "accepted"
    } catch (r: OfficeAiWire.Refusal) {
        r.code
    }

    // ---- closed allowlists ----

    @Test
    fun lookupAcceptsExactRealm() {
        val ticket = parse(json(
            "operation" to "office.lookup", "epoch" to "$epoch", "taskID" to task,
            "workspaceID" to workspace, "workspacePresent" to "exact", "nativeEpoch" to "$epoch",
        ))
        assertEquals("office.lookup", ticket.operation)
        assertEquals(workspace, ticket.required("workspaceID"))
    }

    @Test
    fun lookupAbsentRealmRejectsWorkspaceIdKey() {
        assertEquals("internal", refusal(json(
            "operation" to "office.lookup", "epoch" to "$epoch", "taskID" to task,
            "workspacePresent" to "absent", "workspaceID" to workspace, "nativeEpoch" to "$epoch",
        )))
        parse(json(
            "operation" to "office.lookup", "epoch" to "$epoch", "taskID" to task,
            "workspacePresent" to "absent", "nativeEpoch" to "$epoch",
        ))
    }

    @Test
    fun unknownKeyRefusesWholeTicket() {
        // The mailbox should never send this; if it does, NOTHING dispatches.
        assertEquals("internal", refusal(json(
            "operation" to "office.lookup", "epoch" to "$epoch", "taskID" to task,
            "workspacePresent" to "absent", "nativeEpoch" to "$epoch", "sneaky" to "x",
        )))
    }

    @Test
    fun nonStringOrControlValueRefuses() {
        assertEquals("internal", refusal(
            ("""{"operation":"office.lookup","epoch":"$epoch","taskID":"$task",""" +
                """"workspacePresent":"absent","nativeEpoch":"$epoch","x":1}""")
                .toByteArray(Charsets.UTF_8),
        ))
        assertEquals("internal", refusal(json(
            "operation" to "office.lookup", "epoch" to "$epoch", "taskID" to task,
            "workspacePresent" to "absent", "nativeEpoch" to "$epoch", "x" to "line\nbreak",
        )))
    }

    @Test
    fun epochMismatchIsGenerationFenced() {
        assertEquals("generationFenced", refusal(json(
            "operation" to "office.lookup", "epoch" to "76", "taskID" to task,
            "workspacePresent" to "absent", "nativeEpoch" to "76",
        )))
    }

    @Test
    fun overBudgetDescriptorRefuses() {
        val big = ByteArray(OfficeAiWire.MAX_DESCRIPTOR_BYTES + 1) { 'a'.code.toByte() }
        assertEquals("internal", refusal(big))
    }

    // ---- command grammar ----

    private fun commandJson(action: String, vararg extra: Pair<String, String>): ByteArray =
        json(
            listOf(
                "operation" to "office.command", "epoch" to "$epoch",
                "sessionToken" to sessionToken, "generation" to "7",
                "opId" to "apply-1-abc", "action" to action, "taskID" to task,
            ) + extra.toList(),
        )

    @Test
    fun captureTargetAcceptedApplyTextRequiresHandle() {
        parse(commandJson("captureTarget"))
        assertEquals("internal", refusal(commandJson("applyText")))
        parse(commandJson("applyText", "targetHandle" to "0123456789abcdef0123456789abcdef"))
    }

    @Test
    fun setCellContentRequiresCellKindAndHandle() {
        assertEquals("internal", refusal(commandJson("setCellContent")))
        parse(commandJson(
            "setCellContent", "targetHandle" to "0123456789abcdef0123456789abcdef",
            "cellAddress" to "B7", "contentKind" to "number",
        ))
        assertEquals("internal", refusal(commandJson(
            "setCellContent", "targetHandle" to "0123456789abcdef0123456789abcdef",
            "cellAddress" to "B7", "contentKind" to "bogus",
        )))
    }

    @Test
    fun actionFieldCrossRules() {
        // applyText carries no cell/kind fields; queries carry no handle.
        assertEquals("internal", refusal(commandJson(
            "applyText", "targetHandle" to "0123456789abcdef0123456789abcdef",
            "cellAddress" to "B7",
        )))
        assertEquals("internal", refusal(commandJson(
            "queryTextSelection", "targetHandle" to "0123456789abcdef0123456789abcdef",
        )))
        assertEquals("internal", refusal(commandJson("notAnAction"))
        )
    }

    // ---- save grammar ----

    @Test
    fun saveFlushRejectsFormatExportRequiresFormat() {
        val base = listOf(
            "operation" to "office.save", "epoch" to "$epoch",
            "sessionToken" to sessionToken, "generation" to "7",
            "opId" to "flush-1-abc",
        )
        parse(json(base + listOf("saveOperation" to "flush")))
        assertEquals("internal", refusal(json(base + listOf(
            "saveOperation" to "flush", "format" to "docx",
        ))))
        parse(json(base + listOf(
            "saveOperation" to "export", "format" to "docx", "suggestedName" to "copy.docx",
        )))
        assertEquals("internal", refusal(json(base + listOf(
            "saveOperation" to "export", "format" to "odt",
        ))))
        assertEquals("internal", refusal(json(base + listOf(
            "saveOperation" to "export", "format" to "docx",
            "suggestedName" to "nested/name.docx",
        ))))
    }

    // ---- verify grammar incl the fixed Amendment/2 additions ----

    private fun verifyJson(vararg extra: Pair<String, String>): ByteArray = json(
        listOf(
            "operation" to "office.verify", "epoch" to "$epoch",
            "path" to "/data/user/0/com.floe.android/no_backup/floe-office-outputs/7/abc-1.docx",
            "sha256" to "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "format" to "docx", "expectCommand" to "applyText",
        ) + extra.toList(),
    )

    @Test
    fun verifyRequiresModeAndOwnedProofKeys() {
        assertEquals("semanticNotInspected", refusal(verifyJson()))
        parse(verifyJson("verificationMode" to "reconcile",
            "effectOpId" to "seed-apply-1", "exportOpId" to "seed-export-1"))
        // liveEffect needs the full owned identity.
        assertEquals("internal", refusal(verifyJson("verificationMode" to "liveEffect")))
        parse(verifyJson(
            "verificationMode" to "liveEffect", "effectOpId" to "seed-apply-1",
            "exportOpId" to "seed-export-1", "sessionToken" to sessionToken,
            "generation" to "7", "targetHandle" to "0123456789abcdef0123456789abcdef",
            "taskID" to task, "preEditSha256" to "0".repeat(64),
        ))
    }

    @Test
    fun verifyForeignKeysRefused() {
        // "sheetName" (a filename ordinal guess) is NOT part of the contract:
        // the logical index travels in expectPartIndex resolved from capture.
        assertEquals("internal", refusal(verifyJson(
            "verificationMode" to "reconcile", "effectOpId" to "a", "exportOpId" to "b",
            "sheetName" to "Sheet1",
        )))
    }

    @Test
    fun verifyXlsxSetCellRequiresPartIndex() {
        val base = listOf(
            "operation" to "office.verify", "epoch" to "$epoch",
            "path" to "/data/user/0/com.floe.android/no_backup/floe-office-outputs/7/a.xlsx",
            "sha256" to "0".repeat(64), "format" to "xlsx",
            "expectCommand" to "setCellContent", "cellAddress" to "A1", "contentKind" to "literal",
            "verificationMode" to "reconcile", "effectOpId" to "a", "exportOpId" to "b",
        )
        assertEquals("structureInvalid", refusal(json(base)))
        parse(json(base + listOf("expectPartIndex" to "1")))
    }

    @Test
    fun verifyDigestAndOpIdGrammar() {
        assertEquals("internal", refusal(json(
            listOf(
                "operation" to "office.verify", "epoch" to "$epoch",
                "path" to "/x/a.docx", "sha256" to "nothex",
                "format" to "docx", "expectCommand" to "applyText",
                "verificationMode" to "reconcile", "effectOpId" to "a", "exportOpId" to "b",
            ),
        )))
    }

    // ---- reconcile / pushOriginal grammar ----

    @Test
    fun reconcileAcceptsExactOpIdGrammar() {
        parse(json(
            "operation" to "office.reconcile", "epoch" to "$epoch",
            "exportOpId" to "seed-export-1_a", "format" to "pptx",
        ))
        assertEquals("internal", refusal(json(
            "operation" to "office.reconcile", "epoch" to "$epoch",
            "exportOpId" to "bad op", "format" to "pptx",
        )))
        assertEquals("internal", refusal(json(
            "operation" to "office.reconcile", "epoch" to "$epoch",
            "exportOpId" to "ok-1", "format" to "pdf",
        )))
    }

    @Test
    fun pushOriginalPathGrammar() {
        parse(json(
            "operation" to "office.pushOriginal", "epoch" to "$epoch", "taskID" to task,
            "workspaceID" to workspace, "nativeEpoch" to "$epoch",
            "logicalPath" to "reports/q4.xlsx",
        ))
        // Absolute escapes and traversal refuse the whole ticket.
        assertEquals("internal", refusal(json(
            "operation" to "office.pushOriginal", "epoch" to "$epoch", "taskID" to task,
            "workspaceID" to workspace, "nativeEpoch" to "$epoch",
            "logicalPath" to "/etc/passwd",
        )))
        assertEquals("internal", refusal(json(
            "operation" to "office.pushOriginal", "epoch" to "$epoch", "taskID" to task,
            "workspaceID" to workspace, "nativeEpoch" to "$epoch",
            "logicalPath" to "a/../../b.docx",
        )))
        // Non-OOXML extension refuses as an unsupported family, before any lane.
        assertEquals("unsupportedFamily", refusal(json(
            "operation" to "office.pushOriginal", "epoch" to "$epoch", "taskID" to task,
            "workspaceID" to workspace, "nativeEpoch" to "$epoch",
            "logicalPath" to "a.txt",
        )))
    }

    // ---- staged payload rules ----

    @Test
    fun stagedRulesPerOperation() {
        val lookup = parse(json(
            "operation" to "office.lookup", "epoch" to "$epoch", "taskID" to task,
            "workspacePresent" to "absent", "nativeEpoch" to "$epoch",
        ))
        assertEquals(OfficeAiWire.Stage.NONE, OfficeAiWire.stageFor(lookup.operation, lookup.fields))
        val apply = parse(commandJson("applyText",
            "targetHandle" to "0123456789abcdef0123456789abcdef"))
        assertEquals(OfficeAiWire.Stage.REQUIRED, OfficeAiWire.stageFor(apply.operation, apply.fields))
        // A query command must NOT carry staged bytes: whole-ticket refusal.
        val query = parse(commandJson("queryTextSelection"))
        assertEquals("internal", run {
            try {
                OfficeAiWire.decodeStaged("unexpected".toByteArray(), query); "accepted"
            } catch (r: OfficeAiWire.Refusal) { r.code }
        })
        // Missing staged bytes for an apply: refusal, never an empty effect.
        assertEquals("internal", run {
            try {
                OfficeAiWire.decodeStaged(ByteArray(0), apply); "accepted"
            } catch (r: OfficeAiWire.Refusal) { r.code }
        })
        // Over the engine content cap: typed requestTooLarge (never truncated).
        assertEquals("requestTooLarge", run {
            try {
                OfficeAiWire.decodeStaged(ByteArray(OfficeAiWire.MAX_APPLY_TEXT_BYTES + 1), apply)
                "accepted"
            } catch (r: OfficeAiWire.Refusal) { r.code }
        })
        val text = OfficeAiWire.decodeStaged("hello".toByteArray(Charsets.UTF_8), apply)
        assertEquals("hello", text)
    }

    // ---- bounded reply envelopes ----

    @Test
    fun failureEnvelopeBounded() {
        val longDetail = "d".repeat(5000)
        val bytes = OfficeAiWire.failureBytes("verificationFailed", longDetail)
        assertTrue(bytes.size <= OfficeAiWire.MAX_FAILURE_REPLY_BYTES)
        val decoded = String(bytes, Charsets.UTF_8)
        assertTrue(decoded.contains("\"code\":\"verificationFailed\""))
        assertTrue(decoded.contains("\"detail\""))
        val hugeCode = OfficeAiWire.failureBytes("x".repeat(200), null)
        assertTrue(hugeCode.size <= OfficeAiWire.MAX_FAILURE_REPLY_BYTES)
    }

    @Test
    fun oversizedSuccessBecomesTypedFailureNeverTruncation() {
        val huge = "s".repeat(400_000)
        val settlement = OfficeAiWire.successReply {
            put("blob", huge); put("blob2", huge); put("blob3", huge); put("blob4", huge)
        }
        assertTrue(settlement is OfficeAiWire.Settlement.Failure)
        assertEquals("answerTooLarge", (settlement as OfficeAiWire.Settlement.Failure).code)
    }

    @Test
    fun camelTokenMapping() {
        assertEquals("applyConflict", OfficeAiWire.camelToken("APPLY_CONFLICT"))
        assertEquals("mountEndedWithoutAck", OfficeAiWire.camelToken("MOUNT_ENDED_WITHOUT_ACK"))
        assertEquals("staleAckQuarantine", OfficeAiWire.camelToken("STALE_ACK_QUARANTINE"))
        assertEquals("flushAlreadyInFlight", OfficeAiWire.camelToken("FLUSH_ALREADY_IN_FLIGHT"))
        assertEquals("internal", OfficeAiWire.camelToken("INTERNAL"))
    }

    // ---- Amendment/2 literal codec ----

    /**
     * Main's exact ruling (2026-10-27): EXACT-STRING literal intent cannot
     * be served by a locale-free reinterpret guess list (dates `2026-10-27`,
     * `1/2`, times `12:30`, locale decimal/currency shapes all risk
     * reinterpretation), so the settled native apostrophe codec prefixes
     * EVERY non-empty literal, and the case/bytes of the wanted value are
     * preserved exactly (`true` stays lowercase, never `TRUE`). The verifier
     * contract always receives the RAW original string.
     */
    @Test
    fun literalCodecAlwaysForEveryNonEmptyLiteral() {
        assertEquals("'hello", OfficeAiWire.encodeNativeLiteral("hello"))
        assertEquals("'=SUM(A1:A2)", OfficeAiWire.encodeNativeLiteral("=SUM(A1:A2)"))
        assertEquals("'00123", OfficeAiWire.encodeNativeLiteral("00123"))
        assertEquals("'+7", OfficeAiWire.encodeNativeLiteral("+7"))
        assertEquals("'-5", OfficeAiWire.encodeNativeLiteral("-5"))
        // Case must remain lowercase: exact-string intent.
        assertEquals("'true", OfficeAiWire.encodeNativeLiteral("true"))
        assertEquals("'False", OfficeAiWire.encodeNativeLiteral("False"))
        // Date/time-shaped and locale currency literals are exactly covered.
        assertEquals("'2026-10-27", OfficeAiWire.encodeNativeLiteral("2026-10-27"))
        assertEquals("'1/2", OfficeAiWire.encodeNativeLiteral("1/2"))
        assertEquals("'12:30", OfficeAiWire.encodeNativeLiteral("12:30"))
        assertEquals("'$1,234.56", OfficeAiWire.encodeNativeLiteral("\$1,234.56"))
        // A literal leading apostrophe survives as part of the value via the
        // double-prefix rule (typing ''x yields the string 'x).
        assertEquals("''x", OfficeAiWire.encodeNativeLiteral("'x"))
        // Empty text is never dispatched as a literal anyway (engine rejects
        // empty content); the codec leaves it untouched.
        assertEquals("", OfficeAiWire.encodeNativeLiteral(""))
        assertTrue(OfficeAiWire.literalUsesCodec("hello"))
        assertTrue(OfficeAiWire.literalUsesCodec("00123"))
    }
}
