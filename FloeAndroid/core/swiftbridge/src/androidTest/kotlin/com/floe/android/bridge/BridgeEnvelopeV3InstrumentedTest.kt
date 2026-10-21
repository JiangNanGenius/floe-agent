package com.floe.android.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.floe.android.contracts.BridgeProtocolV3
import com.floe.android.contracts.BridgeV3CommandMatrix
import org.json.JSONObject
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Device regression source for the explicit bridge protocol v3 wire contract.
 *
 * These cases must be executed by the qualifier only after the real shared
 * core `.so`, JNI library and APK are built. Every accepted shape below must
 * return the fail-closed `runtimeUnavailable` seam because no v3 binder is
 * registered in production: no case may report task success, a fabricated
 * run/conversation identity or an operation effect. Nothing here registers a
 * handler, starts a run, reads credentials or touches the network.
 */
@RunWith(AndroidJUnit4::class)
class BridgeEnvelopeV3InstrumentedTest {
    private val task = UUID.randomUUID().toString()
    private val run = UUID.randomUUID().toString()
    private val environment = UUID.randomUUID().toString()
    private val job = UUID.randomUUID().toString()
    private val zero = "00000000-0000-0000-0000-000000000000"

    private fun ownerJson(environmentID: String? = null, jobID: String? = null): String {
        val parts = mutableListOf("\"taskID\":\"$task\"", "\"runID\":\"$run\"")
        if (environmentID != null) parts += "\"environmentID\":\"$environmentID\""
        if (jobID != null) parts += "\"jobID\":\"$jobID\""
        return parts.joinToString(separator = ",", prefix = "{", postfix = "}")
    }

    private fun envelope(
        schema: String? = "floe.command-envelope/3",
        scope: String,
        configurationScope: String? = null,
        command: String,
        stateful: Boolean,
        owner: String? = null,
        revision: String? = null,
        cursor: String? = null,
        effect: String? = null,
        createIntent: Boolean? = null,
        payload: String? = null,
        correlation: String = "\"c-1\"",
    ): String {
        val parts = mutableListOf<String>()
        if (schema != null) parts += "\"schema\":\"$schema\""
        parts += "\"scope\":\"$scope\""
        if (configurationScope != null) parts += "\"configurationScope\":\"$configurationScope\""
        parts += "\"command\":\"$command\""
        parts += "\"stateful\":$stateful"
        if (owner != null) parts += "\"owner\":$owner"
        if (revision != null) parts += "\"revision\":$revision"
        if (cursor != null) parts += "\"cursor\":$cursor"
        if (effect != null) parts += "\"effect\":$effect"
        if (createIntent != null) parts += "\"createIntent\":$createIntent"
        if (payload != null) parts += "\"payload\":$payload"
        parts += "\"correlationID\":$correlation"
        return parts.joinToString(separator = ",", prefix = "{", postfix = "}")
    }

    private fun request(operation: String, body: String, requestID: String = "c-1"): String =
        """{"version":3,"requestID":"$requestID","operation":"$operation","envelope":$body}"""

    private fun exchange(request: String): JSONObject = JSONObject(SwiftCore.exchange(request))

    private fun assertInvalid(response: JSONObject, reason: String) {
        assertFalse(response.getBoolean("ok"))
        assertEquals("invalidEnvelope", response.getString("error"))
        assertEquals(reason, response.getString("reason"))
    }

    private fun assertUnbound(response: JSONObject, reason: String) {
        assertFalse(response.getBoolean("ok"))
        assertEquals("runtimeUnavailable", response.getString("error"))
        assertEquals(reason, response.getString("reason"))
        assertEquals(3, response.getInt("version"))
    }

    private fun strings(array: org.json.JSONArray): List<String> =
        (0 until array.length()).map(array::getString)

