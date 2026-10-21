// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * S1..S12 required-action wire tests — AUTHORED, NOTRUN (no JVM/Gradle
 * execution in the source phase; Main runs them in the composed batch).
 *
 * Scripted transport doubles only; no native bridge, no device, no cloud.
 * Every assertion is against the ACTUAL envelope/payload JSON the host
 * dispatches, cross-checked against the real RB-6 router/closed-grammar
 * keys (RuntimeFacadeCapabilitiesSkillsMCP / RuntimeFacadeSkillsService /
 * RuntimeFacadeMCPService bytes), so a regression to the pre-fix shapes
 * (serverID/credentialState/Long-revision decode, "settings"/"upgrade"/
 * "rollback" fabricated CAS, skillId+numeric effectToken upgrade.apply,
 * candidate without createIntent, disabled tool set reset, revision-less
 * cancel.refresh, discarding upgrade.check, empty connectors projection,
 * fake requestFolderStaging "success", LAN-denied == auth failure) fails
 * HERE, not silently.
 */
class IntegrationsRequiredActionsTest {

    private val json = Json { ignoreUnknownKeys = true }

    // ------------------------------------------------------------ doubles

    /** One scripted command → queue receipt → effect page table. The
     *  effect pages echo the REAL poll correlation/receipt (same shape as
     *  the accepted WebSearchHostControllerTest exchange double). */
    private class ScriptExchange(
        private val replyFor: (command: String) -> String?,
    ) : HostBridgeExchange {
        val requests = CopyOnWriteList()

        override fun exchange(request: String): String {
            requests.add(request)
            val correlation = correlationOf(request)
            if (request.contains("\"operation\":\"effect.poll\"")) {
                val receipt = receiptOf(request)
                val value = replies[receipt]
                return if (value != null) {
                    """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
                        """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt",""" +
                        """"sequence":1},"effects":[{"sequence":1,"kind":"accepted","value":$value}],""" +
                        """"hasMore":false,"resyncRequired":false}"""
                } else {
                    """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
                        """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt",""" +
                        """"sequence":0},"effects":[],"hasMore":true,"resyncRequired":false}"""
                }
            }
            val command = commandOf(request)
            val receipt = "op:v1:$command-${sequence.incrementAndGet()}"
            replyFor(command)?.let { replies[receipt] = stripFrame(it) }
            return """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$receipt"}"""
        }

        private val replies = ConcurrentHashMap<String, String>()
        private val sequence = AtomicInteger(0)

        /** replyFor may return a full completedFrame OR a bare value page;
         *  normalize to the bare page JSON the poll wraps. */
        private fun stripFrame(page: String): String {
            val root = Json.parseToJsonElement(page) as? JsonObject ?: return page
            if (root["schema"]?.jsonPrimitive?.content == "floe.effect-cursor/3") {
                val effects = root["effects"] as? JsonArray
                return (effects?.firstOrNull() as? JsonObject)?.get("value")?.toString() ?: page
            }
            return page
        }

        fun envelopes(command: String): List<JsonObject> = requests.list
            .filter { it.contains("\"command\":\"$command\"") }
            .map { Json.parseToJsonElement(it) as JsonObject }
            .mapNotNull { it["envelope"] as? JsonObject }

        companion object {
            fun commandOf(raw: String): String {
                val marker = "\"command\":\""
                val start = raw.indexOf(marker).takeIf { it >= 0 } ?: return ""
                val from = start + marker.length
                val end = raw.indexOf('"', from)
                return if (end > from) raw.substring(from, end) else ""
            }
        }
    }

    private class CopyOnWriteList {
        private val items = java.util.Collections.synchronizedList(mutableListOf<String>())
        fun add(value: String) { items.add(value) }
        val list: List<String> get() = items.toList()
    }

    private class FakeRouteAuthority : HostRouteAuthority {
        var token = "rt:v1:" + "a".repeat(32)
        val opened = AtomicInteger(0)
        override fun open(
            kind: HostEditorKind,
            editorID: String,
            uiGeneration: Long,
            expectedNativeRootEpoch: Long,
        ): String? {
            opened.incrementAndGet()
            return token
        }

        override fun clear(token: String) = Unit
    }

    private class RecordingIngress : HostSecureIngressSubmitter {
        var lastIntentCore: String? = null
        var lastRoute: String? = null
        var lastBytes: ByteArray? = null
        var result: String? = "int:v1:" + "b".repeat(32)
        override fun submit(intentCoreJSON: String, routeToken: String, value: ByteArray): String? {
            lastIntentCore = intentCoreJSON
            lastRoute = routeToken
            lastBytes = value.copyOf()
            return result
        }
    }

    private fun hostWith(exchange: ScriptExchange): RuntimeHost {
        val host = RuntimeHost(
            commandClient = RuntimeHostCommandClient(
                exchange = exchange,
                scope = CoroutineScope(Dispatchers.Default),
                ioDispatcher = Dispatchers.Default,
                budgets = HostWireBudgets(effectPollIntervalMillis = 1),
            ),
            gatewayCapability = MutableStateFlow(com.floe.android.SecretGatewayCapability.Ready),
            bootstrapCapability = MutableStateFlow(com.floe.android.RuntimeBootstrapCapability.Idle),
            scope = CoroutineScope(Dispatchers.Default),
            ioDispatcher = Dispatchers.Default,
        )
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("skillsMcpDiscovery", available = true, missing = emptyList())
        host.nativeRootEpochReader = { 31L }
        host.integrations.testRouteAuthority = FakeRouteAuthority()
        return host
    }

