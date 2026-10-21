// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.UUID

/**
 * MAIN_ANDROID_PLATFORM_LAUNCH_OWNERSHIP_20261021 — the ONE launch/settle
 * provenance rule shared by the three platform launcher lanes (attachment
 * GetContent, Skills OpenDocumentTree, API 37 local-network permission).
 *
 * Problem: a launcher callback arrives LATE and carries no request identity
 * of its own. The composition must therefore remember WHICH pending request
 * a live platform picker/permission dialog was launched for, and refuse to
 * hand a late/restored callback to any other request. `rememberSaveable`
 * preserves that issued identity across Activity recreation — but the
 * controller-side incarnation counter restarts at 1 after process death, so
 * a restored "issued incarnation 1" can collide with a brand-new request 1
 * from the new process. An incarnation comparison alone cannot tell those
 * apart.
 *
 * Rule: each Application-owned controller lane mints an opaque per-process
 * [namespace]. The composition persists the encoded [LaunchKey]
 * (`namespace:incarnation`) for the single launch it issued. A callback is
 * DISPATCHED only when BOTH the lane's current namespace AND the current
 * pending request's incarnation match the persisted key; anything else is
 * DROPPED with no controller call and no state write. Consequences:
 *
 *  * Same process, same pending request -> dispatch to the exact request
 *    (the controller's own full-identity fence remains the final check).
 *  * Same process, request superseded while the old picker was showing ->
 *    the old callback drops; the lane then frees and the CURRENT pending
 *    may launch — the replacement never fires a second concurrent picker
 *    and the old result is never rebound to the new request.
 *  * Process death with a restored (old-namespace) callback or restored
 *    (old-namespace) issued key -> the stale callback drops, the stale
 *    issued key holds the lane until that callback settles, then the new
 *    process's pending launches under the new namespace. A counter reset
 *    collision can no longer bind an old result to a new request.
 *  * The persisted key carries ONLY an opaque UUID and a Long: no URI, no
 *    secret, no user content, no permission state.
 *
 * Nothing here is a second authority: the controllers' final exact
 * request/owner fences ([AttachmentImportController.onPickerResult],
 * [SkillsFolderStagingController.onTreeResult],
 * [LocalNetworkAccessBroker.onPermissionResult]) stay the deciding checks.
 */
object PlatformLaunchOwnership {

    /** Mint one opaque namespace for ONE lane of ONE Application-owned
     *  controller generation. Random UUID — proves only which process
     *  generation issued a launch; it never encodes user data. */
    fun mintNamespace(): String = UUID.randomUUID().toString()

    /** The immutable launch identity persisted by the composition. */
    data class LaunchKey(val namespace: String, val incarnation: Long) {

        /** Bundle-safe single-string form (`<namespace>:<incarnation>`).
         *  A namespace is a UUID (no ':'), so the last separator is
         *  unambiguous. */
        fun encode(): String = "$namespace$NAMESPACE_SEPARATOR$incarnation"

        companion object {
            private const val NAMESPACE_SEPARATOR = ':'

            /** Parse a persisted key; null/blank/malformed decode to null
             *  (a blank key means the lane is free). */
            fun decode(raw: String?): LaunchKey? {
                if (raw.isNullOrEmpty()) return null
                val separator = raw.lastIndexOf(NAMESPACE_SEPARATOR)
                if (separator <= 0 || separator == raw.length - 1) return null
                val namespace = raw.substring(0, separator)
                val incarnation = raw.substring(separator + 1).toLongOrNull()
                    ?: return null
                return LaunchKey(namespace, incarnation)
            }
        }
    }

    /** What the composition effect must do when the lane's pending-request
     *  flow changes. */
    sealed interface PendingDecision {
        /** Persist THIS key and launch the platform picker/permission
         *  dialog for it. */
        data class Launch(val savedKey: LaunchKey) : PendingDecision

        /** Do nothing: either no request is pending, or an earlier launch
         *  still owns the lane (a live picker may be showing, or a restored
         *  pre-process-death key is still awaiting its settling callback). */
        data object Hold : PendingDecision
    }