    @Test
    fun handshakeNegotiatesV3WithoutClaimingBusinessCapabilities() {
        val response = exchange("""{"version":3,"requestID":"h3","operation":"handshake"}""")
        assertEquals(3, response.getInt("version"))
        assertEquals("h3", response.getString("requestID"))
        assertEquals(listOf(1, 2, 3),
            (0 until response.getJSONArray("supportedVersions").length())
                .map(response.getJSONArray("supportedVersions")::getInt))
        val schemas = response.getJSONObject("schemas")
        assertEquals("floe.command-envelope/3", schemas.getString("command"))
        assertEquals("floe.event-cursor/3", schemas.getString("runEvents"))
        assertEquals("floe.effect-cursor/3", schemas.getString("operationEffects"))
        assertEquals(listOf("handshake", "credential.status"),
            strings(response.getJSONArray("operations")))
        assertEquals(0, response.getJSONArray("businessCapabilities").length())
        assertEquals("structuralOnly", response.getString("envelopeValidation"))
        val staged = response.getJSONArray("stagedOperations")
        assertEquals(3, staged.length())
        for (index in 0 until staged.length()) {
            assertFalse(staged.getJSONObject(index).getBoolean("bound"))
        }
        assertEquals(listOf("command.submit", "event.poll", "effect.poll"),
            (0 until staged.length()).map { staged.getJSONObject(it).getString("operation") })
    }

    @Test
    fun configurationLabelMatrixCannotRelabelAuthority() {
        val revision = """{"resourceID":"provider.p1","version":"sync-4"}"""
        val valid = exchange(request("command.submit",
            envelope(scope = "applicationConfiguration", configurationScope = "providers",
                command = "config.provider.save", stateful = true, revision = revision)))
        assertUnbound(valid, "commandBinderUnbound")
        val relabelled = exchange(request("command.submit",
            envelope(scope = "applicationConfiguration", configurationScope = "system",
                command = "config.provider.save", stateful = true, revision = revision)))
        assertInvalid(relabelled, "configurationScopeMismatch")
        val owner = exchange(request("command.submit",
            envelope(scope = "applicationConfiguration", configurationScope = "providers",
                command = "config.providers.list", stateful = false,
                owner = """{"taskID":"$task"}""")))
        assertInvalid(owner, "configurationScopeMustNotCarryOwner")
        // Pre-conversation staging is configuration vocabulary, no run needed.
        for (command in listOf("attachment.stage", "attachment.staging.read",
                "attachment.staging.cancel", "attachment.staging.discard")) {
            assertUnbound(exchange(request("command.submit",
                envelope(scope = "applicationConfiguration",
                    configurationScope = "attachmentStaging",
                    command = command, stateful = false))), "commandBinderUnbound")
        }
    }

    @Test
    fun conversationLifecycleRequiresTaskAndRejectsRunRoles() {
        val taskOnly = """{"taskID":"$task"}"""
        assertUnbound(exchange(request("command.submit",
            envelope(scope = "conversationLifecycle", command = "conversation.get",
                stateful = false, owner = taskOnly))), "commandBinderUnbound")
        assertInvalid(exchange(request("command.submit",
            envelope(scope = "conversationLifecycle", command = "conversation.get",
                stateful = false, owner = ownerJson()))),
            "conversationLifecycleMustNotCarryRunIdentity")
        assertInvalid(exchange(request("command.submit",
            envelope(scope = "conversationLifecycle", command = "conversation.get",
                stateful = false))), "missingTaskIdentity")
    }

    @Test
    fun launchDistinguishesExistingConversationFromCreateIntent() {
        val taskOnly = """{"taskID":"$task"}"""
        val revision = """{"resourceID":"conversation.$task","version":"7"}"""
        assertUnbound(exchange(request("command.submit",
            envelope(scope = "launch", command = "run.start", stateful = true,
                owner = taskOnly, revision = revision))), "commandBinderUnbound")
        assertInvalid(exchange(request("command.submit",
            envelope(scope = "launch", command = "run.start", stateful = true,
                revision = revision))), "missingTaskIdentity")
        assertInvalid(exchange(request("command.submit",
            envelope(scope = "launch", command = "run.start", stateful = true,
                owner = ownerJson(), revision = revision))),
            "launchMustNotCarryExecutionRoles")
        // A new launch never contains a not-yet-created task/run identity and
        // needs an explicit create intent instead of a fabricated revision.
        for (command in listOf("run.startTask", "conversation.create", "temp.start")) {
            assertUnbound(exchange(request("command.submit",
                envelope(scope = "launch", command = command, stateful = true,
                    createIntent = true))), "commandBinderUnbound")
            assertInvalid(exchange(request("command.submit",
                envelope(scope = "launch", command = command, stateful = true))),
                "createIntentRequired")
            assertInvalid(exchange(request("command.submit",
                envelope(scope = "launch", command = command, stateful = true,
                    owner = taskOnly, createIntent = true))),
                "newIdentityMustNotCarryOwner")
        }
    }