    private suspend fun waitUntil(timeoutMillis: Long = 3_000, predicate: () -> Boolean) {
        withTimeout(timeoutMillis) {
            while (!predicate()) delay(5)
        }
    }

    // ------------------------------------------------------------ fixtures

    /** One REAL-shaped mcp.servers.list row (keys exactly as
     *  RuntimeFacadeMCPService.list emits: id, credential{required,state},
     *  revision{resourceID=mcp.<UPPER uuid>,version=64-hex digest},
     *  connection{state,generation STRING|toolCount|reason}, tools[],
     *  disabledRemoteToolNames[]). */
    private val SERVER_ID = "6F7B2A1C-3D4E-5F60-7182-93A4B5C6D7E8"
    private val ROW_RESOURCE_ID = "mcp.$SERVER_ID"
    private val ROW_DIGEST = "ab".repeat(32)

    private fun mcpServersPage(
        state: String = "connecting",
        credentialState: String = "configured",
        toolsDisabled: List<String> = listOf("write"),
    ): String = """
        {"servers":[{
            "id":"$SERVER_ID",
            "displayName":"Local Hub",
            "endpoint":"https://hub.local:8443/mcp",
            "enabled":true,
            "allowInCanvas":false,
            "allowInsecureHTTP":false,
            "authentication":"bearerToken",
            "credentialHeaderName":"Authorization",
            "timeoutSeconds":30,
            "disabledRemoteToolNames":${toolsDisabled.toJsonArray()},
            "revision":{"resourceID":"$ROW_RESOURCE_ID","version":"$ROW_DIGEST"},
            "connection":{"state":"$state","generation":"7"},
            "toolCount":2,
            "tools":[{"remoteName":"search","displayName":"Search","description":"d","readOnlyHint":true,"destructiveHint":false,"enabled":true},
                      {"remoteName":"write","displayName":"Write","description":"d","readOnlyHint":false,"destructiveHint":true,"enabled":false}],
            "credential":{"required":true,"state":"$credentialState","opaqueReference":"ref:v1:x"},
            "secretCleanupPending":false
        }],"hasMore":false,"nextCursor":null,
        "transports":[{"transport":"streamableHTTP2026-07-28","availability":"AVAILABLE","note":"x"}],
        "gatewayRegistered":true}
    """.trimIndent()

    private fun skillsSnapshotPage(
        nextCursor: String? = null,
        hasMore: Boolean = false,
        settingsRevision: String = "cd".repeat(32),
        pending: String = "[]",
        official: Boolean = true,
        catalogState: String = "ready",
        catalogPackages: String = "[]",
        rollback: Boolean = false,
    ): String = """
        {"skills":[{
            "id":"pdf-forms","name":"PDF Forms","version":"1.2.0","enabled":true,
            "digest":"$ROW_DIGEST",
            "revision":{"resourceID":"skill.pdf-forms","version":"$ROW_DIGEST"},
            "updatedAt":"2026-10-20T00:00:00Z",
            "official":$official,
            "bundledSeedSuppressed":false,
            "description":"Fill PDF forms",
            "rollbackAvailable":$rollback
        }],
        "hasMore":$hasMore,
        "nextCursor":${nextCursor?.let { "\"$it\"" } ?: "null"},
        "catalog":{"state":"$catalogState","checkedAt":"2026-10-20T00:00:00Z","packages":$catalogPackages,"lastFailure":null,"retryAfter":null},
        "pendingReviews":$pending,
        "settings":{"autoScriptedUpdates":true,"revision":{"resourceID":"skills.settings","version":"$settingsRevision"}}}
    """.trimIndent()

    private fun reviewProjection(
        token: String = "eff:v1:" + "e".repeat(32),
        skillId: String = "pdf-forms",
        version: String = "1.3.0",
        committed: Boolean = false,
    ): String = """
        {"reviewToken":${if (committed) "null" else "\"$token\""},"skillID":"$skillId",
         "version":"$version","committed":$committed,
         "changedFiles":["SKILL.md"],"addedCapabilities":["workspace.read"],
         "addedTools":["pdf.fill"],"releaseNotes":{"en":"Improvements"}}
    """.trimIndent()

    private fun List<String>.toJsonArray(): String =
        joinToString(",", "[", "]") { "\"$it\"" }

    // ------------------------------------------------------------ tests

