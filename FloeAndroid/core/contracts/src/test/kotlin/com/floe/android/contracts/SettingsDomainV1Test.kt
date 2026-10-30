package com.floe.android.contracts

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.UUID

/**
 * JVM source tests for the settings-domain P0 Kotlin projection.
 *
 * Authored only in this package: no Gradle/JVM execution is claimed by the
 * source candidate. These tests mirror the Swift vocabulary semantics and the
 * canonical digest fixed vectors without opening a database or a network.
 */
class SettingsDomainV1Test {
    private fun failure(
        command: String,
        label: String,
        payload: Map<String, Any?>?,
        createIntent: Boolean = false,
        revisionPresent: Boolean = false,
    ): SettingsDomainV1.ValidationFailure? =
        SettingsDomainV1.validate(command, label, createIntent, revisionPresent, payload)

    @Test
    fun matrixHas95TuplesAnd19Labels() {
        // 90 accepted tuples + the five G07.3A interaction tuples. The first
        // 90 entries (including the G04 workspace ledger at the tail before
        // this batch) remain intact; the interaction tuples are appended.
        assertEquals(95, BridgeV3CommandMatrix.ENTRIES.size)
        val interactionCommands = listOf(
            "conversation.messageSearch", "conversation.messageWindow",
            "question.pending", "question.answer", "question.cancel",
        )
        assertEquals(
            interactionCommands,
            BridgeV3CommandMatrix.ENTRIES.takeLast(5).map { it.command },
        )
        for (command in interactionCommands) {
            val entry = BridgeV3CommandMatrix.ENTRIES.single { it.command == command }
            assertEquals(BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE, entry.scope)
            assertFalse(entry.revisionRequired)
            assertFalse(entry.allowsCreateIntent)
            assertNull(entry.configurationScope)
        }
        val workspaceCommands = listOf("workspace.read", "workspace.write", "workspace.activate")
        assertEquals(
            workspaceCommands,
            BridgeV3CommandMatrix.ENTRIES
                .filter { it.command in workspaceCommands }
                .map { it.command },
        )
        for (command in workspaceCommands) {
            val entry = BridgeV3CommandMatrix.ENTRIES.single { it.command == command }
            assertEquals(BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE, entry.scope)
            assertFalse(entry.revisionRequired)
            assertFalse(entry.allowsCreateIntent)
            assertNull(entry.configurationScope)
        }
        assertEquals(1, BridgeV3CommandMatrix.ENTRIES.count {
            it.command == "plan.accept" && it.scope == BridgeV3Scope.Kind.LAUNCH &&
                it.revisionRequired && !it.allowsCreateIntent
        })
        assertEquals(1, BridgeV3CommandMatrix.ENTRIES.count {
            it.command == "goal.confirm" &&
                it.scope == BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE &&
                it.revisionRequired && !it.allowsCreateIntent
        })
        assertEquals(1, BridgeV3CommandMatrix.ENTRIES.count {
            it.command == "conversation.compact" &&
                it.scope == BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE &&
                !it.revisionRequired
        })
        assertEquals(0, BridgeV3CommandMatrix.ENTRIES.count { it.command == "child.create" })
        assertEquals(19, BridgeProtocolV3.CONFIGURATION_SCOPES.size)
        assertEquals(SettingsDomainV1.LABELS.toSet(),
            BridgeProtocolV3.CONFIGURATION_SCOPES.takeLast(5).toSet())

        val newPairs = listOf(
            "config.defaults.get" to "settings.defaults",
            "config.defaults.save" to "settings.defaults",
            "memory.list" to "memory",
            "memory.get" to "memory",
            "memory.add" to "memory",
            "memory.update" to "memory",
            "memory.delete" to "memory",
            "memory.delete.bulk" to "memory",
            "memory.search" to "memory",
            "memory.candidates.list" to "memory",
            "memory.candidate.resolve" to "memory",
            "memory.organize.start" to "memory",
            "memory.organize.proposal.read" to "memory",
            "memory.organize.apply" to "memory",
            "memory.organize.cancel" to "memory",
            "personalization.get" to "personalization",
            "personalization.revision.read" to "personalization",
            "personalization.save" to "personalization",
            "personalization.rollback" to "personalization",
            "personalization.automatic.set" to "personalization",
            "personalization.generate" to "personalization",
            "personalization.generate.cancel" to "personalization",
            "content.read" to "personalization",
            "usage.statistics.get" to "usage",
            "privacy.summary.get" to "privacy",
            "privacy.history.clear" to "privacy",
            "privacy.modelConfiguration.clear" to "privacy",
        )
        assertEquals(27, newPairs.size)
        for ((command, label) in newPairs) {
            assertEquals("missing $command/$label", 1,
                BridgeV3CommandMatrix.ENTRIES.count {
                    it.command == command && it.configurationScope == label
                })
        }
        assertEquals(3, BridgeV3CommandMatrix.ENTRIES.count { it.command == "content.read" })
        assertEquals(setOf("memory.add", "memory.delete.bulk", "memory.organize.start",
            "memory.organize.apply", "personalization.generate"),
            SettingsDomainV1.CREATE_ONLY_COMMANDS)
        for (reserved in listOf("credentials", "settings.approval", "operations")) {
            assertTrue(BridgeV3CommandMatrix.ENTRIES.none {
                it.configurationScope == reserved
            })
        }
    }