    @Test
    fun taskExecutionAllowsOptionalRealEnvironmentAndJob() {
        // Absent env/job is the v3 correction; it still reaches the unbound
        // seam and never fabricates a run.
        assertUnbound(exchange(request("command.submit",
            envelope(scope = "taskExecution", command = "run.snapshot",
                stateful = false, owner = ownerJson()))), "commandBinderUnbound")
        // Present env/job must be real-looking explicit UUIDs, not defaults.
        assertUnbound(exchange(request("command.submit",
            envelope(scope = "taskExecution", command = "run.snapshot",
                stateful = false, owner = ownerJson(environment, job)))),
            "commandBinderUnbound")
    }

    @Test
    fun taskExecutionRejectsMalformedOrAllZeroRoles() {
        assertInvalid(exchange(request("command.submit",
            envelope(scope = "taskExecution", command = "run.snapshot",
                stateful = false, owner = ownerJson(zero)))), "invalidOwnerenvironmentID")
        assertInvalid(exchange(request("command.submit",
            envelope(scope = "taskExecution", command = "run.snapshot",
                stateful = false, owner = ownerJson("not-a-uuid")))), "invalidOwnerenvironmentID")
        assertInvalid(exchange(request("command.submit",
            envelope(scope = "taskExecution", command = "run.snapshot",
                stateful = false, owner = ownerJson(null, zero)))), "invalidOwnerjobID")
        assertInvalid(exchange(request("command.submit",
            envelope(scope = "taskExecution", command = "run.snapshot",
                stateful = false))), "missingExecutionOwner")
    }

    @Test
    fun effectPollIsAsyncOperationChannelWithoutRunIdentity() {
        val effect = """{"operationReceiptID":"receipt-device-1","sequence":0}"""
        val accepted = exchange(request("effect.poll",
            envelope(schema = "floe.effect-cursor/3", scope = "applicationConfiguration",
                configurationScope = "providers", command = "effect.poll",
                stateful = false, effect = effect)))
        assertUnbound(accepted, "effectPumpUnbound")
        // No effect, receipt or run may be synthesised by the wire package.
        assertFalse(accepted.has("operationReceiptID"))
        assertFalse(accepted.has("runID"))
        assertInvalid(exchange(request("effect.poll",
            envelope(schema = "floe.effect-cursor/3", scope = "applicationConfiguration",
                configurationScope = "providers", command = "effect.poll",
                stateful = false, effect = """{"operationReceiptID":"r","sequence":-1}"""))),
            "invalidEffectCursor")
        assertInvalid(exchange(request("effect.poll",
            envelope(schema = "floe.effect-cursor/3", scope = "applicationConfiguration",
                configurationScope = "providers", command = "effect.poll",
                stateful = false))), "missingEffectCursor")
        assertInvalid(exchange(request("effect.poll",
            envelope(schema = "floe.command-envelope/3", scope = "applicationConfiguration",
                configurationScope = "providers", command = "effect.poll",
                stateful = false, effect = effect))), "schemaRoleMismatch")
    }

    @Test
    fun runEventPollRequiresRunCursorNotEffectCursor() {
        assertUnbound(exchange(request("event.poll",
            envelope(schema = "floe.event-cursor/3", scope = "taskExecution",
                command = "event.poll", stateful = false,
                owner = ownerJson(), cursor = """{"runID":"$run","sequence":0}"""))),
            "eventPumpUnbound")
        assertInvalid(exchange(request("event.poll",
            envelope(schema = "floe.event-cursor/3", scope = "taskExecution",
                command = "event.poll", stateful = false,
                owner = ownerJson()))), "missingEventCursor")
        assertInvalid(exchange(request("event.poll",
            envelope(schema = "floe.event-cursor/3", scope = "taskExecution",
                command = "event.poll", stateful = false,
                owner = ownerJson(), cursor = """{"runID":"$environment","sequence":0}"""))),
            "cursorRunMismatch")
        // An operation-effect or command schema never impersonates a run event.
        assertInvalid(exchange(request("event.poll",
            envelope(schema = "floe.effect-cursor/3", scope = "taskExecution",
                command = "event.poll", stateful = false, owner = ownerJson(),
                cursor = """{"runID":"$run","sequence":0}"""))),
            "schemaRoleMismatch")
        assertInvalid(exchange(request("event.poll",
            envelope(schema = "floe.command-envelope/3", scope = "taskExecution",
                command = "event.poll", stateful = false, owner = ownerJson(),
                cursor = """{"runID":"$run","sequence":0}"""))),
            "schemaRoleMismatch")
        assertInvalid(exchange(request("command.submit",
            envelope(scope = "taskExecution", command = "run.snapshot", stateful = false,
                owner = ownerJson(), cursor = """{"runID":"$run","sequence":0}"""))),
            "cursorRoleMismatch")
    }

