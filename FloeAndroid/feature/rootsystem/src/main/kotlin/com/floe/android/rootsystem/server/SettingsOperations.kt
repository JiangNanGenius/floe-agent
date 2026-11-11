// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import com.floe.android.rootsystem.SettingItemReceipt
import com.floe.android.rootsystem.SettingReadResult
import com.floe.android.rootsystem.SettingsBatchReceipt
import com.floe.android.rootsystem.SettingsChange
import com.floe.android.rootsystem.SettingsChangeAction
import com.floe.android.rootsystem.policy.SettingsKeyPolicy

/**
 * The real, typed Settings-provider operations behind system.settings.read /
 * system.settings.write.
 *
 * Every child invocation is a FIXED, code-built argv into the validated
 * `settings` binary (`get`/`put`/`delete` grammar proven on the Samsung
 * reference) through [Runner] — the existing bounded process/cancellation
 * helper of [SystemOperations]. Model text can never become a shell, an argv
 * element, a namespace or a key: inputs arrive only from the closed
 * [SettingsKeyPolicy] table and have already passed strict grammar checks on
 * both sides of the binder.
 *
 * Semantics:
 *  - `system` keys use the trusted exact current user; `global` keys are
 *    device-wide and carry no user/profile target.
 *  - Every change retains the exact stored old value (absence included) via a
 *    pre-read, applies one bounded child, then decides success from a real
 *    post-read-back: put ok only when the stored value numerically equals the
 *    requested value; delete ok only when the key is absent afterwards. OEM
 *    refusals, clamps and provider errors are reported with the bounded real
 *    output tail, never fabricated.
 *  - Cancellation is cooperative: it aborts before the next item, preserves
 *    the completed receipts and flags the batch cancelled.
 */