    @Test
    fun closedPayloadValidationMirrorsSwiftSemantics() {
        assertNull(failure("config.defaults.save", "settings.defaults",
            mapOf("values" to mapOf("defaultAgentMode" to "human")),
            revisionPresent = true))
        assertEquals("unknownDefaultsField",
            failure("config.defaults.save", "settings.defaults",
                mapOf("values" to mapOf("defaultAgentMode" to "human", "extra" to 1)),
                revisionPresent = true)?.reason)
        assertEquals("invalidDefaultsValue:defaultAgentMode",
            failure("config.defaults.save", "settings.defaults",
                mapOf("values" to mapOf("defaultAgentMode" to "god")),
                revisionPresent = true)?.reason)
        assertEquals("invalidDefaultsValue:verifyFinalAnswer",
            failure("config.defaults.save", "settings.defaults",
                mapOf("values" to mapOf("verifyFinalAnswer" to 1)),
                revisionPresent = true)?.reason)

        assertNull(failure("memory.list", "memory", emptyMap()))
        assertEquals("invalidPayloadField:isPinned",
            failure("memory.list", "memory", mapOf("isPinned" to null))?.reason)
        assertEquals("invalidPayloadField:isPinned",
            failure("memory.list", "memory", mapOf("isPinned" to 1))?.reason)
        assertEquals("payloadFieldOutOfRange:limit",
            failure("memory.list", "memory", mapOf("limit" to 0))?.reason)
        assertEquals("invalidPayloadField:limit",
            failure("memory.list", "memory", mapOf("limit" to 1.5))?.reason)
        assertEquals("invalidCursor",
            failure("memory.list", "memory", mapOf("cursor" to 12))?.reason)
        assertEquals("invalidPayloadField:id",
            failure("memory.get", "memory",
                mapOf("id" to "00000000-0000-0000-0000-000000000000"))?.reason)
        assertNull(failure("memory.get", "memory",
            mapOf("id" to "11111111-1111-1111-1111-111111111111")))

        assertNull(failure("memory.add", "memory",
            mapOf("content" to "hello", "scope" to mapOf("kind" to "user")),
            createIntent = true))
        assertEquals("invalidPayloadField:scope",
            failure("memory.add", "memory",
                mapOf("content" to "hello", "scope" to mapOf("kind" to "workspace")),
                createIntent = true)?.reason)
        assertEquals("invalidPayloadField:scope",
            failure("memory.add", "memory",
                mapOf("content" to "hello", "scope" to mapOf(
                    "kind" to "user",
                    "workspaceID" to "11111111-1111-1111-1111-111111111111")),
                createIntent = true)?.reason)

        val oversize = "x".repeat(24_001)
        val tooLarge = failure("personalization.save", "personalization",
            mapOf("kind" to "soul", "content" to oversize), revisionPresent = true)
        assertEquals("payloadTooLarge", tooLarge?.code)
        assertEquals("maxChars:24000", tooLarge?.reason)

        assertNull(failure("memory.update", "memory",
            mapOf(
                "id" to "11111111-1111-1111-1111-111111111111",
                "changes" to mutableMapOf<String, Any?>(
                    "expiresAt" to null, "factIdentity" to null,
                ),
            ),
            revisionPresent = true))
        assertEquals("invalidPayloadField:content",
            failure("memory.update", "memory",
                mapOf(
                    "id" to "11111111-1111-1111-1111-111111111111",
                    "changes" to mapOf("content" to null),
                ),
                revisionPresent = true)?.reason)
    }

