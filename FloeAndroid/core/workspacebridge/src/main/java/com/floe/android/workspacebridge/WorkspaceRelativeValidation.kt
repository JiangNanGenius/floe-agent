// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import java.io.File

/**
 * Pure Kotlin mirror of the Swift `WorkspaceRelativePath` rules (the runtime
 * side must not materialize unsafe entries even when they arrive from a
 * corrupt or compromised CORE snapshot: defense in depth, fail closed).
 * Byte-identical semantics; documented platform delta: the JVM works on
 * `String` + UTF-8 byte counts exactly like Swift's `utf8.count`.
 */
object WorkspaceRelativeValidation {
    const val MAX_TOTAL_BYTES = 2048
    const val MAX_COMPONENT_BYTES = 255
    const val MAX_COMPONENTS = 256

    /** Returns the component list, or null when the raw relative path is
     *  refused (absolute, "~", NUL/control chars, empty/dot/dotdot segments,
     *  overlong components/total, too deep, reserved transfer prefixes). */
    fun validate(raw: String): List<String>? {
        if (raw.isEmpty()) return null
        if (raw.toByteArray(Charsets.UTF_8).size > MAX_TOTAL_BYTES) return null
        if (raw.startsWith("/") || raw.startsWith("~")) return null
        for (element in raw) {
            if (element.code < 0x20 || element.code == 0x7F) return null
        }
        val parts = raw.split("/")
        if (parts.isEmpty() || parts.size > MAX_COMPONENTS) return null
        for (component in parts) {
            if (component.isEmpty() || component == "." || component == "..") return null
            if (component.toByteArray(Charsets.UTF_8).size > MAX_COMPONENT_BYTES) return null
            if (component.startsWith(".floe-commit-") || component.startsWith(".floe-wt-") ||
                component.startsWith(".workspace-bridge")
            ) return null
        }
        return parts
    }

    /**
     * Containment classification for one symlink target relative to the
     * link's own directory (mirrors Swift `classifyLinkTarget`).
     * `relativeContained` = relative and textual `..`-resolution stays at or
     * below the workspace root depth. Anything else is external.
     */
    fun linkTargetContained(target: String, linkComponents: List<String>, maxTargetBytes: Int = MAX_TOTAL_BYTES): Boolean {
        if (target.isEmpty() || target.toByteArray(Charsets.UTF_8).size > maxTargetBytes) return false
        if (target.startsWith("/") || target.startsWith("~")) return false
        for (element in target) {
            if (element.code < 0x20 || element.code == 0x7F) return false
        }
        val parts = target.split("/")
        if (parts.isEmpty()) return false
        var depth = linkComponents.size - 1
        for (component in parts) {
            if (component.isEmpty() || component == ".") continue
            if (component == "..") {
                if (depth <= 0) return false
                depth -= 1
                continue
            }
            if (component.toByteArray(Charsets.UTF_8).size > MAX_COMPONENT_BYTES) return false
            depth += 1
            if (depth > MAX_COMPONENTS) return false
        }
        return depth >= 0
    }

    /** Destination guard: refuse any canonical path escaping `root`. */
    fun containedCanonical(root: File, candidate: File): Boolean {
        val rootPath = root.canonicalPath
        val candidatePath = candidate.canonicalPath
        return candidatePath == rootPath || candidatePath.startsWith(rootPath + File.separator)
    }
}