    @Test
    fun versionTwoStillRequiresAllFourExecutionRoles() {
        // Frozen v2 is not relaxed by v3's optional role rule.
        val v2 = """{"version":2,"requestID":"c-1","operation":"command.submit","envelope":{"scope":"taskExecution","owner":{"taskID":"$task","runID":"$run"},"command":"run.snapshot","stateful":false,"correlationID":"c-1"}}"""
        val response = exchange(v2)
        assertFalse(response.getBoolean("ok"))
        assertEquals("invalidEnvelope", response.getString("error"))
        assertEquals("invalidOwnerenvironmentID", response.getString("reason"))
    }

    @Test
    fun versionThreeNeverReinterpretsAV2Payload() {
        val legacy = """{"scope":"taskExecution","owner":${ownerJson(environment, job)},"command":"run.snapshot","stateful":false,"correlationID":"c-1"}"""
        val missingSchema = exchange(request("command.submit", legacy))
        assertInvalid(missingSchema, "missingSchema")
        val v2Schema = exchange(request("command.submit",
            envelope(schema = "floe.command-envelope/2", scope = "taskExecution",
                command = "run.snapshot", stateful = false,
                owner = ownerJson(environment, job))))
        assertInvalid(v2Schema, "schemaMismatch")
    }

    @Test
    fun acceptedShapesNeverReportDomainSuccess() {
        val bodies = listOf(
            envelope(scope = "taskExecution", command = "run.snapshot", stateful = false,
                owner = ownerJson()),
            envelope(scope = "conversationLifecycle", command = "conversation.get",
                stateful = false, owner = """{"taskID":"$task"}"""),
            envelope(scope = "launch", command = "run.startTask", stateful = true,
                createIntent = true),
            envelope(scope = "applicationConfiguration", configurationScope = "providers",
                command = "config.provider.save", stateful = true,
                revision = """{"resourceID":"provider.p1","version":"1"}"""),
        )
        for (body in bodies) {
            val response = exchange(request("command.submit", body))
            assertFalse(response.getBoolean("ok"))
            assertEquals("runtimeUnavailable", response.getString("error"))
            assertEquals("commandBinderUnbound", response.getString("reason"))
        }
    }
    @Test
    fun settingsDomainMatrixAppends27TuplesUnderFiveLabels() {
        // Accepted rev3 additive tuples. No handler exists, so every valid
        // shape must still terminate at the typed unbound seam.
        val digest = "sha256:" + "a".repeat(64)
        val revision = """{"resourceID":"settings.defaults","version":"$digest"}"""
        assertUnbound(exchange(request("command.submit",
            envelope(scope = "applicationConfiguration",
                configurationScope = "settings.defaults",
                command = "config.defaults.save", stateful = true,
                revision = revision,
                payload = """{"values":{"verifyFinalAnswer":true}}"""))),
            "commandBinderUnbound")
        assertUnbound(exchange(request("command.submit",
            envelope(scope = "applicationConfiguration", configurationScope = "memory",
                command = "memory.add", stateful = true, createIntent = true,
                payload = """{"content":"hello","scope":{"kind":"user"}}"""))),
            "commandBinderUnbound")
        assertUnbound(exchange(request("command.submit",
            envelope(scope = "applicationConfiguration", configurationScope = "memory",
                command = "memory.organize.start", stateful = true, createIntent = true,
                payload = """{"mode":"reviewFirst","includeSemantic":false}"""))),
            "commandBinderUnbound")
        assertUnbound(exchange(request("command.submit",
            envelope(scope = "applicationConfiguration",
                configurationScope = "personalization",
                command = "personalization.generate", stateful = true,
                createIntent = true, payload = """{"kind":"soul"}"""))),
            "commandBinderUnbound")
        assertUnbound(exchange(request("command.submit",
            envelope(scope = "applicationConfiguration", configurationScope = "usage",
                command = "usage.statistics.get", stateful = false,
                payload = """{"dimension":"model","limit":10}"""))),
            "commandBinderUnbound")
        assertUnbound(exchange(request("command.submit",
            envelope(scope = "applicationConfiguration", configurationScope = "privacy",
                command = "privacy.summary.get", stateful = false))),
            "commandBinderUnbound")
        // The five new labels are declared; the three reserved labels stay
        // command-free.
        val newLabels = setOf("settings.defaults", "memory", "personalization",
            "usage", "privacy")
        for (label in newLabels) {
            val rules = BridgeV3CommandMatrix.ENTRIES.filter {
                it.configurationScope == label
            }
            assertTrue("empty additive label $label", rules.isNotEmpty())
        }
        assertEquals(87, BridgeV3CommandMatrix.ENTRIES.size)
        assertEquals(19, BridgeProtocolV3.CONFIGURATION_SCOPES.size)
        // Uniqueness includes configurationScope; the third content.read
        // entry intentionally shares scope+command with the conversations one.
        val keys = BridgeV3CommandMatrix.ENTRIES.map {
            "${it.scope.wire}|${it.configurationScope ?: ""}|${it.command}"
        }
        assertEquals(BridgeV3CommandMatrix.ENTRIES.size, keys.toSet().size)
        assertEquals(57, BridgeV3CommandMatrix.ENTRIES.take(57).map {
            "${it.scope.wire}|${it.configurationScope ?: ""}|${it.command}"
        }.toSet().size)
        assertEquals(86, BridgeV3CommandMatrix.ENTRIES.map {
            "${it.scope.wire}|${it.command}"
        }.toSet().size)
        assertEquals(2, BridgeV3CommandMatrix.ENTRIES.count {
            it.scope == com.floe.android.contracts.BridgeV3Scope.Kind.APPLICATION_CONFIGURATION &&
                it.command == "content.read"
        })
        for (reserved in listOf("credentials", "settings.approval", "operations")) {
            assertTrue("reserved label has commands: $reserved",
                BridgeV3CommandMatrix.ENTRIES.none {
                    it.configurationScope == reserved
                })
        }
    }