    /** What the composition effect must do when the platform launcher
     *  callback arrives. */
    sealed interface CallbackDecision {
        /** Hand the result to the lane controller for THIS exact pending
         *  request incarnation. */
        data class Dispatch(val incarnation: Long) : CallbackDecision

        /** Drop the callback: no controller call, no flow write, no
         *  cancel. The lane is freed either way. */
        data object Drop : CallbackDecision
    }

    /**
     * Decide whether a newly observed pending request may launch. The lane
     * launches at most one picker at a time: a non-null [savedKey] always
     * holds, INCLUDING when its namespace differs from [currentNamespace]
     * (a restored pre-process-death launch may still own a live platform
     * picker; freeing the lane here could stack a second picker whose
     * restored old result would then validate against the new key).
     */
    fun evaluatePending(
        savedKey: LaunchKey?,
        pendingIncarnation: Long?,
        currentNamespace: String,
    ): PendingDecision {
        if (pendingIncarnation == null) return PendingDecision.Hold
        if (savedKey != null) return PendingDecision.Hold
        return PendingDecision.Launch(LaunchKey(currentNamespace, pendingIncarnation))
    }

    /**
     * Decide what a platform callback means. ALWAYS frees the lane (the
     *  caller clears the persisted key): a restored callback from before
     *  process death must not pin the lane forever. Dispatch requires the
     *  FULL saved identity to still be current — same lane namespace AND
     *  the lane's current pending incarnation equal to the saved one.
     *  Namespace equality alone is not sufficient (a same-process request
     *  superseded while its picker was showing must not receive the old
     *  result), and incarnation equality alone is not sufficient (a
     *  post-process-death counter reset collides incarnations across
     *  namespaces).
     */
    fun evaluateCallback(
        savedKey: LaunchKey?,
        currentPendingIncarnation: Long?,
        currentNamespace: String,
    ): CallbackDecision {
        val saved = savedKey ?: return CallbackDecision.Drop
        if (saved.namespace != currentNamespace) return CallbackDecision.Drop
        if (currentPendingIncarnation == null ||
            currentPendingIncarnation != saved.incarnation
        ) {
            return CallbackDecision.Drop
        }
        return CallbackDecision.Dispatch(saved.incarnation)
    }

    /**
     * Mutable per-lane ledger over the pure rules above. One effect owns
     * exactly one ledger; the composition mirrors [savedKey] through
     * `rememberSaveable` (encoding/decoding with [LaunchKey]) so the
     * identity survives Activity recreation and re-enters evaluation after
     * process death. JVM tests drive this ledger directly to model
     * launch / settle / supersede / restored-key-collision / unrelated-lane
     * behavior without any Android framework.
     */
    class LaneLedger(
        /** The lane's CURRENT controller-generation namespace. */
        val namespace: String,
    ) {
        /** The launch identity currently handed to the platform launcher;
         *  null = the lane is free. */
        var savedKey: LaunchKey? = null
            private set

        /** The pending flow changed; returns the decision and records a
         *  launch claim. */
        fun onPending(pendingIncarnation: Long?): PendingDecision {
            val decision = evaluatePending(savedKey, pendingIncarnation, namespace)
            if (decision is PendingDecision.Launch) {
                savedKey = decision.savedKey
            }
            return decision
        }

        /** The platform callback arrived; ALWAYS settles the lane, then
         *  returns dispatch-or-drop. */
        fun onCallback(currentPendingIncarnation: Long?): CallbackDecision {
            val saved = savedKey
            savedKey = null
            return evaluateCallback(saved, currentPendingIncarnation, namespace)
        }

        /** Re-adopt a persisted key after composition recreation (the value
         *  the composition held in `rememberSaveable`); null clears. */
        fun restore(restoredKey: LaunchKey?) {
            savedKey = restoredKey
        }

        /** Host-side teardown / explicit cancel: free the lane. */
        fun release() {
            savedKey = null
        }
    }
}
