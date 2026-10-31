// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import com.floe.android.rootsystem.GrantRequest
import com.floe.android.rootsystem.OperationClaim
import com.floe.android.rootsystem.ScopeRoot
import com.floe.android.rootsystem.SystemOperation

/**
 * Server-side live grant registry. Grants are registered by the App host after
 * its ordinary admission/approval flow and are validated on every call. A
 * service death fences every grant (generation change); a new service process
 * starts empty and therefore requires fresh registration. There is no
 * persisted grant database and no self-grant path.
 */
class GrantRegistry(
    private val clock: () -> Long = System::currentTimeMillis,
    private val maxActiveGrants: Int = 32,
    private val maxLifetimeMillis: Long = 6 * 60 * 60 * 1000L,
    private val maxCancellations: Int = 64,
) {

    sealed interface Registration {
        data class Ok(val grantId: String) : Registration
        data class Rejected(val code: String) : Registration
    }

    sealed interface Verdict {
        data object Ok : Verdict
        data class Rejected(val code: String) : Verdict
    }

    private data class Grant(
        val request: GrantRequest,
        val registeredAtMillis: Long,
        val generation: Long,
        var revoked: Boolean = false,
    )

    private val grants = LinkedHashMap<String, Grant>()
    private val cancellations = LinkedHashMap<String, Long>()
    private var generation: Long = 0L

    fun currentGeneration(): Long = generation

    fun activeGrantCount(): Int = synchronized(this) { grants.size }

    fun register(
        request: GrantRequest,
        scopeBaseValidator: (ScopeRoot) -> String? = { null },
    ): Registration = synchronized(this) {
        if (!request.isWellFormed()) return Registration.Rejected("grant_shape")
        val now = clock()
        expire(now)
        if (grants.containsKey(request.grantId)) return Registration.Rejected("grant_duplicate")
        if (grants.size >= maxActiveGrants) return Registration.Rejected("grant_capacity")
        if (request.expiresAtMillis <= now) return Registration.Rejected("grant_expired")
        if (request.expiresAtMillis - now > maxLifetimeMillis) return Registration.Rejected("grant_lifetime")
        if (request.operations.isEmpty()) return Registration.Rejected("grant_operations")
        if (request.packageManagementAllowed &&
            SystemOperation.PACKAGE_FORCE_STOP !in request.operations
        ) {
            return Registration.Rejected("grant_management_shape")
        }
        val scopeIds = HashSet<String>()
        for (scope in request.scopes) {
            if (!scopeIds.add(scope.scopeId)) return Registration.Rejected("scope_duplicate")
            scopeBaseValidator(scope)?.let { return Registration.Rejected(it) }
        }
        grants[request.grantId] = Grant(request, now, generation)
        Registration.Ok(request.grantId)
    }

    fun check(
        claim: OperationClaim,
        operation: SystemOperation,
        scopeId: String?,
        write: Boolean,
    ): Verdict = synchronized(this) {
        if (!claim.isWellFormed()) return Verdict.Rejected("claim_shape")
        if (claim.requestId in cancellations) return Verdict.Rejected("cancelled")
        val grant = grants[claim.grantId] ?: return Verdict.Rejected("grant_unknown")
        if (grant.revoked) return Verdict.Rejected("revoked")
        if (grant.generation != generation) return Verdict.Rejected("fenced")
        val now = clock()
        if (now >= grant.request.expiresAtMillis) return Verdict.Rejected("expired")
        if (claim.epoch != grant.request.epoch) return Verdict.Rejected("epoch")
        if (claim.taskId != grant.request.taskId) return Verdict.Rejected("task")
        if (claim.runId != grant.request.runId) return Verdict.Rejected("run")
        if (operation !in grant.request.operations) return Verdict.Rejected("operation")
        if (operation == SystemOperation.PACKAGE_FORCE_STOP &&
            !grant.request.packageManagementAllowed
        ) {
            return Verdict.Rejected("management")
        }
        if (scopeId != null) {
            val scope = grant.request.scopes.firstOrNull { it.scopeId == scopeId }
                ?: return Verdict.Rejected("scope_unknown")
            if (write && !scope.writable) return Verdict.Rejected("scope_read_only")
        }
        Verdict.Ok
    }

    fun scope(claim: OperationClaim, scopeId: String): ScopeRoot? = synchronized(this) {
        grants[claim.grantId]?.request?.scopes?.firstOrNull { it.scopeId == scopeId }
    }

    fun cancel(requestId: String): Boolean = synchronized(this) {
        if (requestId.isBlank() || requestId.length > 128) return false
        cancellations[requestId] = clock()
        while (cancellations.size > maxCancellations) {
            val oldest = cancellations.keys.firstOrNull() ?: break
            cancellations.remove(oldest)
        }
        true
    }

    fun isCancelled(requestId: String): Boolean = synchronized(this) {
        requestId in cancellations
    }

    fun revoke(grantId: String): Boolean = synchronized(this) {
        grants[grantId]?.let {
            it.revoked = true
            true
        } ?: false
    }

    fun revokeAll() = synchronized(this) {
        grants.keys.toList().forEach { grants[it]?.revoked = true }
        grants.clear()
        cancellations.clear()
    }

    /** Called when the owning service process dies; all authority is fenced. */
    fun fenceAll() = synchronized(this) {
        generation += 1
        grants.clear()
        cancellations.clear()
    }

    fun expire(now: Long = clock()) = synchronized(this) {
        grants.entries.removeIf { now >= it.value.request.expiresAtMillis || it.value.revoked }
    }
}