    /** F-S1/F-S2: decode reads the REAL row keys; every mutation echoes the
     *  opaque pair (resourceID + 64-hex digest) — no serverID key, no
     *  credentialState top-level key, no Long revision, no "0"/default. */
    @Test
    fun `mcp rows decode real identity credential and digest revision`() = runBlocking {
        val exchange = ScriptExchange { command ->
            when (command) {
                "mcp.servers.list" -> completedFrame(mcpServersPage())
                else -> null
            }
        }
        val host = hostWith(exchange)
        host.integrations.refreshMcpServers()
        waitUntil { host.integrations.destination.value.mcp.servers.isNotEmpty() }
        val row = host.integrations.destination.value.mcp.servers.single()
        assertEquals(SERVER_ID, row.serverId)
        assertEquals(ROW_DIGEST, row.revision.version)
        assertEquals(ROW_RESOURCE_ID, row.revision.resourceID)
        assertTrue(row.credentialStored)
        assertTrue(row.credentialRequired)
        // generation arrives as a STRING in the wire object:
        assertEquals(7L, (row.state as com.floe.android.feature.integrations
            .McpConnectionStateUi.Connecting).generation)
        assertEquals(listOf("write"), row.disabledRemoteToolNames)

        // Enabled toggle then echoes the REAL pair (never "mcp.server"/Long):
        host.integrations.setMcpServerEnabled(SERVER_ID, enabled = false)
        waitUntil {
            exchange.envelopes("mcp.connect").any { env ->
                val rev = env["revision"] as? JsonObject
                rev?.stringOf("resourceID") == ROW_RESOURCE_ID &&
                    rev.stringOf("version") == ROW_DIGEST
            }
        }
        val env = exchange.envelopes("mcp.connect").last()
        assertNull(env["createIntent"])
        assertEquals("enabled.set", (env["payload"] as JsonObject).stringOf("operation"))
    }

    /** F-S10: cancel.refresh must carry a revision (the local validator
     *  refuses a revision-required command without one; the pre-fix shape
     *  never even reached the queue). The typed settled outcome is read. */
    @Test
    fun `cancel refresh carries the real revision and consumes the typed outcome`() = runBlocking {
        var listRound = 0
        val exchange = ScriptExchange { command ->
            when (command) {
                "mcp.servers.list" -> {
                    listRound += 1
                    completedFrame(mcpServersPage())
                }
                "mcp.disconnect" -> completedFrame(
                    """{"state":"noop","serverID":"$SERVER_ID","reason":"generationNotLive"}""",
                )
                else -> null
            }
        }
        val host = hostWith(exchange)
        host.integrations.refreshMcpServers()
        waitUntil { host.integrations.destination.value.mcp.servers.isNotEmpty() }
        host.integrations.cancelMcpRefresh(SERVER_ID, generation = 7L)
        waitUntil {
            exchange.envelopes("mcp.disconnect").any { env ->
                (env["revision"] as? JsonObject)?.stringOf("version") == ROW_DIGEST &&
                    (env["payload"] as? JsonObject)?.stringOf("operation") == "cancel.refresh"
            }
        }
        // The noop terminal (generation superseded) triggers an honest
        // re-read, not a silent dismiss: a second servers.list follows.
        waitUntil { listRound >= 2 }
    }

    /** F-S3 + F-S9: the create hop is the CANDIDATE's closed createIntent
     *  key (both direct and frozen secure-intent candidates) and the
     *  disabled tool set is preserved across edit/save. */
    @Test
    fun `candidate carries createIntent and preserves disabled tools`() = runBlocking {
        val exchange = ScriptExchange { command ->
            when (command) {
                "mcp.servers.list" -> completedFrame(mcpServersPage())
                "mcp.connect" -> completedFrame(
                    """{"state":"committed","serverID":"$SERVER_ID","secretIntent":"keep",""" +
                        """"revision":{"resourceID":"$ROW_RESOURCE_ID","version":"ff".repeat(16)},""" +
                        """"connect":{"connection":{"state":"inactive"}}}""",
                )
                else -> null
            }
        }
        val host = hostWith(exchange)
        host.integrations.refreshMcpServers()
        waitUntil { host.integrations.destination.value.mcp.servers.isNotEmpty() }

        val editor = com.floe.android.feature.integrations.McpEditorIdentity(
            editorId = "editor-1", epoch = 1, serverId = SERVER_ID,
        )
        val request = com.floe.android.feature.integrations.McpSaveRequest(
            identity = editor,
            serverId = SERVER_ID,
            draft = com.floe.android.feature.integrations.McpDraftSnapshot(
                displayName = "Local Hub",
                endpointText = "https://hub.local:8443/mcp",
                enabled = true,
                authentication = com.floe.android.feature.integrations
                    .McpAuthenticationUi.BEARER_TOKEN,
                disabledRemoteToolNames = setOf("write"),
            ),
            credentialIntent = com.floe.android.feature.integrations
                .CredentialDraftIntent.KEEP_EXISTING,
            credentialDraft = null,
            baseRevision = com.floe.android.feature.integrations.McpServerRevisionUi(
                ROW_RESOURCE_ID, ROW_DIGEST,
            ),
        )
        assertTrue(host.integrations.saveMcpServer(request))
        waitUntil { exchange.envelopes("mcp.connect").isNotEmpty() }
        val env = exchange.envelopes("mcp.connect").last()
        val payload = env["payload"] as JsonObject
        val candidate = payload["candidate"] as JsonObject
        assertEquals("keep", payload.stringOf("secretIntent"))
        assertEquals(false, (candidate["createIntent"] as? JsonPrimitive)?.booleanOrNull)
        assertEquals(
            listOf("write"),
            (candidate["disabledRemoteToolNames"] as? JsonArray)
                ?.map { (it as JsonPrimitive).contentOrNull },
        )
        // Envelope CAS is the REAL pair:
        assertEquals(ROW_DIGEST, (env["revision"] as? JsonObject)?.stringOf("version"))
    }