    @Test
    fun usageDimensionUsesFrozenUnknownDimensionReason() {
        val invalid = listOf<Any?>(
            "everything", 7, 1.5, true, null,
            listOf("model"), mapOf("kind" to "model"),
        )
        for (value in invalid) {
            val failure = failure("usage.statistics.get", "usage",
                mapOf("dimension" to value))
            assertEquals("code for $value", "invalidEnvelope", failure?.code)
            assertEquals("reason for $value", "unknownDimension", failure?.reason)
        }
        assertNull(failure("usage.statistics.get", "usage", emptyMap()))
        for (valid in listOf("total", "conversation", "model", "provider")) {
            assertNull(failure("usage.statistics.get", "usage",
                mapOf("dimension" to valid, "limit" to 10)))
        }
        // Other domains keep the generic enum-field taxonomy.
        assertEquals("invalidPayloadField:status",
            failure("memory.list", "memory", mapOf("status" to "bogus"))?.reason)
        assertEquals("invalidPayloadField:status",
            failure("memory.update", "memory",
                mapOf(
                    "id" to "11111111-1111-1111-1111-111111111111",
                    "changes" to mapOf("status" to "bogus"),
                ),
                revisionPresent = true)?.reason)
    }

    @Test
    fun createOnlyPolicyAndBulkValidation() {
        assertEquals("createIntentRequired",
            failure("memory.add", "memory",
                mapOf("content" to "x", "scope" to mapOf("kind" to "user")))?.reason)
        assertEquals("createIntentRequired",
            failure("personalization.generate", "personalization",
                mapOf("kind" to "soul"))?.reason)
        assertEquals("revisionForNewIdentity",
            failure("memory.add", "memory",
                mapOf("content" to "x", "scope" to mapOf("kind" to "user")),
                createIntent = true, revisionPresent = true)?.reason)
        assertNull(failure("memory.organize.start", "memory",
            mapOf("mode" to "reviewFirst", "includeSemantic" to false),
            createIntent = true))

        val id = UUID.randomUUID().toString()
        val digest = "sha256:" + "a".repeat(64)
        val batch = mapOf(
            "batchID" to UUID.randomUUID().toString(),
            "entries" to listOf(mapOf("id" to id, "expectedDigest" to digest)),
            "syncRevision" to 0L,
        )
        assertNull(failure("memory.delete.bulk", "memory", batch, createIntent = true))
        val duplicate = mapOf(
            "batchID" to UUID.randomUUID().toString(),
            "entries" to listOf(
                mapOf("id" to id, "expectedDigest" to digest),
                mapOf("id" to id, "expectedDigest" to digest),
            ),
            "syncRevision" to 0L,
        )
        assertEquals("duplicateBatchEntry",
            failure("memory.delete.bulk", "memory", duplicate, createIntent = true)?.reason)

        assertNull(failure("content.read", "personalization",
            mapOf("handle" to "h-1", "offsetBytes" to 0, "maxBytes" to 32768)))
        assertEquals("invalidChunkRange",
            failure("content.read", "personalization",
                mapOf("handle" to "h-1", "offsetBytes" to 0, "maxBytes" to 0))?.reason)
    }

    @Test
    fun canonicalDigestFixedVectorsMatchSwift() {
        val domain = "floe.test-domain.v1"
        assertEquals("sha256:8e266dda37a34717f46567b34e7d01235be575ae642e5cace0c20d42d79ed040",
            SettingsDomainV1.CanonicalDigest.token(
                domain, listOf(listOf(SettingsDomainV1.CanonicalDigest.Field.Null))))
        assertEquals("sha256:c1cc1e8fc89341e28d2a3392b7f6c5d8122d5bab7c4949c458a2fa1001a3e14e",
            SettingsDomainV1.CanonicalDigest.token(
                domain, listOf(listOf(
                    SettingsDomainV1.CanonicalDigest.Field.Text("a\u001Fb")))))
        assertEquals("sha256:e82f2c03d0f48dd66637930c25c0e34e33e55b38c362b24b64e00e0e50c11463",
            SettingsDomainV1.CanonicalDigest.token(
                domain, listOf(listOf(
                    SettingsDomainV1.CanonicalDigest.Field.Text("a"),
                    SettingsDomainV1.CanonicalDigest.Field.Integer(1),
                    SettingsDomainV1.CanonicalDigest.Field.Real(1.0),
                ))))
        assertNotEquals(
            SettingsDomainV1.CanonicalDigest.token(
                domain, listOf(listOf(SettingsDomainV1.CanonicalDigest.Field.Real(-0.0)))),
            SettingsDomainV1.CanonicalDigest.token(
                domain, listOf(listOf(SettingsDomainV1.CanonicalDigest.Field.Real(0.0))))
        )
        // The encoder preserves caller order. Identity streams are sorted by
        // the caller (SQL ORDER BY); any construction order of the same
        // sorted stream digests equally, an unsorted stream does not.
        val records = listOf(
            listOf(SettingsDomainV1.CanonicalDigest.Field.Text("a"),
                SettingsDomainV1.CanonicalDigest.Field.Text("1")),
            listOf(SettingsDomainV1.CanonicalDigest.Field.Text("b"),
                SettingsDomainV1.CanonicalDigest.Field.Text("2")),
        )
        val byRawID = Comparator<List<SettingsDomainV1.CanonicalDigest.Field>> { lhs, rhs ->
            (lhs[0] as SettingsDomainV1.CanonicalDigest.Field.Text).value.compareTo(
                (rhs[0] as SettingsDomainV1.CanonicalDigest.Field.Text).value)
        }
        assertEquals(
            SettingsDomainV1.CanonicalDigest.token(domain, records.sortedWith(byRawID)),
            SettingsDomainV1.CanonicalDigest.token(
                domain, records.reversed().sortedWith(byRawID)),
        )
        assertNotEquals(
            SettingsDomainV1.CanonicalDigest.token(domain, records),
            SettingsDomainV1.CanonicalDigest.token(domain, records.reversed()),
        )
    }