    @Test
    fun settingsDomainCreateOnlyRequiresExplicitIntent() {
        val revision = """{"resourceID":"r","version":"1"}"""
        assertInvalid(exchange(request("command.submit",
            envelope(scope = "applicationConfiguration", configurationScope = "memory",
                command = "memory.add", stateful = true, revision = revision,
                payload = """{"content":"hello","scope":{"kind":"user"}}"""))),
            "createIntentRequired")
        assertInvalid(exchange(request("command.submit",
            envelope(scope = "applicationConfiguration",
                configurationScope = "personalization",
                command = "personalization.generate", stateful = true,
                revision = revision, payload = """{"kind":"soul"}"""))),
            "createIntentRequired")
        assertInvalid(exchange(request("command.submit",
            envelope(scope = "applicationConfiguration", configurationScope = "memory",
                command = "memory.add", stateful = true, createIntent = true,
                payload = """{"content":"hello","scope":{"kind":"user"},"dbPath":"/tmp/x"}"""))),
            "unknownMemoryField")
    }

    @Test
    fun settingsDomainContentReadLabelIsolation() {
        val valid = """{"handle":"h-1","offsetBytes":0,"maxBytes":1024}"""
        assertUnbound(exchange(request("command.submit",
            envelope(scope = "applicationConfiguration",
                configurationScope = "personalization", command = "content.read",
                stateful = false, payload = valid))), "commandBinderUnbound")
        assertUnbound(exchange(request("command.submit",
            envelope(scope = "applicationConfiguration",
                configurationScope = "conversations", command = "content.read",
                stateful = false, payload = valid))), "commandBinderUnbound")
        // Only the personalization entry is settings-validated.
        assertInvalid(exchange(request("command.submit",
            envelope(scope = "applicationConfiguration",
                configurationScope = "personalization", command = "content.read",
                stateful = false,
                payload = """{"handle":"","offsetBytes":0,"maxBytes":1024}"""))),
            "emptyPayloadField:handle")
        assertInvalid(exchange(request("command.submit",
            envelope(scope = "applicationConfiguration",
                configurationScope = "personalization", command = "content.read",
                stateful = false,
                payload = """{"handle":"h","offsetBytes":0,"maxBytes":32769}"""))),
            "invalidChunkRange")
        // Wrong label never widens authority.
        assertInvalid(exchange(request("command.submit",
            envelope(scope = "applicationConfiguration", configurationScope = "usage",
                command = "memory.list", stateful = false, payload = "{}"))),
            "configurationScopeMismatch")
    }

}