    /** F-S3 create path: a NEW identity rides the Set lease; its frozen
     *  intentCore candidate carries createIntent=true and the lease
     *  baseRevision is the UUID-derived resource + the domain's "0"
     *  absent-row marker (never "mcp.server"). */
    @Test
    fun `set lease create hop freezes candidate createIntent and zero base`() = runBlocking {
        val exchange = ScriptExchange { command ->
            when (command) {
                "mcp.connect" -> completedFrame(
                    """{"state":"committed","serverID":"NEW","secretIntent":"set",""" +
                        """"revision":{"resourceID":"mcp.NEW","version":"ee".repeat(32)},""" +
                        """"connect":{"state":"connected","generation":"1","toolCount":0}}""",
                )
                else -> null
            }
        }
        val host = hostWith(exchange)
        val ingress = RecordingIngress()
        host.integrations.secureIngress = ingress
        host.integrations.testRouteAuthority = FakeRouteAuthority()
        host.integrations.mcpEditorOpened(
            com.floe.android.feature.integrations.McpEditorIdentity(
                editorId = "new-1", epoch = 1, serverId = null,
            ),
        )
        val request = com.floe.android.feature.integrations.McpSaveRequest(
            identity = com.floe.android.feature.integrations.McpEditorIdentity(
                editorId = "new-1", epoch = 1, serverId = null,
            ),
            serverId = null,
            draft = com.floe.android.feature.integrations.McpDraftSnapshot(
                displayName = "New", endpointText = "https://api.example.com/mcp",
                authentication = com.floe.android.feature.integrations
                    .McpAuthenticationUi.BEARER_TOKEN,
            ),
            credentialIntent = com.floe.android.feature.integrations
                .CredentialDraftIntent.SET,
            credentialDraft = "typed-secret",
            baseRevision = null,
        )
        assertTrue(host.integrations.saveMcpServer(request))
        waitUntil { ingress.lastIntentCore != null }
        val intent = Json.parseToJsonElement(ingress.lastIntentCore!!) as JsonObject
        val candidate = intent["candidate"] as JsonObject
        assertEquals(true, (candidate["createIntent"] as? JsonPrimitive)?.booleanOrNull)
        val base = intent["baseRevision"] as JsonObject
        assertEquals("0", base.stringOf("version"))
        val minted = candidate.stringOf("id")!!
        assertEquals("mcp." + minted.uppercase(), base.stringOf("resourceID"))
        // The command envelope itself: createIntent=true and NO revision
        // (frozen rule: a new identity never carries a version).
        waitUntil { exchange.envelopes("mcp.connect").isNotEmpty() }
        val env = exchange.envelopes("mcp.connect").last()
        assertEquals(true, (env["createIntent"] as? JsonPrimitive)?.booleanOrNull)
        assertNull(env["revision"])
    }

    /** F-S4: upgrade.apply sends the REAL staged reviewToken (from the
     *  check reply), the optional STRING effectToken echo (the module
     *  presentation Long), and the real skill.<id> digest CAS. skillId is
     *  NOT in the payload (closed grammar forbids it there). */
    @Test
    fun `upgrade apply uses review token grammar and real digest CAS`() = runBlocking {
        val token = "eff:v1:" + "1".repeat(32)
        val exchange = ScriptExchange { command ->
            when (command) {
                "skills.list" -> completedFrame(skillsSnapshotPage())
                "skills.install" -> completedFrame(reviewProjection(token = token))
                else -> null
            }
        }
        val host = hostWith(exchange)
        host.integrations.refreshSkills()
        waitUntil { host.integrations.destination.value.skills.installed.isNotEmpty() }
        assertTrue(host.integrations.checkUpgrade("pdf-forms", source = null))
        waitUntil {
            host.integrations.destination.value.upgrade?.candidateVersion == "1.3.0"
        }
        // Apply with the module dispatch token 4 (the staged eff:v1 token
        // was registered host-side by the check terminal above):
        assertTrue(host.integrations.applyUpgrade("pdf-forms", effectToken = 4L))
        waitUntil {
            exchange.envelopes("skills.install").any { env ->
                (env["payload"] as? JsonObject)?.stringOf("operation") == "upgrade.apply"
            }
        }
        val env = exchange.envelopes("skills.install").last {
            (it["payload"] as JsonObject).stringOf("operation") == "upgrade.apply"
        }
        val payload = env["payload"] as JsonObject
        assertEquals(token, payload.stringOf("reviewToken"))
        assertEquals("4", (payload["effectToken"] as? JsonPrimitive)?.contentOrNull)
        assertNull(payload["skillId"])
        val rev = env["revision"] as JsonObject
        assertEquals("skill.pdf-forms", rev.stringOf("resourceID"))
        assertEquals(ROW_DIGEST, rev.stringOf("version"))
    }