    @Test
    fun canonicalDigestFinalContractVectorsMatchSwift() {
        val domain = "floe.test-domain.v1"
        fun token(vararg fields: SettingsDomainV1.CanonicalDigest.Field): String =
            SettingsDomainV1.CanonicalDigest.token(domain, listOf(fields.toList()))
        assertEquals("sha256:aed0060f828b6acf31240bc2b95a550a1ef217db9a858a4729bbc0984483dbda",
            token(SettingsDomainV1.CanonicalDigest.Field.Text("NULL")))
        assertEquals("sha256:5f037464bb245e468c7125156403b38992101d256b67969e7e402ad31583b6cd",
            token(SettingsDomainV1.CanonicalDigest.Field.Text("<null>")))
        assertEquals("sha256:d04a8ffdfeb150415c05a449cac3dae28715c483eb5d014c6f464a47b2400454",
            token(SettingsDomainV1.CanonicalDigest.Field.Text("")))
        assertEquals("sha256:ff873c5ad7ae6cf5f697bbe64a67d2fe88da84c756739173ee2c92474c6ebda5",
            token(SettingsDomainV1.CanonicalDigest.Field.Text("a|b")))
        assertEquals("sha256:2d76a1d92b3c479128fb1b652f1411826aad7b14fb0b49a3d59697661f32d1c4",
            token(SettingsDomainV1.CanonicalDigest.Field.Integer(1)))
        assertEquals("sha256:e407fd63c4efd9d63f718765355be2de2b692fa2190912aa39a7697329f387a9",
            token(SettingsDomainV1.CanonicalDigest.Field.Real(1.0)))
        assertEquals("sha256:678e97b738f918c00420f5e34c1e320fb5fb7a67aa6f8649a5ed06cd95bf9218",
            token(SettingsDomainV1.CanonicalDigest.Field.Text("1")))
        assertEquals("sha256:77557c230f4072b4493eaedee41e45f411ca04c7f8fa8b8f8b88e34a997b1760",
            token(SettingsDomainV1.CanonicalDigest.Field.Text("记忆 🧪")))
        assertEquals("sha256:1358515378e0289f3ae51bebeb3832f644636dc6fc2ea7288810012d477ab43d",
            token(SettingsDomainV1.CanonicalDigest.Field.Text("a\u0000b")))
        assertEquals("sha256:0833a1f65a014f8ec3eb42b9d2151d6c13a0b472a4fccbb81dad063e7ac35d59",
            token(SettingsDomainV1.CanonicalDigest.Field.Integer(Long.MIN_VALUE)))
        assertEquals("sha256:72207d1c815db4361ead204b47c3969062ae0ce73344c2c3fcf50f93dae8a814",
            token(SettingsDomainV1.CanonicalDigest.Field.Integer(Long.MAX_VALUE)))
        assertEquals("sha256:abc5fa1dd093f66909da2503c0045cab7bd059ce9dcccff2d8151b22969973f1",
            token(SettingsDomainV1.CanonicalDigest.Field.Real(-0.0)))
        assertEquals("sha256:8e1dac2bf944541404eed91460e7d00b02cb08593424fc8e1231149fa0615391",
            token(SettingsDomainV1.CanonicalDigest.Field.Real(0.0)))
        assertEquals("sha256:e9b33f8eb6a88ed572780774f83f58bcbcd5a88f89b5a7354453df08ec96eef3",
            SettingsDomainV1.CanonicalDigest.token(domain, emptyList()))
    }

    @Test
    fun matrixUniquenessIncludesConfigurationScope() {
        val entries = BridgeV3CommandMatrix.ENTRIES
        val keys = entries.map {
            "${it.scope.wire}|${it.configurationScope ?: ""}|${it.command}"
        }
        assertEquals(95, keys.toSet().size)
        assertEquals(57, entries.take(57).map {
            "${it.scope.wire}|${it.configurationScope ?: ""}|${it.command}"
        }.toSet().size)
        assertEquals(94, entries.map { "${it.scope.wire}|${it.command}" }.toSet().size)
        assertEquals(2, entries.count {
            it.scope == BridgeV3Scope.Kind.APPLICATION_CONFIGURATION &&
                it.command == "content.read"
        })
        assertEquals(95, entries.size)
        assertEquals(19, BridgeProtocolV3.CONFIGURATION_SCOPES.size)
    }

