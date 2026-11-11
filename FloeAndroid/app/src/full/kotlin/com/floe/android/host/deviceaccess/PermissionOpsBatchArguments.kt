// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.rootsystem.policy.PermissionOpsPolicy
import org.json.JSONObject

/**
 * Closed argument parsing for the four permission/AppOps tools.
 *
 * Queries name one selected package; managers take an ordered batch of at
 * most [MAX_ITEMS] items. Every item is validated (package shape, permission
 * shape, closed action, closed AppOps catalog token, closed mode) so a
 * malformed entry fails the whole call before any device effect. The SDK
 * gate for foreground mode and the catalog availability stay service-side,
 * mirrored at dispatch by the availability ceiling.
 */
internal object PermissionOpsBatchArguments {

    const val MAX_ITEMS = 8

    sealed interface Request {
        data class PermissionsQuery(val packageName: String, val userId: Int) : Request
        data class PermissionItem(
            val packageName: String,
            val permission: String,
            val action: String,
        )

        data class PermissionsManage(val items: List<PermissionItem>, val userId: Int) : Request
        data class AppOpsQuery(val packageName: String, val userId: Int) : Request
        data class AppOpsItem(
            val packageName: String,
            val operation: String,
            val mode: String,
        )

        data class AppOpsManage(val items: List<AppOpsItem>, val userId: Int) : Request
        data class Invalid(val code: String) : Request
    }

    private val PACKAGE_NAME = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")

    fun packageNameValid(raw: String): Boolean = PACKAGE_NAME.matches(raw)

    fun permissionsQuery(arguments: JSONObject): Request {
        val packageName = arguments.optString("packageName").trim()
        if (!PACKAGE_NAME.matches(packageName)) return Request.Invalid("invalid_arguments")
        val userId = userId(arguments) ?: return Request.Invalid("invalid_arguments")
        return Request.PermissionsQuery(packageName, userId)
    }

    fun appOpsQuery(arguments: JSONObject): Request {
        val packageName = arguments.optString("packageName").trim()
        if (!PACKAGE_NAME.matches(packageName)) return Request.Invalid("invalid_arguments")
        val userId = userId(arguments) ?: return Request.Invalid("invalid_arguments")
        return Request.AppOpsQuery(packageName, userId)
    }

    fun permissionsManage(arguments: JSONObject): Request {
        val array = arguments.optJSONArray("items") ?: return Request.Invalid("invalid_arguments")
        if (array.length() < 1 || array.length() > MAX_ITEMS) {
            return Request.Invalid("invalid_arguments")
        }
        val items = ArrayList<Request.PermissionItem>(array.length())
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: return Request.Invalid("invalid_arguments")
            val packageName = item.optString("packageName").trim()
            val permission = item.optString("permission").trim()
            val action = item.optString("action").trim()
            if (!PACKAGE_NAME.matches(packageName)) return Request.Invalid("invalid_arguments")
            if (!PermissionOpsPolicy.PERMISSION_NAME.matches(permission)) {
                return Request.Invalid("invalid_arguments")
            }
            if (action !in PermissionOpsPolicy.ACTIONS) return Request.Invalid("invalid_arguments")
            if (items.any { it.packageName == packageName && it.permission == permission }) {
                return Request.Invalid("invalid_arguments")
            }
            items += Request.PermissionItem(packageName, permission, action)
        }
        val userId = userId(arguments) ?: return Request.Invalid("invalid_arguments")
        return Request.PermissionsManage(items, userId)
    }

    fun appOpsManage(arguments: JSONObject): Request {
        val array = arguments.optJSONArray("items") ?: return Request.Invalid("invalid_arguments")
        if (array.length() < 1 || array.length() > MAX_ITEMS) {
            return Request.Invalid("invalid_arguments")
        }
        val items = ArrayList<Request.AppOpsItem>(array.length())
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: return Request.Invalid("invalid_arguments")
            val packageName = item.optString("packageName").trim()
            val operation = item.optString("operation").trim()
            val mode = item.optString("mode").trim()
            if (!PACKAGE_NAME.matches(packageName)) return Request.Invalid("invalid_arguments")
            if (operation !in PermissionOpsPolicy.APP_OP_TOKENS) {
                return Request.Invalid("invalid_arguments")
            }
            if (mode !in PermissionOpsPolicy.MODES) return Request.Invalid("invalid_arguments")
            if (items.any { it.packageName == packageName && it.operation == operation }) {
                return Request.Invalid("invalid_arguments")
            }
            items += Request.AppOpsItem(packageName, operation, mode)
        }
        val userId = userId(arguments) ?: return Request.Invalid("invalid_arguments")
        return Request.AppOpsManage(items, userId)
    }

    private fun userId(arguments: JSONObject): Int? {
        val raw = if (arguments.has("userId")) {
            arguments.optInt("userId", -1)
        } else {
            0
        }
        return if (raw in 0..999) raw else null
    }
}