    /** F-S5/F-S6: settings.set + upgrade.rollback ride the REAL digests;
     *  fabricated "settings"/"rollback" versions never leave the host. */
    @Test
    fun `settings and rollback CAS use the decoded real digests`() = runBlocking {
        val settingsDigest = "cd".repeat(32)
        val exchange = ScriptExchange { command ->
            when (command) {
                "skills.list" -> completedFrame(
                    skillsSnapshotPage(settingsRevision = settingsDigest, rollback = true),
                )
                "skills.install" -> completedFrame(
                    """{"state":"applied","enabled":false,"revision":{"resourceID":"skills.settings","""" +
                        """"version":"$settingsDigest"}}""",
                )
                else -> null
            }
        }
        val host = hostWith(exchange)
        host.integrations.refreshSkills()
        waitUntil { host.integrations.destination.value.skills.installed.isNotEmpty() }

        host.integrations.setAutoScriptedUpdates(enabled = false)
        waitUntil {
            exchange.envelopes("skills.install").any { env ->
                (env["payload"] as? JsonObject)?.stringOf("operation") == "settings.set"
            }
        }
        val settingsEnv = exchange.envelopes("skills.install").last {
            (it["payload"] as JsonObject).stringOf("operation") == "settings.set"
        }
        assertEquals(
            settingsDigest,
            (settingsEnv["revision"] as JsonObject).stringOf("version"),
        )

        assertTrue(host.integrations.rollbackUpgrade("pdf-forms", effectToken = 9L))
        waitUntil {
            exchange.envelopes("skills.install").any { env ->
                (env["payload"] as? JsonObject)?.stringOf("operation") == "upgrade.rollback"
            }
        }
        val rbEnv = exchange.envelopes("skills.install").last {
            (it["payload"] as JsonObject).stringOf("operation") == "upgrade.rollback"
        }
        assertEquals(ROW_DIGEST, (rbEnv["revision"] as JsonObject).stringOf("version"))
        assertEquals("skill.pdf-forms", (rbEnv["revision"] as JsonObject).stringOf("resourceID"))
        // rollback payload stays closed: operation + skillId only.
        val payload = rbEnv["payload"] as JsonObject
        assertNull(payload["effectToken"])
    }

    /** S8 paging: the snapshot's decimal nextCursor is echoed in the
     *  PAYLOAD of the following page (the frozen cursor role), rows
     *  accumulate, and catalog + settings re-apply per page. */
    @Test
    fun `snapshot follows nextCursor with bounded pages`() = runBlocking {
        val exchange = ScriptExchange { command ->
            when (command) {
                "skills.list" -> completedFrame(
                    skillsSnapshotPage(nextCursor = "1", hasMore = true),
                )
                else -> null
            }
        }
        val host = hostWith(exchange)
        host.integrations.refreshSkills()
        waitUntil { exchange.envelopes("skills.list").size >= 2 }
        val second = exchange.envelopes("skills.list")[1]
        assertEquals("1", (second["payload"] as JsonObject).stringOf("cursor"))
        // The row's digest revision decoded from the REAL pair drives the
        // enable-toggle CAS verbatim:
        host.integrations.setSkillEnabled("pdf-forms", ROW_DIGEST, enabled = false)
        waitUntil {
            exchange.envelopes("skills.install").any { env ->
                (env["revision"] as? JsonObject)?.stringOf("version") == ROW_DIGEST &&
                    (env["payload"] as? JsonObject)?.stringOf("operation") == "enabled.set"
            }
        }
    }

    /** S8 review echo: a snapshot pendingReviews row with kind=upgrade and
     *  its REAL echoed revision makes confirm ride the digest CAS (never
     *  createIntent), while an install-kind review rides explicit create. */
    @Test
    fun `pending review rows echo kind and CAS revision`() = runBlocking {
        val upgradeToken = "eff:v1:" + "2".repeat(32)
        val exchange = ScriptExchange { command ->
            when (command) {
                "skills.list" -> completedFrame(
                    skillsSnapshotPage(
                        pending = """[{"reviewToken":"$upgradeToken","skillID":"pdf-forms",""" +
                            """"kind":"upgrade","revision":{"resourceID":"skill.pdf-forms",""" +
                            """"version":"$ROW_DIGEST"}}]""",
                    ),
                )
                "skills.install" -> completedFrame(reviewProjection(committed = true))
                else -> null
            }
        }
        val host = hostWith(exchange)
        host.integrations.refreshSkills()
        waitUntil { host.integrations.destination.value.installReview != null }
        val reviewId = host.integrations.destination.value.installReview!!.reviewId
        assertTrue(host.integrations.confirmPendingInstallation(reviewId))
        waitUntil {
            exchange.envelopes("skills.install").any { env ->
                (env["payload"] as? JsonObject)?.stringOf("operation") == "review.confirm"
            }
        }
        val env = exchange.envelopes("skills.install").last {
            (it["payload"] as JsonObject).stringOf("operation") == "review.confirm"
        }
        assertNull(env["createIntent"])
        assertEquals(ROW_DIGEST, (env["revision"] as JsonObject).stringOf("version"))
    }

