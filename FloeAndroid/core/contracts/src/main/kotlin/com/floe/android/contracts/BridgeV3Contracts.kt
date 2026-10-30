// SPDX-License-Identifier: MPL-2.0
package com.floe.android.contracts

import java.util.UUID

/**
 * Bridge protocol v3 typed contract projection (source only).
 *
 * This file mirrors the explicit integer wire version 3 validated by
 * `FloeAndroidCore/BridgeEnvelopeV3.swift`. It is a typed projection for
 * Kotlin callers and tests; it deliberately contains no JSON decoder, no
 * binder, no network client and no business execution. The Swift core remains
 * the single validation/authority implementation. Nothing here mints a run,
 * conversation, operation receipt or effect.
 *
 * Frozen v1/v2 contracts are untouched: [BridgeProtocol], [CommandEnvelope],
 * [EventCursor] and [ExecutionOwner] keep their existing meaning. A v3
 * envelope is never accepted by the v2 types and vice versa.
 *
 * Wire invariants mirrored here:
 * * `applicationConfiguration` has a closed host vocabulary and no owner;
 * * `conversationLifecycle` needs only a real taskID;
 * * `launch` is either an existing-conversation taskID or an explicit
 *   create-intent new identity (never a not-yet-created task/run);
 * * `taskExecution` requires taskID+runID and allows optional real env/job;
 * * `effect.poll` (`floe.effect-cursor/3`) is a separate async operation
 *   channel with an opaque host receipt and nonnegative sequence, and has no
 *   run/environment/job roles.
 */
object BridgeProtocolV3 {
    const val VERSION = 3

    /** Same strict request/output bound as v1/v2. */
    const val MAX_REQUEST_BYTES = BridgeProtocol.MAX_REQUEST_BYTES

    const val COMMAND_SCHEMA = "floe.command-envelope/3"
    const val RUN_EVENT_SCHEMA = "floe.event-cursor/3"
    const val EFFECT_SCHEMA = "floe.effect-cursor/3"

    val SUPPORTED_VERSIONS = listOf(1, 2, 3)

    /** Truly executable v3 operations in this source package. */
    val OPERATIONS = listOf("handshake", "credential.status")

    /** Staged schema-only channels; NOT working domain operations. */
    val STAGED_OPERATIONS = listOf("command.submit", "event.poll", "effect.poll")

    /**
     * Closed host-owned configuration vocabulary (19 declared labels).
     * Active command labels are providers/models/preferences/catalog/skills/
     * mcp/settings.websearch/conversations/capabilities/system/attachmentStaging
     * plus the five additive Settings-domain P0 labels below;
     * credentials, operations and settings.approval remain reserved for this
     * wire slice and are not commands merely because they are declared.
     */
    val CONFIGURATION_SCOPES = listOf(
        "providers", "models", "preferences", "catalog", "credentials",
        "skills", "mcp", "settings.approval", "settings.websearch",
        "conversations", "capabilities", "system", "operations",
        "attachmentStaging",
        // Settings-domain P0 additive labels (accepted rev3 contract).
        "settings.defaults", "memory", "personalization", "usage", "privacy",
    )

    val SCOPES = listOf(
        "applicationConfiguration", "conversationLifecycle", "launch", "taskExecution",
    )
}

/** Wire scope carries only the roles its semantics actually require. */
sealed interface BridgeV3Scope {
    enum class Kind(val wire: String) {
        APPLICATION_CONFIGURATION("applicationConfiguration"),
        CONVERSATION_LIFECYCLE("conversationLifecycle"),
        LAUNCH("launch"),
        TASK_EXECUTION("taskExecution"),
    }

    val kind: Kind

    /** Host-owned configuration scope; never carries execution identities. */
    data class ApplicationConfiguration(val configurationScope: String) : BridgeV3Scope {
        override val kind: Kind get() = Kind.APPLICATION_CONFIGURATION
        init {
            require(configurationScope in BridgeProtocolV3.CONFIGURATION_SCOPES) {
                "closed configuration vocabulary"
            }
        }
    }

    /** Durable conversation or live ephemeral session. No run/env/job roles. */
    data class ConversationLifecycle(val taskID: UUID) : BridgeV3Scope {
        override val kind: Kind get() = Kind.CONVERSATION_LIFECYCLE
        init { requireExplicit(taskID, "taskID") }
    }

    sealed interface Launch : BridgeV3Scope {
        override val kind: Kind get() = Kind.LAUNCH

