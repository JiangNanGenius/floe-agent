// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Test

class ConversationApprovalGenerationTest {
    private val conversation = "11111111-1111-4111-8111-111111111111"
    private val run = "22222222-2222-4222-8222-222222222222"
    private val generation = "33333333-3333-4333-8333-333333333333"
    private val descriptor = "a".repeat(64)

    private fun page(
        gen: String = generation,
        revision: String = "generation:$gen",
        tool: String = "device.act",
        presentationGen: String = gen,
        details: String = """{"action":"back"}""",
        detailStatus: String = "available",
        workspaceVerified: Boolean = false,
        risks: String = "[]",
    ): ConversationWire.SnapshotPage {
        val json = """{"conversationID":"$conversation","runID":"$run","durableState":"waitingApproval",
          "revision":{"resourceID":"run.$run","version":"waitingApproval"},"isTerminal":false,
          "liveOwner":true,"durableWatermark":10,"pendingInputs":[],
          "pendingApproval":{"callID":"c1","tool":"$tool","reason":"Review","requestedAt":"2026-01-01T00:00:00Z",
          "generation":"$gen","presentation":{"status":"available","generation":"$presentationGen","tool":"$tool",
          "effect":"mutating","isSideEffecting":true,"riskLabels":$risks,"requestedScope":"local",
          "grantScope":"singleUse","workspaceVerified":$workspaceVerified,"descriptorIdentity":"$descriptor",
          "detailStatus":"$detailStatus","actionDetails":$details}},
          "approvalRevision":{"resourceID":"approval.c1","version":"$revision"}}"""
        return requireNotNull(ConversationWire.decodeSnapshotPage(Json.parseToJsonElement(json)))
    }

    private fun builder() = ThreadProjectionBuilder(conversation).apply { selectedRunId = run }

    @Test fun exactActionAndPackageComeOnlyFromSameGenerationSnapshot() {
        val builder = builder()
        builder.applySnapshot(page(details = """{"action":"launch","packageName":"org.example.editor"}"""))
        val card = builder.build().pendingApprovals.single()
        assertTrue(card.identityVerified)
        assertTrue(card.scopeVerified)
        assertEquals("launch", card.actionKind)
        assertEquals("org.example.editor", card.actionPackage)
        assertEquals("generation:$generation", card.approvalRevision)
        assertEquals(card, builder.approvalBinding(run, "c1"))
    }

    @Test fun incompleteOrUnboundDetailsNeverAuthorizeAllow() {
        val pages = listOf(
            page(presentationGen = "44444444-4444-4444-8444-444444444444"),
            page(revision = "2026-01-01T00:00:00Z"),
            page(detailStatus = "unavailable"),
            page(details = """{"action":"launch","packageName":"org.example.app","extra":"x"}"""),
            page(tool = "workspace.writeFile"),
        )
        for (snapshot in pages) {
            val builder = builder()
            builder.applySnapshot(snapshot)
            assertFalse(builder.build().pendingApprovals.single().scopeVerified)
        }
    }

    @Test fun unversionedEventsCannotSupplyScopeOrRetireCurrentGeneration() {
        val builder = builder()
        val frame = HostRunEventFrame(runID = run, sequence = 5, kind = "approval",
            payload = Json.parseToJsonElement("""{"callID":"c1","tool":"device.act","scope":"other-app"}""").jsonObject,
            bytes = 0)
        builder.applyRunEvent(frame)
        assertTrue(builder.build().pendingApprovals.isEmpty())
        builder.applySnapshot(page())
        val card = builder.build().pendingApprovals.single()
        builder.applyRunEvent(frame.copy(sequence = 11,
            payload = Json.parseToJsonElement("""{"callID":"c1","outcome":"allowed"}""").jsonObject))
        assertEquals(card, builder.build().pendingApprovals.single())
    }

    @Test fun snapshotsAreImmutableAcrossGenerationChanges() {
        val builder = builder()
        builder.applySnapshot(page())
        val first = builder.build()
        val replacement = "44444444-4444-4444-8444-444444444444"
        builder.applySnapshot(page(gen = replacement))
        assertEquals(generation, first.pendingApprovals.single().requestGeneration)
        assertEquals(replacement, builder.build().pendingApprovals.single().requestGeneration)
    }

    private fun filePage(tool: String, details: String, verified: Boolean = true) = page(
        tool = tool, details = details, workspaceVerified = verified, risks = """["writesFiles"]"""
    )