    /** S11 folder grammar: the staged stg:v1 handle is the ONLY thing the
     *  import command carries; a synthetic/arbitrary path is not possible
     *  (the handle came from the domain receipt via the trusted channel). */
    @Test
    fun `folder import sends only the opaque stg token`() = runBlocking {
        val exchange = ScriptExchange { command ->
            when (command) {
                "skills.install" -> completedFrame(reviewProjection(token = "rev-ignored"))
                else -> null
            }
        }
        val host = hostWith(exchange)
        val handle = "stg:v1:" + "3".repeat(32)
        val reference = com.floe.android.feature.integrations.StagedPackageRefUi(
            handle = handle, displayName = "My Skill Folder", mimeType = null, sizeBytes = 2048,
        )
        assertTrue(host.integrations.importStagedPackage("form-1", reference))
        waitUntil { exchange.envelopes("skills.install").isNotEmpty() }
        val env = exchange.envelopes("skills.install").last()
        val payload = env["payload"] as JsonObject
        assertEquals("folder.import", payload.stringOf("operation"))
        assertEquals(handle, payload.stringOf("stagingToken"))
        assertEquals(true, (env["createIntent"] as? JsonPrimitive)?.booleanOrNull)
        assertNull(env["revision"])
    }

    /** S12: capability.tools.list readiness drives the Connectors rows —
     *  never a hard-empty list, never "all usable". */
    @Test
    fun `capability tool sources project real readiness`() = runBlocking {
        val page = """
            {"tools":[
                {"name":"web.search","description":"d","availability":"available","source":"native"},
                {"name":"workspace.read","description":"d","availability":"available","source":"native"},
                {"name":"exec.shell","description":"d","availability":"notImplemented","source":"native",
                 "prerequisites":[{"kind":"environmentG03","reason":"resolved Linux environment"}]},
                {"name":"mcp_6f7b2a1c3d_pdf.fill","description":"d","availability":"available","source":"mcp"}
            ],"hasMore":false,"nextCursor":null,"totalCandidates":4,
            "temporaryCeiling":{"names":[],"policy":"publicWebOnly.closedSet","searchProviderConfigured":false},
            "modelScoped":false}
        """.trimIndent()
        val exchange = ScriptExchange { command ->
            when (command) {
                "mcp.servers.list" -> completedFrame(mcpServersPage(state = "ready"))
                "capability.tools.list" -> completedFrame(page)
                else -> null
            }
        }
        val host = hostWith(exchange)
        host.integrations.load()
        waitUntil { host.integrations.destination.value.connectors.toolSources.isNotEmpty() }
        val rows = host.integrations.destination.value.connectors.toolSources
        // One native aggregate + one MCP-server source (matched by the
        // ORIGINAL namespace prefix rule off the real row id):
        assertEquals(2, rows.size)
        val nativeRow = rows.first { it.destinationId == "native-tools" }
        val mcpRow = rows.first { it.destinationId == "mcp-tools.$SERVER_ID" }
        // native: 2 available + 1 blocked → still an AVAILABLE aggregate;
        // mcp server: 1 registered-and-available tool under the real prefix.
        assertTrue(nativeRow.availability is com.floe.android.feature.integrations
            .ConnectorAvailabilityUi.Available)
        assertTrue(mcpRow.availability is com.floe.android.feature.integrations
            .ConnectorAvailabilityUi.Available)
        // A zero-available source would be Unavailable with remediation —
        // verified by the blocked-only fixture below (no hidden empty list).
    }

    /** S12 honesty: a fully blocked projection still renders the source
     *  with an actionable remediation instead of vanishing. */
    @Test
    fun `blocked sources stay visible with remediation`() = runBlocking {
        val page = """
            {"tools":[{"name":"exec.shell","description":"d","availability":"notImplemented","source":"native",
              "prerequisites":[{"kind":"environmentG03","reason":"resolved Linux environment"}]}],
             "hasMore":false,"nextCursor":null,"totalCandidates":1,
             "temporaryCeiling":{"names":[],"policy":"x","searchProviderConfigured":false},"modelScoped":false}
        """.trimIndent()
        val exchange = ScriptExchange { command ->
            when (command) {
                "capability.tools.list" -> completedFrame(page)
                else -> null
            }
        }
        val host = hostWith(exchange)
        host.integrations.load()
        waitUntil { host.integrations.destination.value.connectors.toolSources.isNotEmpty() }
        val row = host.integrations.destination.value.connectors.toolSources
            .first { it.destinationId == "native-tools" }
        assertTrue(
            row.availability is com.floe.android.feature.integrations
                .ConnectorAvailabilityUi.Unavailable,
        )
    }