    @Test
    fun contentBudgetCountsCompleteEnvelopeAndEscaping() {
        fun responseBytes(content: String, contentBytes: Int): Int {
            val prefix = """{"active":{"content":"""
            val suffix = ""","contentBytes":$contentBytes,""" +
                """"id":"11111111-1111-1111-1111-111111111111","revision":3},""" +
                """"cursor":{"revision":"absent"},"latestRevision":3,"revisionsMeta":[]}"""
            return prefix.toByteArray(Charsets.UTF_8).size +
                SettingsDomainV1.ContentBudget.jsonEncodedStringBytes(content) +
                suffix.toByteArray(Charsets.UTF_8).size
        }
        val sample = "a\"b\n中文😀"
        val sampleBytes = sample.toByteArray(Charsets.UTF_8).size
        // `contentBytes` is final metadata; the metadata probe only empties
        // the content string itself.
        val metadata = responseBytes("", sampleBytes)
        assertEquals(metadata - 2 + SettingsDomainV1.ContentBudget.jsonEncodedStringBytes(sample),
            responseBytes(sample, sampleBytes))
        assertEquals(responseBytes(sample, sampleBytes),
            SettingsDomainV1.ContentBudget.encodedInlineResponseBytes(metadata, sample))
        assertTrue(SettingsDomainV1.ContentBudget.shouldInline(sample, metadata,
            responseBytes(sample, sampleBytes)))
        assertFalse(SettingsDomainV1.ContentBudget.shouldInline(sample, metadata,
            responseBytes(sample, sampleBytes) - 1))
        assertEquals(3, SettingsDomainV1.ContentBudget.jsonEncodedStringBytes("a"))
        assertEquals(4, SettingsDomainV1.ContentBudget.jsonEncodedStringBytes("\""))
        assertEquals(4, SettingsDomainV1.ContentBudget.jsonEncodedStringBytes("\n"))
        assertEquals(8, SettingsDomainV1.ContentBudget.jsonEncodedStringBytes("\u001F"))
        assertEquals(5, SettingsDomainV1.ContentBudget.jsonEncodedStringBytes("中"))
        assertEquals(6, SettingsDomainV1.ContentBudget.jsonEncodedStringBytes("😀"))
        assertEquals(10, SettingsDomainV1.ContentBudget.jsonEncodedStringBytes("a\u0000b"))
    }