    @Test fun fileActionsCarryCompleteBoundPathsAndPreconditions() {
        val samples = listOf(
            "workspace.createFile" to """{"kind":"workspaceFile","workspaceID":"$conversation","operation":"createFile","target":"notes/new.txt","source":"inline","overwrite":"forbidden","precondition":"none"}""",
            "workspace.createFile" to """{"kind":"workspaceFile","workspaceID":"$conversation","operation":"createFile","target":"notes/existing.txt","source":"inline","overwrite":"allowed","precondition":"none"}""",
            "workspace.writeFile" to """{"kind":"workspaceFile","workspaceID":"$conversation","operation":"writeFile","target":"notes/existing.txt","source":"inline","overwrite":"allowed","precondition":"none"}""",
            "workspace.writeFile" to """{"kind":"workspaceFile","workspaceID":"$conversation","operation":"writeFile","target":"notes/existing.txt","source":"inline","overwrite":"conditional","precondition":"sha256"}""",
            "workspace.writeFile" to """{"kind":"workspaceFile","workspaceID":"$conversation","operation":"writeFile","target":"notes/existing.txt","source":"inline","overwrite":"conditional","precondition":"mtime"}""",
            "workspace.writeFile" to """{"kind":"workspaceFile","workspaceID":"$conversation","operation":"writeFile","target":"notes/existing.txt","source":"inline","overwrite":"conditional","precondition":"sha256AndMtime"}""",
            "workspace.writeFile" to """{"kind":"workspaceFile","workspaceID":"$conversation","operation":"writeFile","target":"notes/final.txt","source":"workspaceFile","overwrite":"forbidden","precondition":"none","sourcePath":"draft/large.txt","sourcePrecondition":"sha256"}""",
            "workspace.writeFile" to """{"kind":"workspaceFile","workspaceID":"$conversation","operation":"writeFile","target":"notes/final.txt","source":"workspaceFile","overwrite":"conditional","precondition":"sha256","sourcePath":"draft/large.txt","sourcePrecondition":"sha256"}""",
            "workspace.applyPatch" to """{"kind":"workspaceFile","workspaceID":"$conversation","operation":"applyPatch","target":"notes/existing.txt","source":"patch","overwrite":"conditional","precondition":"patchContext"}""",
        )
        for ((tool, details) in samples) {
            val parsed = requireNotNull(workspaceApprovalDetails(tool, Json.parseToJsonElement(details).jsonObject))
            assertEquals(conversation, parsed.workspaceId)
            assertEquals(tool.removePrefix("workspace."), parsed.operation)
            assertTrue(parsed.targetPath.startsWith("notes/"))
            assertFalse(parsed.toString().contains(parsed.targetPath))
            parsed.sourcePath?.let { assertFalse(parsed.toString().contains(it)) }
            val builder = builder()
            builder.applySnapshot(filePage(tool, details))
            val card = builder.build().pendingApprovals.single()
            // A general snapshot is not yet a privacy-authorized human-only
            // channel, even when its fields are structurally complete.
            assertFalse(card.scopeVerified)
            assertNull(card.workspaceAction)
            assertEquals(card, builder.approvalBinding(run, "c1"))
        }
        val unicode = builder()
        val chinese = """{"kind":"workspaceFile","workspaceID":"$conversation","operation":"createFile","target":"项目/会议纪要.md","source":"inline","overwrite":"forbidden","precondition":"none"}"""
        val parsedChinese = workspaceApprovalDetails("workspace.createFile", Json.parseToJsonElement(chinese).jsonObject)
        assertEquals("项目/会议纪要.md", parsedChinese?.targetPath)
        unicode.applySnapshot(filePage("workspace.createFile", chinese))
        assertFalse(unicode.build().pendingApprovals.single().scopeVerified)
    }