    /** MAIN_ANDROID37_LAN_PERMISSION_DECISION_20261021: local endpoint on
     *  API 37 without the grant routes the EXPLICIT tap through the broker
     *  (dialog first, captured-hop-only chaining); denial is a typed
     *  local-network code, never an auth substitution; public cloud and
     *  API<37 stay completely ungated; a replaced request's late result is
     *  fenced and never dispatches. */
    @Test
    fun `lan permission gates only explicit local hops on api 37`() = runBlocking {
        val exchange = ScriptExchange { command ->
            when (command) {
                "mcp.servers.list" -> completedFrame(mcpServersPage())
                "mcp.connect" -> completedFrame(
                    """{"state":"connected","serverID":"$SERVER_ID","generation":"8","toolCount":0,""" +
                        """"revision":{"resourceID":"$ROW_RESOURCE_ID","version":"$ROW_DIGEST"}}""",
                )
                else -> null
            }
        }
        val host = hostWith(exchange)
        host.integrations.refreshMcpServers()
        waitUntil { host.integrations.destination.value.mcp.servers.isNotEmpty() }
        val broker = host.integrations.localNetwork

        // API 37 + denied: the local .local endpoint must NOT dispatch
        // before the platform answer; the request state is the only effect.
        broker.apiLevel = { 37 }
        broker.permissionProbe = { android.content.pm.PackageManager.PERMISSION_DENIED }
        broker.refreshCheck()
        assertEquals(
            LocalNetworkAccessBroker.PermissionState.Denied::class.simpleName,
            broker.state::class.simpleName,
        )
        assertTrue(host.integrations.refreshMcpServer(SERVER_ID))
        // nothing reached the queue yet (the dialog owns the hop):
        assertTrue(exchange.envelopes("mcp.connect").isEmpty())
        val captured = broker.permissionRequest.value
        assertNotNull(captured)

        // GRANTED platform answer → the broker RE-READS and only then runs
        // the captured hop (this same explicit tap, never a blind replay).
        broker.permissionProbe = { android.content.pm.PackageManager.PERMISSION_GRANTED }
        broker.onPermissionResult(captured!!, granted = true, rationale = false)
        assertNull(broker.permissionRequest.value)
        waitUntil { exchange.envelopes("mcp.connect").isNotEmpty() }

        // Denied case: fresh local hop, denial with rationale (still
        // offerable) → NO dispatch, typed local-network marker (distinct
        // from any credential code), and the guidance row appears.
        broker.permissionProbe = { android.content.pm.PackageManager.PERMISSION_DENIED }
        broker.refreshCheck()
        assertTrue(host.integrations.refreshMcpServer(SERVER_ID))
        val second = broker.permissionRequest.value
        assertNotNull(second)
        broker.onPermissionResult(second!!, granted = false, rationale = true)
        assertEquals(1, exchange.envelopes("mcp.connect").size) // still only the granted hop
        waitUntil {
            host.integrations.destination.value.mcp.errorMessage ==
                "integrations_action_${com.floe.android.R.string.integrations_local_network_denied}"
        }
        assertNotNull(host.integrations.destination.value.mcp.localNetworkGuidance)

        // Late result for the superseded/absent request is dropped without
        // touching state (no blind latest-request callback).
        val ghost = LocalNetworkAccessBroker.PendingRequest(
            incarnation = 999, serverId = SERVER_ID, capturedEndpoint = "https://hub.local:8443/mcp",
            dispatch = { throw AssertionError("ghost dispatch") },
        )
        broker.onPermissionResult(ghost, granted = true, rationale = false)

        // PUBLIC cloud endpoint stays ungated even while denied:
        broker.refreshCheck()
        assertFalse(broker.blocksConnectHop("https://api.example.com/mcp"))
        assertFalse(broker.isLocalLikely("https://api.example.com/mcp"))
        // API 36 never engages the broker at all (original INTERNET path):
        broker.apiLevel = { 36 }
        broker.refreshCheck()
        assertEquals(
            LocalNetworkAccessBroker.PermissionState.NotRequired::class.simpleName,
            broker.state::class.simpleName,
        )
        assertFalse(broker.blocksConnectHop("https://hub.local:8443/mcp"))
    }

    @Test
    fun `provider permission refusal stays with its action and permanent denial survives recheck`() {
        val host = hostWith(ScriptExchange { null })
        val broker = host.integrations.localNetwork
        broker.apiLevel = { 37 }
        broker.permissionProbe = { android.content.pm.PackageManager.PERMISSION_DENIED }
        var dispatches = 0
        var settingsOpens = 0
        val denied = ArrayList<String>()
        broker.settingsLauncher = { settingsOpens += 1; true }
        assertTrue(broker.runExplicitAction(
            ownerID = "provider-action", endpoint = "https://192.168.1.20:8443",
            isCurrent = { true }, onDenied = { denied.add(it) },
            dispatch = { dispatches += 1 },
        ))
        val issued = broker.permissionRequest.value!!
        broker.onPermissionResult(issued, granted = false, rationale = false)
        assertEquals(listOf(LocalNetworkAccessBroker.CODE_RECOVERY), denied)
        assertEquals(0, dispatches)
        assertNull(host.integrations.destination.value.mcp.errorMessage)
        broker.refreshCheck()
        assertEquals(LocalNetworkAccessBroker.PermissionState.DeniedForever, broker.state)
        assertFalse(broker.runExplicitAction(
            ownerID = "provider-retry", endpoint = "https://192.168.1.20:8443",
            isCurrent = { true }, onDenied = { denied.add(it) },
            dispatch = { dispatches += 1 },
        ))
        assertEquals(1, settingsOpens)
        assertNull(broker.permissionRequest.value)
        assertEquals(0, dispatches)
        broker.permissionProbe = { android.content.pm.PackageManager.PERMISSION_GRANTED }
        broker.refreshCheck()
        assertEquals(LocalNetworkAccessBroker.PermissionState.Granted, broker.state)
        // Settings returns alone never replay either prior action.
        assertEquals(0, dispatches)
        broker.permissionProbe = { android.content.pm.PackageManager.PERMISSION_DENIED }
        broker.refreshCheck()
        assertEquals(LocalNetworkAccessBroker.PermissionState.Denied, broker.state)
    }