        /** Existing conversation: real taskID, never a run identity. */
        data class ExistingConversation(val taskID: UUID) : Launch {
            init { requireExplicit(taskID, "taskID") }
        }

        /** New identity: no task/run exists yet; needs explicit create intent. */
        object NewIdentity : Launch
    }

    /**
     * Actual run scope. Environment/job are optional but syntactically real;
     * shape never proves they exist and never authorizes a default guest.
     */
    data class TaskExecution(
        val taskID: UUID,
        val runID: UUID,
        val environmentID: UUID? = null,
        val jobID: UUID? = null,
    ) : BridgeV3Scope {
        override val kind: Kind get() = Kind.TASK_EXECUTION
        init {
            requireExplicit(taskID, "taskID")
            requireExplicit(runID, "runID")
            environmentID?.let { requireExplicit(it, "environmentID") }
            jobID?.let { requireExplicit(it, "jobID") }
        }
    }
}

/** Opaque resource revision: values are identities and are never trimmed. */
data class BridgeV3Revision(val resourceID: String, val version: String) {
    init {
        require(resourceID.isNotBlank()) { "resourceID" }
        require(version.isNotBlank()) { "version" }
    }
}

/** Actual run-bound event cursor (`floe.event-cursor/3`). */
data class BridgeV3EventCursor(val runID: UUID, val sequence: Long) {
    init {
        requireExplicit(runID, "runID")
        require(sequence >= 0) { "nonnegative sequence" }
    }
}

/**
 * Async operation cursor (`floe.effect-cursor/3`).
 *
 * `operationReceiptID` is an opaque host-minted identity. Shape cannot prove
 * it exists for the current App instance; receipt existence, scoped result
 * visibility, replay bounds, detach/expiry and typed notFound/resync belong to
 * the later facade. No run/environment/job identity is part of this cursor.
 */
data class BridgeV3EffectCursor(val operationReceiptID: String, val sequence: Long) {
    init {
        require(operationReceiptID.isNotBlank()) { "operationReceiptID" }
        require(operationReceiptID.length <= 256) { "operationReceiptID bound" }
        require(operationReceiptID.none { it.isISOControl() }) { "opaque receipt" }
        require(sequence >= 0) { "nonnegative sequence" }
    }
}

/** Exactly one entry of the closed operation → scope matrix. */
data class BridgeV3CommandRule(
    val command: String,
    val scope: BridgeV3Scope.Kind,
    val configurationScope: String?,
    val revisionRequired: Boolean,
    val allowsCreateIntent: Boolean,
    val isRunEventPoll: Boolean = false,
)

/**
 * Closed matrix shared with the Swift source. A command absent here is
 * unknown; presenting it under another scope or configuration label never
 * widens authority. The Kotlin projection cannot add entries at runtime.
 */