    @Test fun invalidFileDetailsRemainDeniableButCannotBeAllowed() {
        val base = """{"kind":"workspaceFile","workspaceID":"$conversation","operation":"writeFile","target":"notes/file.txt","source":"inline","overwrite":"allowed","precondition":"none"}"""
        val malformed = listOf(
            base.replace("notes/file.txt", "../escape"),
            base.replace("notes/file.txt", "Network/server/file"),
            base.replace("notes/file.txt", "Mounts/folder/file"),
            base.replace("notes/file.txt", "${"a".repeat(257)}"),
            base.replace("notes/file.txt", "notes/\\nfile"),
            base.replace("notes/file.txt", "notes/\\u202efoo.txt"),
            base.replace("notes/file.txt", "notes/\\u200bfoo.txt"),
            base.replace("\"overwrite\":\"allowed\"", "\"overwrite\":\"forbidden\""),
            base.replace("\"precondition\":\"none\"", "\"precondition\":\"sha256\""),
            base.replace("\"source\":\"inline\"", "\"source\":\"workspaceFile\""),
            base.replace(conversation, "NOT-A-WORKSPACE"),
            base.dropLast(1) + ",\"content\":\"secret\"}",
            base.replace("writeFile", "createFile"),
        )
        for (details in malformed) {
            assertNull(workspaceApprovalDetails("workspace.writeFile", Json.parseToJsonElement(details).jsonObject))
            val builder = builder()
            builder.applySnapshot(filePage("workspace.writeFile", details))
            val card = builder.build().pendingApprovals.single()
            assertTrue(card.identityVerified)
            assertFalse(card.scopeVerified)
            assertNull(card.workspaceAction)
        }
        val unverified = builder()
        unverified.applySnapshot(filePage("workspace.writeFile", base, verified = false))
        assertFalse(unverified.build().pendingApprovals.single().scopeVerified)
    }
    @Test fun privateFilePageMustMatchOwnerGenerationDescriptorAndToken() {
        val details = """{"kind":"workspaceFile","workspaceID":"$conversation","operation":"createFile","target":"项目/结果.txt","source":"inline","overwrite":"forbidden","precondition":"none"}"""
        val builder = builder()
        builder.applySnapshot(filePage("workspace.createFile", details, verified = false))
        val card = builder.build().pendingApprovals.single()
        val token = "55555555-5555-4555-8555-555555555555"
        val raw = """{"schema":"floe.approval-presentation/1","conversationID":"$conversation","runID":"$run","callID":"c1","generation":"$generation","presentationToken":"$token","presentation":{"status":"available","generation":"$generation","tool":"workspace.createFile","effect":"mutating","isSideEffecting":true,"riskLabels":["writesFiles"],"requestedScope":"local","grantScope":"singleUse","workspaceVerified":true,"descriptorIdentity":"$descriptor","detailStatus":"available","actionDetails":$details}}"""
        val accepted = requireNotNull(privateWorkspaceApprovalPage(Json.parseToJsonElement(raw), card))
        assertEquals("项目/结果.txt", accepted.first.targetPath)
        assertEquals(token, accepted.second)
        for (bad in listOf(
            raw.replace("\"runID\":\"$run\"", "\"runID\":\"$conversation\""),
            raw.replace("\"callID\":\"c1\"", "\"callID\":\"c2\""),
            raw.replace(descriptor, "b".repeat(64)),
            raw.replace(token, "invalid"),
            raw.replace("\"workspaceVerified\":true", "\"workspaceVerified\":false"),
            raw.replace("\"target\":\"项目/结果.txt\"", "\"target\":\"../secret\""),
        )) assertNull(privateWorkspaceApprovalPage(Json.parseToJsonElement(bad), card))
    }

    @Test fun privateLocalShellPageRequiresFullExactTrustedAction() {
        val builder = builder()
        builder.applySnapshot(page(tool = "exec.shell", detailStatus = "unavailable", risks = """["writesFiles"]"""))
        val card = builder.build().pendingApprovals.single()
        val token = "55555555-5555-4555-8555-555555555555"
        val command = "printf hello\\nprintf world"
        val raw = """{"schema":"floe.approval-presentation/1","conversationID":"$conversation","runID":"$run","callID":"c1","generation":"$generation","presentationToken":"$token","presentation":{"status":"available","generation":"$generation","tool":"exec.shell","effect":"mutating","isSideEffecting":true,"riskLabels":["writesFiles"],"requestedScope":"local","grantScope":"singleUse","workspaceVerified":true,"descriptorIdentity":"$descriptor","detailStatus":"available","actionDetails":{"kind":"localShell","target":"localLinux","environmentID":"env-one","workspaceID":"$conversation","targetRevision":2,"command":"$command","cwd":".","timeoutSeconds":10.0,"maxOutputBytes":65536,"environmentTransaction":false}}}"""
        fun decode(value: String) = privateLocalShellApprovalPage(Json.parseToJsonElement(value), card)
        val result = requireNotNull(decode(raw))
        assertEquals("printf hello\nprintf world", result.first.command)
        assertEquals(".", result.first.cwd)
        assertEquals(10.0, result.first.timeoutSeconds, 0.0)
        assertEquals(65536, result.first.maxOutputBytes)
        assertEquals(token, result.second)
        assertFalse(result.first.toString().contains("printf"))
        for (bad in listOf(
            raw.replace("\"target\":\"localLinux\"", "\"target\":\"ssh\""),
            raw.replace("\"targetRevision\":2", "\"targetRevision\":0"),
            raw.replace("\"environmentID\":\"env-one\"", "\"environmentID\":\"\""),
            raw.replace("\"cwd\":\".\"", "\"cwd\":\"../escape\""),
            raw.replace("\"cwd\":\".\"", "\"cwd\":\"./ambiguous\""),
            raw.replace(command, "x".repeat(16385)),
            raw.replace(command, "echo \\u202esecret"),
            raw.replace("\"timeoutSeconds\":10.0", "\"timeoutSeconds\":0.01"),
            raw.replace("\"maxOutputBytes\":65536", "\"maxOutputBytes\":262145"),
            raw.replace("\"environmentTransaction\":false", "\"environmentTransaction\":\"false\""),
            raw.replace("\"kind\":\"localShell\"", "\"extra\":true,\"kind\":\"localShell\""),
            raw.replace(descriptor, "b".repeat(64)),
            raw.replace(token, "invalid"),
        )) assertNull(decode(bad))
    }

}