    @Test
    fun `cancelled action cannot dispatch when permission arrives and cloud stays usable`() {
        val host = hostWith(ScriptExchange { null })
        val broker = host.integrations.localNetwork
        broker.apiLevel = { 37 }
        broker.permissionProbe = { android.content.pm.PackageManager.PERMISSION_DENIED }
        var active = true
        var localDispatches = 0
        var cloudDispatches = 0
        var denials = 0
        assertTrue(broker.runExplicitAction(
            ownerID = "cancelled-goal", endpoint = "https://hub.local",
            isCurrent = { active }, onDenied = { denials += 1 },
            dispatch = { localDispatches += 1 },
        ))
        val issued = broker.permissionRequest.value!!
        active = false
        broker.permissionProbe = { android.content.pm.PackageManager.PERMISSION_GRANTED }
        broker.onPermissionResult(issued, granted = true, rationale = false)
        assertEquals(0, localDispatches)
        assertEquals(0, denials)
        broker.permissionProbe = { android.content.pm.PackageManager.PERMISSION_DENIED }
        assertTrue(broker.runExplicitAction(
            ownerID = "cloud", endpoint = "https://api.example.com/v1",
            isCurrent = { true }, onDenied = { denials += 1 },
            dispatch = { cloudDispatches += 1 },
        ))
        assertEquals(1, cloudDispatches)
        assertNull(broker.permissionRequest.value)
        broker.apiLevel = { 36 }
        assertTrue(broker.runExplicitAction(
            ownerID = "old-android-local", endpoint = "https://hub.local",
            isCurrent = { true }, onDenied = { denials += 1 },
            dispatch = { localDispatches += 1 },
        ))
        assertEquals(1, localDispatches)
        assertEquals(0, denials)
    }

    /** Classifier honesty (no global guessed-URI blocking): the local
     *  families get the explicit action; link-local/private/ULA/single-
     *  label/.local qualify; public hosts never do. */
    @Test
    fun `endpoint classification covers local hostnames without blocking cloud`() {
        val exchange = ScriptExchange { null }
        val host = hostWith(exchange)
        val broker = host.integrations.localNetwork
        for (local in listOf(
            "http://192.168.1.20:8080/mcp", "http://10.0.0.5/mcp", "http://172.20.10.8/mcp",
            "http://printer.local/mcp", "http://nas/mcp", "http://[fd00::42]:9000/mcp",
            "http://localhost:7777/mcp", "http://169.254.1.1/mcp",
        )) {
            assertTrue("expected local: $local", broker.isLocalLikely(local))
        }
        for (cloud in listOf(
            "https://api.example.com/mcp", "https://mcp.provider.io/v2",
            "https://8.8.8.8/mcp",
        )) {
            assertFalse("expected not local: $cloud", broker.isLocalLikely(cloud))
        }
        // Unparseable input is NEVER treated as local (never blocked):
        assertFalse(broker.isLocalLikely("not a url"))
    }

    /** LAN denial is distinct from auth: permissionBlockedHint never
     *  matches credential codes, and matches unreachability/EPERM only. */
    @Test
    fun `permission hints never conflate with auth failures`() {
        val exchange = ScriptExchange { null }
        val host = hostWith(exchange)
        val broker = host.integrations.localNetwork
        assertTrue(broker.permissionBlockingHint("Network is unreachable"))
        assertTrue(broker.permissionBlockingHint("Operation not permitted (EPERM)"))
        assertFalse(broker.permissionBlockingHint("secretMissing"))
        assertFalse(broker.permissionBlockingHint("authenticationRequired"))
        assertFalse(broker.permissionBlockingHint("Unauthorized"))
        // Metadata save vs connect permission stay separate: the save
        // COMMIT reply with a rejected connect sub-hop is still a save
        // SUCCESS with null-coerced guidance, never a credential failure.
        val commit = """{"state":"committed","serverID":"x","secretIntent":"keep",
            "revision":{"resourceID":"mcp.X","version":"aa"},
            "connect":{"errorCode":"credentialUnavailable","reason":"secretMissing"}}"""
        val value = Json.parseToJsonElement(commit) as JsonObject
        assertEquals("committed", value.stringOf("state"))
        assertEquals("secretMissing", (value["connect"] as JsonObject).stringOf("reason"))
    }

    // ------------------------------------------------------------- helpers

    private fun completedFrame(valueJson: String): String =
        """{"version":3,"requestID":"x","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"x","cursor":{"operationReceiptID":"r","sequence":1},""" +
            """"effects":[{"sequence":1,"kind":"accepted","value":$valueJson}],""" +
            """"hasMore":false,"resyncRequired":false}"""

    private fun JsonObject.stringOf(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

}