object BridgeV3CommandMatrix {
    val ENTRIES: List<BridgeV3CommandRule> = listOf(
        // applicationConfiguration — host-owned configuration vocabulary.
        rule("config.providers.list", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "providers"),
        rule("config.provider.save", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "providers", revision = true, create = true),
        rule("config.provider.delete", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "providers", revision = true),
        rule("config.provider.probe", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "providers"),
        rule("config.models.list", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "models"),
        rule("config.model.save", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "models", revision = true),
        rule("config.catalog.search", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "catalog"),
        rule("config.preferences.get", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "preferences"),
        rule("config.preferences.save", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "preferences", revision = true),
        rule("config.websearch.get", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "settings.websearch"),
        rule("config.websearch.save", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "settings.websearch", revision = true),
        rule("conversation.list", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "conversations"),
        rule("conversation.search", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "conversations"),
        rule("capability.tools.list", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "capabilities"),
        rule("skills.list", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "skills"),
        rule("skills.install", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "skills", revision = true, create = true),
        rule("skills.uninstall", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "skills", revision = true),
        rule("mcp.servers.list", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "mcp"),
        rule("mcp.connect", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "mcp", revision = true, create = true),
        rule("mcp.disconnect", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "mcp", revision = true),
        rule("system.bootstrap", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "system"),
        rule("system.shutdown", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "system"),
        rule("system.lifecycle", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "system"),
        rule("attachment.stage", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "attachmentStaging"),
        rule("attachment.staging.read", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "attachmentStaging"),
        rule("attachment.staging.cancel", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "attachmentStaging"),
        rule("attachment.staging.discard", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "attachmentStaging"),

        // conversationLifecycle — task-only lifecycle; no run/env/job roles.
        rule("conversation.get", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE),
        rule("conversation.rename", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE, revision = true),
        rule("conversation.archive", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE, revision = true),
        rule("conversation.delete", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE, revision = true),
        rule("conversation.messagePage", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE),
        rule("temp.end", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE, revision = true),
        rule("temp.keep", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE, revision = true),
        rule("attachment.commit", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE, revision = true),
        rule("attachment.read", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE),
        rule("attachment.cancel", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE, revision = true),
        rule("content.read", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE),
        rule("content.read", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "conversations"),

        // launch — existing conversation vs explicit new identity.
        rule("run.start", BridgeV3Scope.Kind.LAUNCH, revision = true),
        rule("run.startTask", BridgeV3Scope.Kind.LAUNCH, revision = true, create = true),
        rule("conversation.create", BridgeV3Scope.Kind.LAUNCH, revision = true, create = true),
        rule("temp.start", BridgeV3Scope.Kind.LAUNCH, revision = true, create = true),

        // taskExecution — actual run scope; env/job optional but typed.
        rule("run.cancel", BridgeV3Scope.Kind.TASK_EXECUTION, revision = true),
        rule("run.retry", BridgeV3Scope.Kind.TASK_EXECUTION, revision = true),
        rule("run.steer", BridgeV3Scope.Kind.TASK_EXECUTION, revision = true),
        rule("run.queue", BridgeV3Scope.Kind.TASK_EXECUTION, revision = true),
        rule("run.input.edit", BridgeV3Scope.Kind.TASK_EXECUTION, revision = true),
        rule("run.input.remove", BridgeV3Scope.Kind.TASK_EXECUTION, revision = true),
        rule("run.input.reorder", BridgeV3Scope.Kind.TASK_EXECUTION, revision = true),
        rule("run.approval.resolve", BridgeV3Scope.Kind.TASK_EXECUTION, revision = true),
        rule("run.policy.update", BridgeV3Scope.Kind.TASK_EXECUTION, revision = true),
        rule("run.skillcancel", BridgeV3Scope.Kind.TASK_EXECUTION, revision = true),
        rule("run.snapshot", BridgeV3Scope.Kind.TASK_EXECUTION),
        rule("child.list", BridgeV3Scope.Kind.TASK_EXECUTION),
        rule("child.entries", BridgeV3Scope.Kind.TASK_EXECUTION),
        rule("event.poll", BridgeV3Scope.Kind.TASK_EXECUTION, runEventPoll = true),

        // Settings-domain P0 additive matrix (accepted rev3 contract,
        // 2026-10-19). APPEND-ONLY: the 57 entries above are unchanged.
        // No handler is registered in this package.
        rule("config.defaults.get", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "settings.defaults"),
        rule("config.defaults.save", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "settings.defaults", revision = true),
        rule("memory.list", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "memory"),
        rule("memory.get", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "memory"),
        rule("memory.add", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "memory", revision = true, create = true),
        rule("memory.update", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "memory", revision = true),
        rule("memory.delete", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "memory", revision = true),
        rule("memory.delete.bulk", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "memory", revision = true, create = true),
        rule("memory.search", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "memory"),
        rule("memory.candidates.list", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "memory"),
        rule("memory.candidate.resolve", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "memory", revision = true),
        rule("memory.organize.start", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "memory", revision = true, create = true),
        rule("memory.organize.proposal.read", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "memory"),
        rule("memory.organize.apply", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "memory", revision = true, create = true),
        rule("memory.organize.cancel", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "memory"),
        rule("personalization.get", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "personalization"),
        rule("personalization.revision.read", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "personalization"),
        rule("personalization.save", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "personalization", revision = true),
        rule("personalization.rollback", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "personalization", revision = true),
        rule("personalization.automatic.set", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "personalization", revision = true),
        rule("personalization.generate", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "personalization", revision = true, create = true),
        rule("personalization.generate.cancel", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "personalization"),
        // Third entry for the existing content.read command. The label-aware
        // lookup keeps it separate from the conversations entry.
        rule("content.read", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "personalization"),
        rule("usage.statistics.get", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "usage"),
        rule("privacy.summary.get", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "privacy"),
        rule("privacy.history.clear", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "privacy", revision = true),
        rule("privacy.modelConfiguration.clear", BridgeV3Scope.Kind.APPLICATION_CONFIGURATION, "privacy", revision = true),

        // goal-core code batch (2026-10-21, job-7efd60bb51d14f02): the three
        // additive run-control tuples, APPEND-ONLY and byte-aligned with the
        // Swift `BridgeV3.commandRules` and the golden matrix. plan.accept
        // rides LAUNCH with the existing-conversation digest CAS; goal.confirm
        // is a conversationLifecycle identity+revision confirm (NO run role —
        // the original confirm works after the run is terminal);
        // conversation.compact is a durable-history operation guarded
        // core-side by quiescence + the atomic writer proof. No child.create.
        rule("plan.accept", BridgeV3Scope.Kind.LAUNCH, revision = true),
        rule("goal.confirm", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE, revision = true),
        rule("conversation.compact", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE),

        // G04 workspace domain additive ledger (Main decisions D12/D14,
        // 2026-10-24): three conversationLifecycle tuples, APPEND-ONLY and
        // byte-aligned with Swift `BridgeV3.commandRules` and the golden
        // matrix. Outer revisions are NOT required: the opaque native
        // per-document revision token inside the closed workspace payload
        // grammar governs edits, and workspace.activate establishes the
        // exact durable ownership binding with a nativeEpoch-only payload.
        // The real envelope taskID is the only owner role; no run/env/job
        // identity and no absolute root can be presented. These keys stay
        // fail-closed until the real root-owned workspace extension binds
        // them; the projection cannot register a handler or widen authority.
        rule("workspace.read", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE),
        rule("workspace.write", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE),
        rule("workspace.activate", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE),

        // G07.3A interaction batch (2026-10-30): current-thread visible search
        // + durable user questions. APPEND-ONLY on top of the preserved
        // 90-entry baseline, exactly mirroring the Swift matrix tuples and
        // the 95-entry golden. `question.answer`/`question.cancel` stay
        // revisionRequired=false: their CAS identity (requestDigest/runID/
        // expectedRevision/nonce) travels in the payload, so the envelope
        // `stateful` flag is false.
        rule("conversation.messageSearch", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE),
        rule("conversation.messageWindow", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE),
        rule("question.pending", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE),
        rule("question.answer", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE),
        rule("question.cancel", BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE),
    )

