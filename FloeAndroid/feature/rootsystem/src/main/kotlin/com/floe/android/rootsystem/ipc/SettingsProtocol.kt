// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.ipc

import android.os.Bundle
import com.floe.android.rootsystem.SettingItemReceipt
import com.floe.android.rootsystem.SettingReadResult
import com.floe.android.rootsystem.SettingsBatchReceipt
import com.floe.android.rootsystem.SettingsChange
import com.floe.android.rootsystem.SettingsChangeAction
import com.floe.android.rootsystem.policy.SettingsKeyPolicy

/**
 * Bounded codecs for the two appended settings transactions (readSettings /
 * writeSettings). Request bundles are built here from typed, policy-validated
 * values only — never from model text — and replies are parsed fail-closed.
 * Keys live in this file so [BinderProtocol] itself stays nearly untouched;
 * the wire version remains 3 because none of the appended transactions has
 * shipped publicly and the first nineteen legacy positions are preserved.
 */
object SettingsProtocol {

    const val KEY_NAMESPACE = "namespace"
    const val KEY_SETTING_KEY = "settingKey"
    const val KEY_SETTING_VALUE = "settingValue"
    const val KEY_SETTING_ACTION = "settingAction"
    const val KEY_SETTING_USER = "settingUser"
    const val KEY_SETTING_DEVICE_WIDE = "settingDeviceWide"
    const val KEY_SETTING_PRESENT = "settingPresent"
    const val KEY_SETTINGS_CHANGES = "settingsChanges"
    const val KEY_SETTINGS_RECEIPTS = "settingsReceipts"
    const val KEY_OLD_VALUE = "oldValue"
    const val KEY_OLD_PRESENT = "oldPresent"
    const val KEY_EFFECTIVE_VALUE = "effectiveValue"
    const val KEY_EFFECTIVE_PRESENT = "effectivePresent"
    const val KEY_SETTING_SUCCEEDED = "settingSucceeded"
    const val KEY_SETTING_DETAIL = "settingDetail"
    const val KEY_BATCH_REQUESTED = "settingsBatchRequested"
    const val KEY_BATCH_CANCELLED = "settingsBatchCancelled"

    private const val ACTION_PUT = "put"
    private const val ACTION_DELETE = "delete"

    fun readRequest(namespace: String, key: String): Bundle = Bundle().apply {
        putString(KEY_NAMESPACE, namespace)
        putString(KEY_SETTING_KEY, key)
    }

    fun namespaceOf(request: Bundle?): String? =
        request?.getString(KEY_NAMESPACE)?.takeIf { it in SettingsKeyPolicy.SUPPORTED_NAMESPACES }

    fun keyOf(request: Bundle?): String? =
        request?.getString(KEY_SETTING_KEY)?.takeIf { it.length <= 64 }

    fun changeBundles(changes: List<SettingsChange>): Array<Bundle> = changes.map { change ->
        Bundle().apply {
            putString(KEY_NAMESPACE, change.namespace)
            putString(KEY_SETTING_KEY, change.key)
            putString(
                KEY_SETTING_ACTION,
                when (change.action) {
                    SettingsChangeAction.PUT -> ACTION_PUT
                    SettingsChangeAction.DELETE -> ACTION_DELETE
                },
            )
            change.value?.let { putString(KEY_SETTING_VALUE, it) }
        }
    }.toTypedArray()

    /**
     * Parse the changes array fail-closed: bounded, closed namespace/key
     * shape, closed action tokens, bounded value length. Value GRAMMAR and
     * ranges are enforced separately by SettingsKeyPolicy on both sides.
     */
    fun parseChanges(request: Bundle?): List<SettingsChange>? {
        val raw = request?.getParcelableArray(KEY_SETTINGS_CHANGES) ?: return null
        if (raw.isEmpty() || raw.size > SettingsKeyPolicy.MAX_BATCH_CHANGES) return null
        val out = ArrayList<SettingsChange>(raw.size)
        for (item in raw) {
            val bundle = item as? Bundle ?: return null
            val namespace = bundle.getString(KEY_NAMESPACE)
                ?.takeIf { it in SettingsKeyPolicy.SUPPORTED_NAMESPACES } ?: return null
            val key = bundle.getString(KEY_SETTING_KEY)?.takeIf { it.isNotEmpty() && it.length <= 64 }
                ?: return null
            val action = when (bundle.getString(KEY_SETTING_ACTION)) {
                ACTION_PUT -> SettingsChangeAction.PUT
                ACTION_DELETE -> SettingsChangeAction.DELETE
                else -> return null
            }
            val value = bundle.getString(KEY_SETTING_VALUE)?.takeIf {
                it.length <= SettingsKeyPolicy.MAX_VALUE_LENGTH
            }
            if (action == SettingsChangeAction.PUT && value == null) return null
            if (action == SettingsChangeAction.DELETE && value != null) return null
            out.add(SettingsChange(namespace, key, action, value))
        }
        return out
    }

    fun readResultBundle(result: SettingReadResult): Bundle = Bundle().apply {
        putString(KEY_NAMESPACE, result.namespace)
        putString(KEY_SETTING_KEY, result.key)
        putBoolean(KEY_SETTING_PRESENT, result.value != null)
        result.value?.let { putString(KEY_SETTING_VALUE, it.take(64)) }
        putInt(KEY_SETTING_USER, result.userId)
        putBoolean(KEY_SETTING_DEVICE_WIDE, result.deviceWide)
    }

