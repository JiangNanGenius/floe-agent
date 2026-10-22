// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

/**
 * The closed set of REAL Core-side operations that may own the foreground
 * service. The values mirror Main's settled architecture, nothing else:
 *  * ENVIRONMENT_INSTALL — the explicit user-initiated Linux environment
 *    preparation/installation work (one lease around preparation);
 *  * LOCAL_EXECUTION — an actual open runtime session (a real PTY session
 *    is owned work; an idle app is not);
 *  * AGENT_RUN — an actual Agent run whose id comes from the ORIGINAL
 *    runtime context/state (never a UI-minted guess);
 *  * DURABLE_JOB — an original durable job admitted by the runtime job
 *    authority. This module only holds TRANSIENT service ownership for it;
 *    the durable schema and jobs.submit semantics stay owned by the
 *    original job lifecycle (the FloeAndroidJobTools handoff), never here.
 */
enum class OperationKind {
    ENVIRONMENT_INSTALL,
    LOCAL_EXECUTION,
    AGENT_RUN,
    DURABLE_JOB,
}

/**
 * Routes the notification Stop action to the ACTUAL cancellation path the
 * operation's real owner already provides (the canonical run.cancel
 * command, the runtime session release channel, the installer's stop).
 * It is a REQUEST routed to the original owner: the lease stays owned and
 * nonterminal until the real work settles; firing this handler never
 * closes a lease, cancels a newer operation or touches another owner.
 */
fun interface RunStopHandler {
    fun onStopRequested()
}

/** Typed, honest acquisition outcomes. No automatic OS grants, no Settings
 *  launches and no permission dialogs are ever triggered from here; the
 *  visible POST_NOTIFICATIONS UX belongs to Main's Core UI. */
sealed class RunForegroundFailure(message: String) : Exception(message) {

    /** The OS/user blocks a *usable* foreground notification right now:
     *  POST_NOTIFICATIONS is not granted (API 33+) or notifications for the
     *  app/channel are blocked. Reporting success here would be false. */
    class NotificationsBlocked(reason: String) :
        RunForegroundFailure("foreground_notifications_blocked:$reason")

    /** The OS refused to start the foreground service itself (for example
     *  the background start-not-allowed window, or startForeground was
     *  refused). The operation may still run unfocused; the caller must
     *  report background availability honestly. */
    class StartDenied(reason: String) :
        RunForegroundFailure("foreground_start_denied:$reason")

    /** The lifecycle cannot serve right now for a non-permission reason:
     *  the build is not a recognized Core channel, the service did not
     *  confirm foreground within the bounded window, or the process-side
     *  registry refused. Never a fabricated success. */
    class Unavailable(reason: String) :
        RunForegroundFailure("foreground_unavailable:$reason")

    /** The exact operationID is ALREADY owned as a different kind (a
     *  different owner domain): the id is single-flight and the request
     *  is refused without mutating the live registration. Either the
     *  caller holds the same owner kind (idempotent attach) or the id is
     *  genuinely in conflict — never silently reassigned. */
    class OwnerConflict(
        val operationID: String,
        val existingKind: OperationKind,
        val requestedKind: OperationKind,
    ) : RunForegroundFailure(
        "foreground_owner_conflict:$operationID:existing=$existingKind:requested=$requestedKind"
    )
}

/** A stable operation id is a canonical UUID string: UI operations mint it
 *  at the explicit action; Agent/job ids arrive from the ORIGINAL runtime
 *  context. Anything else is refused before it can touch the registry. */
internal object OperationIds {
    fun normalize(operationID: String): String {
        val trimmed = operationID.trim()
        val parsed = try { java.util.UUID.fromString(trimmed) } catch (_: IllegalArgumentException) { null }
        // Accept only the canonical 8-4-4-4-12 lowercase-or-mixed UUID form;
        // round-trip through toString() rejects brace/hyphenless variants.
        require(parsed != null && parsed.toString().equals(trimmed, ignoreCase = true)) {
            "operationID must be a stable UUID string"
        }
        return parsed.toString()
    }
}

/**
 * Pure classifier shared by the controller (UI-thread preflight) and the
 * service (system-callback path). Inputs are read from the real framework
 * state by the caller; this function never guesses.
 */
internal object NotificationGate {
    enum class Block { NONE, POST_NOTIFICATIONS_REQUIRED, NOTIFICATIONS_DISABLED, CHANNEL_BLOCKED }

    fun classify(
        sdkInt: Int,
        postNotificationsGranted: Boolean,
        notificationsEnabled: Boolean,
        channelExists: Boolean,
        channelBlocked: Boolean,
    ): Block {
        if (sdkInt >= 33 && !postNotificationsGranted) return Block.POST_NOTIFICATIONS_REQUIRED
        if (!notificationsEnabled) return Block.NOTIFICATIONS_DISABLED
        if (channelExists && channelBlocked) return Block.CHANNEL_BLOCKED
        return Block.NONE
    }
}

/**
 * Pure copy selection so the notification text is testable without a
 * device. Deterministic precedence: the most user-meaningful visible work
 * wins; multiple kinds collapse to one aggregate line. Returns null only
 * when there is no held work at all — the service must then never show a
 * foreground notification from nothing.
 */
internal object NotificationCopy {
    enum class Key { AGENT_RUN, ENVIRONMENT_INSTALL, LOCAL_EXECUTION, DURABLE_JOB, MULTIPLE }

    fun keyFor(kinds: Set<OperationKind>): Key? = when {
        kinds.isEmpty() -> null
        kinds.size > 1 -> Key.MULTIPLE
        else -> when (kinds.single()) {
            OperationKind.AGENT_RUN -> Key.AGENT_RUN
            OperationKind.ENVIRONMENT_INSTALL -> Key.ENVIRONMENT_INSTALL
            OperationKind.LOCAL_EXECUTION -> Key.LOCAL_EXECUTION
            OperationKind.DURABLE_JOB -> Key.DURABLE_JOB
        }
    }
}