    @Test
    fun finalContractDTOShapesAreNestedAndFlat() {
        val id = UUID.fromString("11111111-1111-1111-1111-111111111111")
        val scope = SettingsDomainV1.MemoryScope(SettingsDomainV1.MemoryScopeKind.user)
        val entry = SettingsDomainV1.MemoryEntry(
            id = id, scope = scope, status = SettingsDomainV1.MemoryEntryStatus.active,
            content = "hello", confidence = 1.0, importance = 0.8,
            isPinned = true, sourceKind = SettingsDomainV1.MemorySourceKind.explicitUserRequest,
            originConversationID = null, originWorkspaceID = null,
            factIdentity = null,
            ownership = SettingsDomainV1.Ownership(null, null, "owner", null, 2),
            expiresAt = null, createdAt = "2026-10-19T00:00:00Z",
            updatedAt = "2026-10-19T00:00:00Z",
            revision = "sha256:" + "a".repeat(64),
        )
        val item = SettingsDomainV1.MemorySearchItem(
            id = id, relevance = 0.9, lexicalRank = 1, semanticRank = null,
            semanticSimilarity = null, current = entry, deleted = false,
        )
        assertEquals("sha256:" + "a".repeat(64), item.current?.revision)
        assertEquals(2, item.current?.ownership?.recallCount)

        val evidence = SettingsDomainV1.MemoryEvidenceReference(
            id = id, messageID = id, excerpt = "sha256:redacted")
        val candidate = SettingsDomainV1.MemoryCandidate(
            id = id, scope = scope, content = "fact", confidence = 0.9,
            stability = 0.9, importance = 0.8,
            sensitivity = SettingsDomainV1.MemorySensitivity.none,
            origin = SettingsDomainV1.CandidateOrigin.explicitUserRequest,
            evidence = listOf(evidence), conflictsWithEntryIDs = emptyList(),
            reviewReason = null, sourceAttachmentID = null, sourceMIMEType = null,
            status = SettingsDomainV1.CandidateStatus.pending, expiresAt = null,
            createdAt = "2026-10-19T00:00:00Z", updatedAt = "2026-10-19T00:00:00Z",
            revision = "sha256:" + "b".repeat(64),
        )
        assertEquals(id, candidate.evidence.single().messageID)

        val effect = SettingsDomainV1.PersonalizationGenerateEffect(
            outcome = SettingsDomainV1.PersonalizationGenerateOutcome.Active,
            document = SettingsDomainV1.GeneratedPersonalizationDocument(
                id = id, revision = 4, isActive = true, contentBytes = 3,
                contentDigest = "sha256:" + "c".repeat(64),
                createdAt = "2026-10-19T00:00:00Z"),
            revisionToken = "11111111-1111-1111-1111-111111111111.4",
            draftRevision = null,
            route = SettingsDomainV1.PersonalizationGenerateRoute(id, id),
            evidenceDigest = "sha256:" + "d".repeat(64),
            sourceSnapshot = SettingsDomainV1.PersonalizationSourceSnapshot(
                1, "sha256:" + "e".repeat(64)),
            cursor = SettingsDomainV1.PersonalizationGenerateCursor(
                "sha256:" + "f".repeat(64), false),
        )
        assertEquals(id, effect.route.providerID)
        assertEquals(1, effect.sourceSnapshot.memoryCount)
        assertFalse(effect.cursor.countersPreserved)

        val history = SettingsDomainV1.PrivacyHistoryClearReport(
            enumerated = SettingsDomainV1.PrivacyHistoryEnumerated(1, 2, 3, 4),
            deleted = SettingsDomainV1.PrivacyHistoryDeleted(
                1, 2, SettingsDomainV1.PrivacyGrantDeletionCounts(3, 4)),
            failures = listOf(SettingsDomainV1.PrivacyFailure(
                id, SettingsDomainV1.PrivacyHistoryFailurePhase.drain, "typed")),
            partial = false,
            remaining = SettingsDomainV1.PrivacyRemaining(0, 0, 0, 0),
        )
        assertEquals(1, history.enumerated.conversations)
        assertEquals(3, history.deleted.grants.persisted)

        val model = SettingsDomainV1.PrivacyModelConfigClearReport(
            enumerated = SettingsDomainV1.PrivacyModelConfigEnumerated(1, 2, 1),
            deleted = SettingsDomainV1.PrivacyModelConfigDeleted(1, 2, 1),
            deletionFailures = listOf(SettingsDomainV1.PrivacyProviderDeletionFailure(
                id, SettingsDomainV1.PrivacyModelConfigFailurePhase.secretReferenceChanged,
                "typed")),
            preferencesReset = true, preferencesSyncRevision = 3,
            remaining = SettingsDomainV1.PrivacyModelConfigRemaining(0, 0, 0),
            partial = false,
        )
        assertEquals(1, model.enumerated.providers)
        assertEquals(1, model.deleted.secrets)

        assertEquals(
            SettingsDomainV1.OperationCancelPhase.streaming,
            SettingsDomainV1.OperationCancelReply(
                SettingsDomainV1.OperationCancelReply.Status.canceled,
                SettingsDomainV1.OperationCancelPhase.streaming).phase,
        )

        val breakdown = SettingsDomainV1.UsageBreakdown(
            id = "m-1", label = "model", inputTokens = 1, outputTokens = 2,
            runs = 1, cacheReadTokens = null, cacheWriteTokens = null,
            reasoningTokens = null, averageTokensPerSecond = null,
            averageTimeToFirstTokenMs = null, averageDurationMs = null,
            totalTokens = 3)
        assertEquals(1, breakdown.inputTokens)
    }

    @Test
    fun contentChunkUsesScalarBoundariesAndBudget() {
        val content = "A\uD83D\uDE00B\u4E2D\u6587C"
        assertThrows { SettingsDomainV1.ContentBudget.chunk(content, 1, 3) }
        val emoji = SettingsDomainV1.ContentBudget.chunk(content, 1, 4)
        assertEquals("\uD83D\uDE00", emoji.chunk)
        assertEquals(5, emoji.nextOffset)
        assertThrows { SettingsDomainV1.ContentBudget.chunk(content, 2, 4) }

        var offset = 0
        val rebuilt = ByteArrayOutputStream()
        var pages = 0
        while (true) {
            val chunk = SettingsDomainV1.ContentBudget.chunk(content, offset, 4)
            rebuilt.write(chunk.chunk.toByteArray(Charsets.UTF_8))
            assertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(chunk))
            pages += 1
            offset = chunk.nextOffset ?: break
        }
        assertEquals(content, rebuilt.toString("UTF-8"))
        assertTrue(pages > 1)

