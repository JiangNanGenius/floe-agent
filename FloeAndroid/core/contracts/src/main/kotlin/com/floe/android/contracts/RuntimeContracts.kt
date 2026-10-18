// SPDX-License-Identifier: MPL-2.0
package com.floe.android.contracts

import java.util.UUID

/** IDs survive bridge/process boundaries; a display name never selects an environment. */
data class ExecutionOwner(val taskID: UUID, val runID: UUID, val environmentID: UUID, val jobID: UUID)
enum class EnvironmentLayer { SESSION, PROJECT, SHARED, BASE }
data class EventCursor(val runID: UUID, val sequence: Long) { init { require(sequence >= 0) } }
data class Revision(val resourceID: String, val version: String) {
    init { require(resourceID.isNotBlank()); require(version.isNotBlank()) }
}
enum class Availability { AVAILABLE, NEEDS_CONFIGURATION, NEEDS_PERMISSION, NOT_IMPLEMENTED, UNSUPPORTED }
data class Capability(val id: String, val availability: Availability)
enum class Distribution { FULL, PLAY }

/** Imported content and model output cannot create these host-authored grants. */
data class OperationContext(val owner: ExecutionOwner, val grantID: UUID?, val expectedRevision: Revision?)
interface CancellationHandle { fun cancel() }
interface CredentialStore {
    suspend fun read(reference: String): ByteArray?
    suspend fun write(reference: String, value: ByteArray)
    suspend fun delete(reference: String)
}
interface CapabilitySource { fun capabilities(): List<Capability> }
interface EventSubscription : CancellationHandle { val cursor: EventCursor }

object BridgeProtocol { const val VERSION = 1; const val MAX_REQUEST_BYTES = 65_536 }
