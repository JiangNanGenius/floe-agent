// SPDX-License-Identifier: MPL-2.0
package com.floe.android.contracts

import java.util.UUID

/**
 * Bridge protocol v2 envelope contract (append-only addition; the frozen v1
 * [BridgeProtocol] object and every existing type are unchanged).
 *
 * These DTOs mirror the Swift-side typed command/event envelope in
 * FloeAndroidCore/BridgeEnvelope.swift. Version 1 callers keep working as
 * before; version 2 exists only for envelope-shaped commands. The core
 * advertises `command.submit` / `event.poll` as staged schema support with
 * bound=false — they perform typed validation and fail closed with
 * runtimeUnavailable until the later host binder packages land. Nothing here
 * executes a task, provider or credential operation.
 */
object BridgeProtocolV2 {
    const val VERSION = 2

    /** Request bound stays 64 KiB; attachments use separate chunk streams. */
    const val MAX_REQUEST_BYTES = BridgeProtocol.MAX_REQUEST_BYTES
    const val ENVELOPE_SCHEMA = "floe.command-envelope/2"
    const val EVENT_CURSOR_SCHEMA = "floe.event-cursor/2"

    /** Truly executable v2 operations in the current foundation. */
    val OPERATIONS = listOf("handshake", "credential.status")

    /** Schema-only staged operations; NOT working domain operations. */
    val STAGED_OPERATIONS = listOf("command.submit", "event.poll")
}

/**
 * A bridge v2 command envelope. Exactly one scope authority may exist:
 * task-scoped commands carry an explicit [owner] (all four non-nil identity
 * UUIDs present — no environment defaults or fabricated values), while
 * global provider/model configuration carries only the host-owned
 * [configurationScope] string. Model JSON never produces either grant.
 *
 * The four owner fields are distinct roles, not value-unique slots. Equal
 * values are legitimate (for example a root `jobID` equal to its `runID`);
 * the frozen [ExecutionOwner] contract has no inequality requirement, and
 * value uniqueness would not prove authorship.
 *
 * [grantID] is a reference to a host-authored approval grant, never the
 * grant itself; [revision]/[cursor] are required by stateful commands the
 * same way [OperationContext] requires them in-process.
 */
data class CommandEnvelope(
    val scope: EnvelopeScope,
    val command: String,
    val stateful: Boolean,
    val revision: Revision?,
    val cursor: EventCursor?,
    val grantID: UUID?,
    val correlationID: String,
) {
    init {
        require(command.isNotBlank() && command.length <= 128 && !command.contains(' '))
        require(correlationID.isNotBlank())
        require(!stateful || revision != null)
        when (scope) {
            is EnvelopeScope.TaskExecution -> {
                val ids = listOf(
                    scope.owner.taskID, scope.owner.runID,
                    scope.owner.environmentID, scope.owner.jobID,
                )
                // Presence is guaranteed by the typed fields; only the
                // all-zero fabrication guard and cursor-run agreement remain.
                // Equal values across roles are allowed by design.
                require(ids.none { it == NIL_UUID }) { "explicit identity, no default UUIDs" }
                require(cursor == null || cursor.runID == scope.owner.runID)
            }
            is EnvelopeScope.ApplicationConfiguration -> {
                require(scope.hostScope.isNotBlank() && scope.hostScope.length <= 256)
            }
        }
    }

    companion object {
        private val NIL_UUID = UUID(0, 0)
    }
}

/** Scope authority for a v2 command; see [CommandEnvelope]. */
sealed interface EnvelopeScope {
    data class TaskExecution(val owner: ExecutionOwner) : EnvelopeScope
    /** Host-owned application-configuration scope for global provider/model
     * settings — never fabricated task/run/environment/job UUIDs. */
    data class ApplicationConfiguration(val hostScope: String) : EnvelopeScope
}

/** Availability of the fail-closed secret backend as reported by v2
 * `credential.status`. With no registered Keystore gateway the core answers
 * NEEDS_CONFIGURATION; there is no memory fallback. */
data class SecretBackendStatus(val registered: Boolean, val availability: Availability) {
    init {
        require(!registered || availability == Availability.AVAILABLE)
        require(registered || availability == Availability.NEEDS_CONFIGURATION)
    }
}