internal class SettingsOperations(
    private val currentUser: () -> Int,
    private val runner: Runner,
) {

    /**
     * Thin seam over the existing process helper (concurrent drain, bounded
     * timeout, cooperative cancel). Implementations throw [SettingsException]
     * with the typed start/timeout/cancel code and return the real exit code.
     */
    fun interface Runner {
        fun run(
            argv: List<String>,
            timeoutMillis: Long,
            cancelled: () -> Boolean,
            onTail: (String) -> Unit,
        ): Int
    }

    class SettingsException(val code: String) : Exception(code)

    private data class StoredValue(val present: Boolean, val value: String?)

    fun read(namespace: String, key: String, cancelled: () -> Boolean): SettingReadResult {
        val spec = SettingsKeyPolicy.specFor(namespace, key)
            ?: throw SettingsException(if (namespace in SettingsKeyPolicy.SUPPORTED_NAMESPACES) "setting_key" else "setting_namespace")
        val stored = readStored(spec, cancelled)
        return SettingReadResult(
            namespace = spec.namespace,
            key = spec.key,
            value = stored.value,
            userId = if (spec.deviceWide) -1 else currentUser(),
            deviceWide = spec.deviceWide,
        )
    }

    fun write(changes: List<SettingsChange>, cancelled: () -> Boolean): SettingsBatchReceipt {
        val requests = changes.map {
            SettingsKeyPolicy.ChangeRequest(it.namespace, it.key, when (it.action) {
                SettingsChangeAction.PUT -> SettingsKeyPolicy.ChangeAction.PUT
                SettingsChangeAction.DELETE -> SettingsKeyPolicy.ChangeAction.DELETE
            }, it.value)
        }
        val checked = when (val result = SettingsKeyPolicy.checkBatch(requests)) {
            is SettingsKeyPolicy.BatchCheck.Ok -> result.changes
            is SettingsKeyPolicy.BatchCheck.Rejected -> throw SettingsException(result.code)
        }
        val completed = ArrayList<SettingItemReceipt>(checked.size)
        var batchCancelled = false
        for (change in checked) {
            if (cancelled()) {
                batchCancelled = true
                break
            }
            // Cancellation can also land INSIDE one item (child wait or
            // read-back): the in-flight item's outcome is unknown, so it is
            // neither rolled back nor faked — the batch stops, the completed
            // receipts are preserved and the remaining items count as
            // skipped.
            try {
                completed += applyOne(change, cancelled)
            } catch (failure: SettingsException) {
                if (failure.code == "cancelled") {
                    batchCancelled = true
                    break
                }
                throw failure
            }
        }
        return SettingsBatchReceipt(
            requested = checked.size,
            ok = completed.count { it.succeeded },
            failed = completed.count { !it.succeeded },
            skipped = checked.size - completed.size,
            cancelled = batchCancelled,
            items = completed,
        )
    }

    /**
     * One change end to end: retain old -> apply -> real read-back -> honest
     * decision. Item-level failures are returned as failed receipts so the
     * batch keeps its partial outcomes; only cancellation aborts the batch.
     */
    private fun applyOne(
        change: SettingsKeyPolicy.ChangeRequest,
        cancelled: () -> Boolean,
    ): SettingItemReceipt {
        val spec = SettingsKeyPolicy.specFor(change.namespace, change.key)
            ?: return itemReceipt(change, null, null, null, null, false, "setting_key", null)
        val user = if (spec.deviceWide) -1 else currentUser().also {
            if (it !in 0..999) throw SettingsException("user")
        }

        // 1) Retain the exact old stored value (absence included). A missing
        //    read-back refuses the item instead of mutating blindly.
        val old = try {
            readStored(spec, cancelled)
        } catch (failure: SettingsException) {
            if (failure.code == "cancelled") throw failure
            return itemReceipt(change, spec, user, null, null, false, "old_read_failed", failure.code)
        }
        if (cancelled()) throw SettingsException("cancelled")

        // 2) One bounded, code-built child for the validated action.
        val argv = childArgv(spec, change, user)
        var tail = ""
        val exit = try {
            runner.run(argv, OP_TIMEOUT_MILLIS, cancelled) { tail = it }
        } catch (failure: SettingsException) {
            if (failure.code == "cancelled") throw failure
            return itemReceipt(
                change, spec, user, old.value, null, false, failure.code, conciseTail(tail),
            )
        }
        if (cancelled()) throw SettingsException("cancelled")

        // 3) Real post-operation read-back decides the outcome.
        val effective = try {
            readStored(spec, cancelled)
        } catch (failure: SettingsException) {
            if (failure.code == "cancelled") throw failure
            return itemReceipt(
                change, spec, user, old.value, null, false, "readback_failed", failure.code,
            )
        }
        return when (change.action) {
            SettingsKeyPolicy.ChangeAction.PUT -> {
                val requested = change.value!!
                when {
                    exit != 0 -> itemReceipt(
                        change, spec, user, old.value, null, false, "setting_put_failed", conciseTail(tail),
                    )
                    !valuesEqual(spec, requested, effective.value) ->
                        // The OEM stored a different value (clamp/honor delay):
                        // report both strings instead of claiming success.
                        itemReceipt(
                            change, spec, user, old.value, effective.value, false,
                            "setting_effective_mismatch", null,
                        )
                    else -> itemReceipt(
                        change, spec, user, old.value, effective.value, true, "setting_put_ok", null,
                    )
                }
            }
            SettingsKeyPolicy.ChangeAction.DELETE -> when {
                exit != 0 -> itemReceipt(
                    change, spec, user, old.value, null, false, "setting_delete_failed", conciseTail(tail),
                )
                effective.present -> itemReceipt(
                    change, spec, user, old.value, effective.value, false, "setting_still_present", null,
                )
                else -> itemReceipt(
                    change, spec, user, old.value, null, true, "setting_delete_ok", null,
                )
            }
        }
    }

    /** Fixed validated argv; never model-supplied. */
    private fun childArgv(
        spec: SettingsKeyPolicy.KeySpec,
        change: SettingsKeyPolicy.ChangeRequest,
        user: Int,
    ): List<String> {
        val base = if (spec.deviceWide) {
            listOf(SETTINGS_BIN)
        } else {
            listOf(SETTINGS_BIN, "--user", user.toString())
        }
        return when (change.action) {
            SettingsKeyPolicy.ChangeAction.PUT ->
                base + listOf("put", spec.namespace, spec.key, change.value!!)
            SettingsKeyPolicy.ChangeAction.DELETE ->
                base + listOf("delete", spec.namespace, spec.key)
        }
    }

    private fun readArgv(spec: SettingsKeyPolicy.KeySpec, user: Int): List<String> =
        if (spec.deviceWide) {
            listOf(SETTINGS_BIN, "get", spec.namespace, spec.key)
        } else {
            listOf(SETTINGS_BIN, "get", "--user", user.toString(), spec.namespace, spec.key)
        }

    /**
     * `settings get` prints the stored string, or the literal `null` when the
     * key is absent; exit 0 is expected even for absent keys. A non-zero exit
     * is a real provider error and is propagated.
     */
    private fun readStored(spec: SettingsKeyPolicy.KeySpec, cancelled: () -> Boolean): StoredValue {
        val user = if (spec.deviceWide) -1 else currentUser()
        var tail = ""
        val exit = runner.run(readArgv(spec, user), READ_TIMEOUT_MILLIS, cancelled) { tail = it }
        if (cancelled()) throw SettingsException("cancelled")
        if (exit != 0) throw SettingsException("settings_read_failed")
        val line = tail.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .lastOrNull()
            ?: return StoredValue(present = false, value = null)
        if (line == "null") return StoredValue(present = false, value = null)
        return StoredValue(present = true, value = line.take(SettingsKeyPolicy.MAX_VALUE_LENGTH + 8))
    }

    /** INT/SCALE equality is numeric: stored "1.0" honors requested "1". */
    private fun valuesEqual(spec: SettingsKeyPolicy.KeySpec, requested: String, effective: String?): Boolean {
        if (effective == null) return false
        return when (spec.kind) {
            SettingsKeyPolicy.ValueKind.INT ->
                requested.toLongOrNull() == effective.toLongOrNull()
            SettingsKeyPolicy.ValueKind.SCALE ->
                requested.toDoubleOrNull() == effective.toDoubleOrNull()
        }
    }

    private fun itemReceipt(
        change: SettingsKeyPolicy.ChangeRequest,
        spec: SettingsKeyPolicy.KeySpec?,
        user: Int?,
        oldValue: String?,
        effectiveValue: String?,
        succeeded: Boolean,
        detailCode: String,
        failureDetail: String?,
    ): SettingItemReceipt {
        val deviceWide = spec?.deviceWide == true
        return SettingItemReceipt(
            namespace = change.namespace,
            key = change.key,
            action = when (change.action) {
                SettingsKeyPolicy.ChangeAction.PUT -> SettingsChangeAction.PUT
                SettingsKeyPolicy.ChangeAction.DELETE -> SettingsChangeAction.DELETE
            },
            oldValue = oldValue,
            requestedValue = change.value,
            effectiveValue = effectiveValue,
            userId = user ?: if (deviceWide) -1 else 0,
            deviceWide = deviceWide,
            succeeded = succeeded,
            detailCode = detailCode,
            failureDetail = failureDetail?.take(96),
        )
    }

    /**
     * Reduce a bounded child tail to one concise printable reason (first
     * Failure/Error-style line, otherwise the last non-empty line), matching
     * the shape of the package-operation receipts.
     */
    private fun conciseTail(outputTail: String): String? {
        val lines = outputTail.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .toList()
        if (lines.isEmpty()) return null
        val reason = lines.firstOrNull {
            it.contains("ailure", ignoreCase = true) ||
                it.contains("rror", ignoreCase = true) ||
                it.contains("denied", ignoreCase = true) ||
                it.contains("refused", ignoreCase = true) ||
                it.contains("xception", ignoreCase = true)
        } ?: lines.last()
        val cleaned = reason.filter { it.code >= 0x20 && it.code != 0x7F }.trim()
        return cleaned.take(96).ifEmpty { null }
    }

    private companion object {
        const val SETTINGS_BIN = "/system/bin/settings"
        const val OP_TIMEOUT_MILLIS = 10_000L
        const val READ_TIMEOUT_MILLIS = 10_000L
    }
}
