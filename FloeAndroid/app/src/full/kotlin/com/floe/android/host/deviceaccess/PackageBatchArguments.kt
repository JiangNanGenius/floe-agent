// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONObject

/**
 * Closed argument parsing for the batch package tools. Install names staged
 * APKs by opaque host-issued id (never a path); uninstall names package ids.
 * Both cap the batch, dedupe preserving order and validate every item so a
 * malformed entry fails the whole call before any device effect.
 */
internal object PackageBatchArguments {

    const val MAX_ITEMS = 8

    sealed interface Request {
        data class Install(val stagedIds: List<String>, val userId: Int) : Request
        data class Uninstall(val packageNames: List<String>, val userId: Int) : Request
        data class SetEnabled(
            val packageNames: List<String>,
            val userId: Int,
            val state: String,
        ) : Request

        data class RemoveForUser(val packageNames: List<String>, val userId: Int) : Request
        data class Restore(val packageNames: List<String>, val userId: Int) : Request
        data class Invalid(val code: String) : Request
    }

    private val PACKAGE_NAME = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")

    private val SET_ENABLED_STATES = setOf("enable", "disable", "disable-user")

    fun install(arguments: JSONObject): Request {
        val ids = stringArray(arguments, "stagedIds") ?: return Request.Invalid("invalid_arguments")
        if (ids.isEmpty() || ids.size > MAX_ITEMS) return Request.Invalid("invalid_arguments")
        val clean = ArrayList<String>(ids.size)
        for (raw in ids) {
            val id = raw.trim()
            if (!ApkStagingManifest.stagedIdValid(id)) return Request.Invalid("invalid_arguments")
            if (id !in clean) clean += id
        }
        if (clean.isEmpty()) return Request.Invalid("invalid_arguments")
        val userId = userId(arguments) ?: return Request.Invalid("invalid_arguments")
        return Request.Install(clean, userId)
    }

    fun uninstall(arguments: JSONObject): Request {
        val names = stringArray(arguments, "packages") ?: return Request.Invalid("invalid_arguments")
        if (names.isEmpty() || names.size > MAX_ITEMS) return Request.Invalid("invalid_arguments")
        val clean = ArrayList<String>(names.size)
        for (raw in names) {
            val name = raw.trim()
            if (!PACKAGE_NAME.matches(name)) return Request.Invalid("invalid_arguments")
            if (name !in clean) clean += name
        }
        if (clean.isEmpty()) return Request.Invalid("invalid_arguments")
        val userId = userId(arguments) ?: return Request.Invalid("invalid_arguments")
        return Request.Uninstall(clean, userId)
    }

    fun setEnabled(arguments: JSONObject): Request {
        val names = stringArray(arguments, "packages") ?: return Request.Invalid("invalid_arguments")
        if (names.isEmpty() || names.size > MAX_ITEMS) return Request.Invalid("invalid_arguments")
        val clean = ArrayList<String>(names.size)
        for (raw in names) {
            val name = raw.trim()
            if (!PACKAGE_NAME.matches(name)) return Request.Invalid("invalid_arguments")
            if (name !in clean) clean += name
        }
        if (clean.isEmpty()) return Request.Invalid("invalid_arguments")
        val state = arguments.optString("state").trim()
        if (state !in SET_ENABLED_STATES) return Request.Invalid("invalid_arguments")
        val userId = userId(arguments) ?: return Request.Invalid("invalid_arguments")
        return Request.SetEnabled(clean, userId, state)
    }

    fun removeForUser(arguments: JSONObject): Request = namedBatch(arguments, Request::RemoveForUser)

    fun restore(arguments: JSONObject): Request = namedBatch(arguments, Request::Restore)

    private fun namedBatch(
        arguments: JSONObject,
        factory: (List<String>, Int) -> Request,
    ): Request {
        val names = stringArray(arguments, "packages") ?: return Request.Invalid("invalid_arguments")
        if (names.isEmpty() || names.size > MAX_ITEMS) return Request.Invalid("invalid_arguments")
        val clean = ArrayList<String>(names.size)
        for (raw in names) {
            val name = raw.trim()
            if (!PACKAGE_NAME.matches(name)) return Request.Invalid("invalid_arguments")
            if (name !in clean) clean += name
        }
        if (clean.isEmpty()) return Request.Invalid("invalid_arguments")
        val userId = userId(arguments) ?: return Request.Invalid("invalid_arguments")
        return factory(clean, userId)
    }

    private fun stringArray(arguments: JSONObject, key: String): List<String>? {
        if (!arguments.has(key)) return null
        val array = arguments.optJSONArray(key) ?: return null
        val result = ArrayList<String>(array.length())
        for (index in 0 until array.length()) {
            val value = array.opt(index) as? String ?: return null
            result += value
        }
        return result
    }

    private fun userId(arguments: JSONObject): Int? {
        val raw = if (arguments.has("userId")) {
            arguments.opt("userId")
        } else {
            return 0
        }
        val value = (raw as? Number)?.toInt() ?: return null
        return value.takeIf { it in 0..999 }
    }
}