        val cjk = "\u4E2D".repeat(100)
        val tight = SettingsDomainV1.ContentBudget.chunk(cjk, 0, 32_768, 160)
        assertTrue(tight.chunk.toByteArray(Charsets.UTF_8).size < 300)
        assertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(tight, 160))
    }

    @Test
    fun terminalEmptyPageHonorsTheActualBudget() {
        val terminal = SettingsDomainV1.ContentBudget.chunk("abc", 3, 1)
        assertEquals("", terminal.chunk)
        assertNull(terminal.nextOffset)
        assertTrue(terminal.done)
        assertEquals(3, terminal.totalBytes)
        assertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(terminal))
        // The empty terminal page has a real encoded size; a tiny budget is a
        // typed failure, not an oversized success.
        assertThrows { SettingsDomainV1.ContentBudget.chunk("abc", 3, 1, 8) }
        assertThrows { SettingsDomainV1.ContentBudget.chunk("abc", 0, 1, 8) }
    }

    /**
     * MAIN_TERMINAL_METADATA_BUDGET_FOLLOWUP_20261019 executed regression
     * mirror (identical semantics to the Swift SettingsDomainV1Tests case):
     * the TERMINAL candidate shrinks its metadata (nextOffset null + done
     * true), so probing the largest terminal candidate FIRST must select the
     * full 10001-byte final page at the exact terminal-tight budget; the
     * binary search then covers only the strictly monotone non-terminal
     * range. Budgets are never exceeded and no data is ever lost.
     */
    @Test
    fun terminalMetadataShrinkSelectsFullFinalPage() {
        val content = "A".repeat(10_001)
        fun encodedPrefix(byteCount: Int, terminal: Boolean): Int =
            SettingsDomainV1.ContentBudget.encodedChunkResponseBytes(
                SettingsDomainV1.ContentChunk(
                    chunk = "A".repeat(byteCount),
                    nextOffset = if (terminal) null else byteCount,
                    totalBytes = 10_001,
                    done = terminal,
                ))
        val terminalBytes = encodedPrefix(10_001, true)
        val penultimateBytes = encodedPrefix(10_000, false)
        assertTrue("terminal metadata shrink expected",
                   penultimateBytes > terminalBytes)

        val page = SettingsDomainV1.ContentBudget.chunk(content, 0, 20_000, terminalBytes)
        assertEquals(10_001, page.chunk.toByteArray(Charsets.UTF_8).size)
        assertTrue(page.done)
        assertNull(page.nextOffset)
        assertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(page, terminalBytes))

        val below = SettingsDomainV1.ContentBudget.chunk(content, 0, 20_000, terminalBytes - 1)
        assertTrue(!below.done)
        assertTrue(below.nextOffset != null)
        assertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(below, terminalBytes - 1))
        val nextPrefix = SettingsDomainV1.ContentChunk(
            chunk = "A".repeat(below.chunk.toByteArray(Charsets.UTF_8).size + 1),
            nextOffset = below.chunk.toByteArray(Charsets.UTF_8).size + 1,
            totalBytes = 10_001,
            done = false,
        )
        assertTrue(!SettingsDomainV1.ContentBudget.fitsPageBudget(nextPrefix, terminalBytes - 1))

        val mid = SettingsDomainV1.ContentBudget.chunk(content, 0, 5_000, terminalBytes)
        assertEquals(5_000, mid.chunk.toByteArray(Charsets.UTF_8).size)
        assertTrue(!mid.done)
        assertEquals(5_000, mid.nextOffset)

        val samples = listOf(
            "\u4E2D".repeat(4_000),
            "\\\"\n".repeat(3_000),
            "\uD83D\uDE00".repeat(3_000),
        )
        for (sample in samples) {
            val bytes = sample.toByteArray(Charsets.UTF_8)
            fun encodedTerminal(byteCount: Int): Int =
                SettingsDomainV1.ContentBudget.encodedChunkResponseBytes(
                    SettingsDomainV1.ContentChunk(
                        chunk = String(bytes, 0, byteCount, Charsets.UTF_8),
                        nextOffset = null,
                        totalBytes = bytes.size,
                        done = true,
                    ))
            val budget = encodedTerminal(bytes.size)
            val full = SettingsDomainV1.ContentBudget.chunk(sample, 0, bytes.size, budget)
            assertEquals(sample, full.chunk)
            assertTrue(full.done)
            val tight = SettingsDomainV1.ContentBudget.chunk(sample, 0, bytes.size, budget - 1)
            assertTrue(!tight.done)
            assertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(tight, budget - 1))
        }
    }

    @Test
    fun denseEscapedContentChunksWithBoundedWork() {
        // 32KiB of the most expensive ASCII escapes; a remove-one-scalar-
        // and-reserialize loop would re-encode the whole prefix per candidate.
        val dense = "\"\\\u0001\n".repeat(8_192)
        val bytes = dense.toByteArray(Charsets.UTF_8)
        assertEquals(32_768, bytes.size)
        var offset = 0
        val rebuilt = ByteArrayOutputStream()
        var pages = 0
        var firstBytes = 0
        while (true) {
            val chunk = SettingsDomainV1.ContentBudget.chunk(dense, offset, 32_768)
            if (pages == 0) firstBytes = chunk.chunk.toByteArray(Charsets.UTF_8).size
            rebuilt.write(chunk.chunk.toByteArray(Charsets.UTF_8))
            assertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(chunk))
            assertTrue(chunk.chunk.isNotEmpty())
            pages += 1
            offset = chunk.nextOffset ?: break
        }
        assertTrue(bytes.contentEquals(rebuilt.toByteArray()))
        // 4 content bytes encode to 12 bytes, so a 48KiB page carries about
        // 16KiB. Exact page count detects silent shrinking.
        assertEquals(3, pages)
        assertTrue(firstBytes > 16_000)
    }

    @Test
    fun encodedSizesMatchActualWireConventions() {
        // Fixed expectations are the actual Swift JSONSerialization byte
        // counts for the shared wire, not a self-derived formula.
        val expected = linkedMapOf(
            "a" to 3,
            "\"" to 4,
            "/" to 4,
            "\\" to 4,
            "\n" to 4,
            "\r" to 4,
            "\t" to 4,
            "\u0008" to 4,
            "\u000C" to 4,
            "\u001F" to 8,
            "\u007F" to 3,
            "\u4E2D" to 5,
            "\uD83D\uDE00" to 6,
            "a\u0000b" to 10,
            "a/b\\c\"d\ne\tf" to 18,
        )
        for ((value, size) in expected) {
            assertEquals("encoded bytes for ${value.length} chars", size,
                SettingsDomainV1.ContentBudget.jsonEncodedStringBytes(value))
        }
        // A lone UTF-16 surrogate cannot exist in the Swift wire string; the
        // Kotlin mirror must not throw or invent a surrogate escape.
        assertEquals(3, SettingsDomainV1.ContentBudget.jsonEncodedStringBytes("\uD800"))
        assertEquals(5, SettingsDomainV1.ContentBudget.jsonEncodedStringBytes("a\uD800b"))
        // Complete fixed-size wire responses (independent byte counts).
        assertEquals(58, SettingsDomainV1.ContentBudget.encodedChunkResponseBytes(
            SettingsDomainV1.ContentChunk("a", null, 1, true)))
        assertEquals(57, SettingsDomainV1.ContentBudget.encodedChunkResponseBytes(
            SettingsDomainV1.ContentChunk("", null, 3, true)))
    }

    @Test
    fun typedDocumentAndOutcomeKeepDraftExplicit() {
        val id = UUID.randomUUID()
        val base = SettingsDomainV1.PersonalizationDocument(
            id = id,
            kind = SettingsDomainV1.PersonalizationKind.soul,
            workspaceID = null,
            revision = 1,
            source = SettingsDomainV1.PersonalizationSource.manual,
            evidenceDigest = "",
            isActive = true,
            createdAt = "2026-10-19T00:00:00Z",
            contentBytes = 3,
            contentDigest = "sha256:" + "d".repeat(64),
            content = "abc",
            contentHandle = null,
        )
        assertEquals("abc", base.content)
        assertNull(base.contentHandle)

        assertThrows {
            base.copy(content = "abc", contentHandle =
                SettingsDomainV1.ContentHandle("h-1", 3))
        }
        assertThrows { base.copy(content = null, contentHandle = null) }

        val draft = SettingsDomainV1.PersonalizationGenerateOutcome.StoredAsDraft(
            SettingsDomainV1.GenerateDraftReason.sourceChanged)
        assertTrue(draft is SettingsDomainV1.PersonalizationGenerateOutcome.StoredAsDraft)
        assertFalse(draft is SettingsDomainV1.PersonalizationGenerateOutcome.Active)

        assertThrows { SettingsDomainV1.MemoryScope(
            SettingsDomainV1.MemoryScopeKind.workspace) }
        assertThrows { SettingsDomainV1.MemoryScope(
            SettingsDomainV1.MemoryScopeKind.task, UUID.randomUUID()) }
        assertEquals(3, SettingsDomainV1.UsageMetrics(
            inputTokens = 1, outputTokens = 2, totalTokens = 3, runs = 1).totalTokens)
    }

    private inline fun assertThrows(block: () -> Unit) {
        try {
            block()
        } catch (_: IllegalArgumentException) {
            return
        }
        throw AssertionError("expected IllegalArgumentException")
    }
}