    fun readResult(reply: Bundle?): SettingReadResult? {
        if (reply == null) return null
        val namespace = reply.getString(KEY_NAMESPACE) ?: return null
        val key = reply.getString(KEY_SETTING_KEY) ?: return null
        val present = reply.getBoolean(KEY_SETTING_PRESENT, false)
        val value = reply.getString(KEY_SETTING_VALUE)?.take(64)
        if (present && value == null) return null
        return SettingReadResult(
            namespace = namespace,
            key = key,
            value = if (present) value else null,
            userId = reply.getInt(KEY_SETTING_USER, 0),
            deviceWide = reply.getBoolean(KEY_SETTING_DEVICE_WIDE, false),
        )
    }

    fun itemReceiptBundle(receipt: SettingItemReceipt): Bundle = Bundle().apply {
        putString(KEY_NAMESPACE, receipt.namespace)
        putString(KEY_SETTING_KEY, receipt.key)
        putString(
            KEY_SETTING_ACTION,
            when (receipt.action) {
                SettingsChangeAction.PUT -> ACTION_PUT
                SettingsChangeAction.DELETE -> ACTION_DELETE
            },
        )
        putBoolean(KEY_OLD_PRESENT, receipt.oldValue != null)
        receipt.oldValue?.let { putString(KEY_OLD_VALUE, it.take(64)) }
        receipt.requestedValue?.let { putString(KEY_SETTING_VALUE, it.take(64)) }
        putBoolean(KEY_EFFECTIVE_PRESENT, receipt.effectiveValue != null)
        receipt.effectiveValue?.let { putString(KEY_EFFECTIVE_VALUE, it.take(64)) }
        putInt(KEY_SETTING_USER, receipt.userId)
        putBoolean(KEY_SETTING_DEVICE_WIDE, receipt.deviceWide)
        putBoolean(KEY_SETTING_SUCCEEDED, receipt.succeeded)
        putString(KEY_SETTING_DETAIL, receipt.detailCode.take(48))
        receipt.failureDetail?.let { putString(BinderProtocol.KEY_FAILURE_DETAIL, it.take(96)) }
    }

    fun batchReceiptBundle(receipt: SettingsBatchReceipt): Bundle = Bundle().apply {
        putInt(KEY_BATCH_REQUESTED, receipt.requested)
        putParcelableArray(
            KEY_SETTINGS_RECEIPTS,
            receipt.items.map(::itemReceiptBundle).toTypedArray(),
        )
        putBoolean(KEY_BATCH_CANCELLED, receipt.cancelled)
    }

    fun batchReceipt(reply: Bundle?): SettingsBatchReceipt? {
        if (reply == null) return null
        val raw = reply.getParcelableArray(KEY_SETTINGS_RECEIPTS) ?: return null
        if (raw.size > SettingsKeyPolicy.MAX_BATCH_CHANGES) return null
        val items = ArrayList<SettingItemReceipt>(raw.size)
        for (entry in raw) {
            val bundle = entry as? Bundle ?: return null
            val namespace = bundle.getString(KEY_NAMESPACE) ?: return null
            val key = bundle.getString(KEY_SETTING_KEY) ?: return null
            val action = when (bundle.getString(KEY_SETTING_ACTION)) {
                ACTION_PUT -> SettingsChangeAction.PUT
                ACTION_DELETE -> SettingsChangeAction.DELETE
                else -> return null
            }
            val oldPresent = bundle.getBoolean(KEY_OLD_PRESENT, false)
            val oldValue = bundle.getString(KEY_OLD_VALUE)?.take(64)
            val requested = bundle.getString(KEY_SETTING_VALUE)?.take(64)
            val effectivePresent = bundle.getBoolean(KEY_EFFECTIVE_PRESENT, false)
            val effective = bundle.getString(KEY_EFFECTIVE_VALUE)?.take(64)
            val detail = bundle.getString(KEY_SETTING_DETAIL)?.take(48) ?: return null
            items.add(
                SettingItemReceipt(
                    namespace = namespace,
                    key = key,
                    action = action,
                    oldValue = if (oldPresent) oldValue else null,
                    requestedValue = requested,
                    effectiveValue = if (effectivePresent) effective else null,
                    userId = bundle.getInt(KEY_SETTING_USER, 0),
                    deviceWide = bundle.getBoolean(KEY_SETTING_DEVICE_WIDE, false),
                    succeeded = bundle.getBoolean(KEY_SETTING_SUCCEEDED, false),
                    detailCode = detail,
                    failureDetail = bundle.getString(BinderProtocol.KEY_FAILURE_DETAIL)?.take(96),
                ),
            )
        }
        val cancelled = reply.getBoolean(KEY_BATCH_CANCELLED, false)
        val requested = reply.getInt(KEY_BATCH_REQUESTED, items.size)
        if (requested < items.size) return null
        val ok = items.count { it.succeeded }
        val failed = items.size - ok
        return SettingsBatchReceipt(
            requested = requested,
            ok = ok,
            failed = failed,
            skipped = requested - items.size,
            cancelled = cancelled,
            items = items,
        )
    }
}