    fun entry(command: String, scope: BridgeV3Scope.Kind): BridgeV3CommandRule? =
        ENTRIES.firstOrNull { it.command == command && it.scope == scope }

    fun entry(command: String, scope: BridgeV3Scope, configurationScope: String? = null): BridgeV3CommandRule? =
        ENTRIES.firstOrNull {
            it.command == command && it.scope == scope.kind &&
                (scope.kind != BridgeV3Scope.Kind.APPLICATION_CONFIGURATION ||
                    it.configurationScope == configurationScope)
        }

    private fun rule(
        command: String,
        scope: BridgeV3Scope.Kind,
        configurationScope: String? = null,
        revision: Boolean = false,
        create: Boolean = false,
        runEventPoll: Boolean = false,
    ): BridgeV3CommandRule = BridgeV3CommandRule(
        command = command,
        scope = scope,
        configurationScope = configurationScope,
        revisionRequired = revision,
        allowsCreateIntent = create,
        isRunEventPoll = runEventPoll,
    )
}

/**
 * A validated-shape command envelope. Structural rules only: no identity is
 * proven to exist and no operation is executed.
 *
 * JSON decoding belongs to the later facade and must reject unknown fields,
 * a schema other than [BridgeProtocolV3.COMMAND_SCHEMA], and every malformed
 * primitive before constructing this type.
 */
data class BridgeV3CommandEnvelope(
    val scope: BridgeV3Scope,
    val command: String,
    val stateful: Boolean,
    val revision: BridgeV3Revision?,
    val grantID: UUID?,
    val correlationID: String,
    val createIntent: Boolean = false,
) {
    /** `floe.command-envelope/3`; command.submit never shares another channel's schema. */
    val schema: String get() = BridgeProtocolV3.COMMAND_SCHEMA

    init {
        require(command.isNotBlank())
        require(command.length <= 128)
        require(!command.contains(' '))
        require(correlationID.isNotBlank())
        grantID?.let { requireExplicit(it, "grantID") }

        val entry = BridgeV3CommandMatrix.entry(command, scope, configurationScopeLabel(scope))
            ?: throw IllegalArgumentException("unknown command in this scope")
        if (scope.kind == BridgeV3Scope.Kind.APPLICATION_CONFIGURATION) {
            require(entry.configurationScope == configurationScopeLabel(scope)) {
                "closed configuration label"
            }
        }
        if (entry.isRunEventPoll) {
            throw IllegalArgumentException("event.poll uses BridgeV3RunEventPollEnvelope")
        }
        require(stateful == (createIntent || entry.revisionRequired)) {
            "stateful must match the closed revision rule"
        }
        if (createIntent) {
            require(entry.allowsCreateIntent) { "create intent is not allowed" }
            require(revision == null) { "new identity has no fabricated revision" }
        }
        if (entry.revisionRequired) {
            if (!createIntent) requireNotNull(revision) { "existing resource revision required" }
        } else {
            require(revision == null) { "stateless command carries no revision" }
        }
        if (entry.scope == BridgeV3Scope.Kind.LAUNCH) {
            if (entry.allowsCreateIntent) {
                require(scope is BridgeV3Scope.Launch.NewIdentity) {
                    "new launch command requires the new-identity scope"
                }
            } else {
                require(scope is BridgeV3Scope.Launch.ExistingConversation) {
                    "existing launch command requires a real taskID"
                }
            }
        }
        if (scope is BridgeV3Scope.Launch.NewIdentity) {
            require(createIntent) { "new launch identity requires explicit create intent" }
        }
        if (scope is BridgeV3Scope.Launch.ExistingConversation) {
            require(!createIntent) { "existing launch cannot claim create intent" }
        }
    }

    private companion object {
        fun configurationScopeLabel(scope: BridgeV3Scope): String? =
            (scope as? BridgeV3Scope.ApplicationConfiguration)?.configurationScope
    }
}

