// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.rootsystem.SettingsChange
import com.floe.android.rootsystem.SettingsChangeAction
import com.floe.android.rootsystem.policy.SettingsKeyPolicy
import org.json.JSONObject

/**
 * Strict argument parser for system.settings.read / system.settings.write.
 * The schema the Swift mailbox enforces is only the transport shape; every
 * namespace/key/value is re-validated HERE against the closed
 * [SettingsKeyPolicy] table before any grant or dispatch, so model text can
 * never widen the settings surface. Values are normalized by the policy so
 * the wire and the OS receive exactly the canonical decimal form.
 */
internal object SettingsToolArguments {

    sealed interface Request {
        data class Read(val namespace: String, val key: String) : Request
        data class Write(val changes: List<SettingsChange>) : Request
        data class Invalid(val code: String) : Request
    }

    fun read(arguments: JSONObject): Request {
        val namespace = arguments.optString("namespace")
        if (namespace !in SettingsKeyPolicy.SUPPORTED_NAMESPACES) {
            return Request.Invalid("setting_namespace")
        }
        val key = arguments.optString("key")
        if (key.isEmpty() || key.length > 64) return Request.Invalid("setting_key")
        if (SettingsKeyPolicy.specFor(namespace, key) == null) {
            return Request.Invalid("setting_key")
        }
        return Request.Read(namespace, key)
    }

    fun write(arguments: JSONObject): Request {
        val raw = arguments.optJSONArray("changes") ?: return Request.Invalid("changes")
        if (raw.length() == 0) return Request.Invalid("changes_empty")
        if (raw.length() > SettingsKeyPolicy.MAX_BATCH_CHANGES) {
            return Request.Invalid("changes_too_many")
        }
        val seen = HashSet<Pair<String, String>>(raw.length())
        val out = ArrayList<SettingsChange>(raw.length())
        for (index in 0 until raw.length()) {
            val item = raw.optJSONObject(index) ?: return Request.Invalid("changes")
            val namespace = item.optString("namespace")
            if (namespace !in SettingsKeyPolicy.SUPPORTED_NAMESPACES) {
                return Request.Invalid("setting_namespace")
            }
            val key = item.optString("key")
            if (key.isEmpty() || key.length > 64) return Request.Invalid("setting_key")
            if (!seen.add(namespace to key)) return Request.Invalid("changes_duplicate")
            val spec = SettingsKeyPolicy.specFor(namespace, key)
                ?: return Request.Invalid("setting_key")
            val actionRaw = item.optString("action")
            when (actionRaw) {
                "put" -> {
                    val value = item.optString("value")
                    val checked = SettingsKeyPolicy.checkValue(spec, value)
                    when (checked) {
                        is SettingsKeyPolicy.ValueCheck.Ok ->
                            out.add(SettingsChange(namespace, key, SettingsChangeAction.PUT, checked.normalized))
                        is SettingsKeyPolicy.ValueCheck.Rejected ->
                            return Request.Invalid(checked.code)
                    }
                }
                "delete" -> {
                    if (item.has("value")) return Request.Invalid("changes")
                    out.add(SettingsChange(namespace, key, SettingsChangeAction.DELETE, null))
                }
                else -> return Request.Invalid("setting_action")
            }
        }
        return Request.Write(out)
    }
}
