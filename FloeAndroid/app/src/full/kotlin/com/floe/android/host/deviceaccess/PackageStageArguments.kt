// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONObject

/**
 * Closed argument parsing for `system.packages.stage`. Every source names an
 * ORIGIN the host itself can verify — the current task's resolved Linux
 * workspace, or a user-granted file root — never a model-supplied host path
 * or content URI. A malformed source fails the whole call before any effect;
 * duplicates (same origin + normalized path) are dropped preserving order.
 */
internal object PackageStageArguments {

    const val MAX_ITEMS = 8
    const val MAX_PATH = 512
    const val MAX_ROOT_ID = 64

    sealed interface Source {
        /** Relative path inside the current task's resolved Linux workspace. */
        data class Workspace(val relativePath: String) : Source

        /** Relative path inside one user-granted shared file root. */
        data class FileRoot(val rootId: String, val relativePath: String) : Source
    }

    sealed interface Request {
        data class Stage(val sources: List<Source>) : Request
        data class Invalid(val code: String) : Request
    }

    fun parse(arguments: JSONObject): Request {
        val array = arguments.optJSONArray("sources") ?: return Request.Invalid("invalid_arguments")
        if (array.length() == 0 || array.length() > MAX_ITEMS) {
            return Request.Invalid("invalid_arguments")
        }
        val sources = ArrayList<Source>(array.length())
        val seen = HashSet<String>()
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: return Request.Invalid("invalid_arguments")
            val origin = item.optString("origin")
            val rawPath = item.optString("path")
            val path = normalizeWorkspaceRelative(rawPath) ?: return Request.Invalid("invalid_arguments")
            when (origin) {
                "workspace" -> {
                    val key = "w:$path"
                    if (seen.add(key)) sources += Source.Workspace(path)
                }
                "fileRoot" -> {
                    val rootId = item.optString("root").trim()
                    if (rootId.isEmpty() || rootId.length > MAX_ROOT_ID ||
                        rootId.any { it.isISOControl() }
                    ) {
                        return Request.Invalid("invalid_arguments")
                    }
                    val key = "r:$rootId:$path"
                    if (seen.add(key)) sources += Source.FileRoot(rootId, path)
                }
                else -> return Request.Invalid("invalid_arguments")
            }
        }
        if (sources.isEmpty()) return Request.Invalid("invalid_arguments")
        return Request.Stage(sources)
    }

    /**
     * Normalize one model-supplied relative path WITHOUT granting anything:
     * absolute paths, `..`/`.` segments, empty segments, control characters
     * and backslashes are refused, the result must end in `.apk`, and no
     * segment may exceed the platform bound. The origin-side resolver
     * (Swift workspace guard / file-root canonicalization) re-checks
     * containment against the real root before any byte moves.
     */
    private fun normalizeWorkspaceRelative(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty() || trimmed.length > MAX_PATH) return null
        if (trimmed.startsWith("/") || trimmed.any { it == '\u0000' || it.isISOControl() || it == '\\' }) {
            return null
        }
        val segments = trimmed.split('/')
        if (segments.isEmpty() || segments.size > 32) return null
        if (segments.any { it.isEmpty() || it == "." || it == ".." || it.length > 255 }) return null
        if (!segments.last().endsWith(".apk", ignoreCase = true)) return null
        return segments.joinToString("/")
    }
}