/**
 * Run-bound event poll. The cursor is the actual run cursor, never an
 * operation effect cursor, and the run identity must agree with the cursor.
 */
data class BridgeV3RunEventPollEnvelope(
    val run: BridgeV3Scope.TaskExecution,
    val cursor: BridgeV3EventCursor,
    val correlationID: String,
) {
    init {
        require(correlationID.isNotBlank())
        require(run.runID == cursor.runID) { "cursor run mismatch" }
    }

    val command: String get() = "event.poll"
    val stateful: Boolean get() = false
    /** `floe.event-cursor/3`, distinct from the command and effect schemas. */
    val schema: String get() = BridgeProtocolV3.RUN_EVENT_SCHEMA
}

/**
 * Async operation effect poll. It carries no owner/run/environment/job and no
 * fabricated effect; the opaque receipt only names a host operation whose
 * existence the later facade must verify for the current App instance.
 */
data class BridgeV3EffectPollEnvelope(
    val configurationScope: String,
    val effect: BridgeV3EffectCursor,
    val correlationID: String,
) {
    init {
        require(configurationScope in BridgeProtocolV3.CONFIGURATION_SCOPES) {
            "closed configuration vocabulary"
        }
        require(correlationID.isNotBlank())
    }

    val command: String get() = "effect.poll"
    val stateful: Boolean get() = false
    /** `floe.effect-cursor/3`, distinct from run events and commands. */
    val schema: String get() = BridgeProtocolV3.EFFECT_SCHEMA
}

/**
 * Explicit handshake projection. Availability is negotiation, not a business
 * capability claim: every staged channel stays unbound until a real host
 * binder exists.
 */
data class BridgeV3Handshake(
    val supportedVersions: List<Int>,
    val schemas: Map<String, String>,
    val operations: List<String>,
    val stagedOperations: List<BridgeV3StagedOperation>,
    val businessCapabilities: List<String>,
    val envelopeValidation: String,
) {
    companion object {
        fun current(): BridgeV3Handshake = BridgeV3Handshake(
            supportedVersions = BridgeProtocolV3.SUPPORTED_VERSIONS,
            schemas = mapOf(
                "command" to BridgeProtocolV3.COMMAND_SCHEMA,
                "runEvents" to BridgeProtocolV3.RUN_EVENT_SCHEMA,
                "operationEffects" to BridgeProtocolV3.EFFECT_SCHEMA,
            ),
            operations = BridgeProtocolV3.OPERATIONS,
            stagedOperations = listOf(
                BridgeV3StagedOperation("command.submit", false, BridgeProtocolV3.COMMAND_SCHEMA),
                BridgeV3StagedOperation("event.poll", false, BridgeProtocolV3.RUN_EVENT_SCHEMA),
                BridgeV3StagedOperation("effect.poll", false, BridgeProtocolV3.EFFECT_SCHEMA),
            ),
            businessCapabilities = emptyList(),
            envelopeValidation = "structuralOnly",
        )
    }
}

data class BridgeV3StagedOperation(
    val operation: String,
    val bound: Boolean,
    val schema: String,
)

private val ZERO_UUID: UUID = UUID(0L, 0L)

private fun requireExplicit(id: UUID, role: String) {
    require(id != ZERO_UUID) { "$role must be explicit, never a default UUID" }
}
