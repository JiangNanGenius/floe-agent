// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

/**
 * Pure routing/write decisions for the user-selected file ceilings.
 *
 * The App host, the configured `RootSystemConfig.allowedScopeBases` and the
 * grant scope must agree:
 *  - only an explicitly selected root id may be named by a file tool;
 *  - other-app data roots are usable only while the Root tier is the actual
 *    live owner. An ADB shell service never receives an app-data scope, and
 *    choosing one cannot promote that service to UID 0;
 *  - platform roots are always read-only, even with the global write ceiling
 *    on; and
 *  - diagnostics always use a deterministic read-only platform base,
 *    independent of file selections, so an empty/unmounted public directory
 *    or an unreadable app-data folder never disables process/network
 *    diagnostics, pairing or Root startup.
 *
 * No filesystem access happens here: the backend resolves and re-checks the
 * canonical target for every operation.
 */
internal object FileScopePolicy {

    const val CODE_SCOPE_REQUIRED = "scope_required"
    const val CODE_SCOPE_UNKNOWN = "scope_unknown"
    const val CODE_SCOPE_REQUIRES_ROOT = "scope_requires_root"
    const val CODE_FILE_SCOPE_REQUIRED = "file_scope_required"
    const val CODE_SCOPE_READ_ONLY = "scope_read_only"
    const val CODE_WRITE_DISABLED = "write_scope_disabled"
    const val CODE_SCOPE_POLICY = "scope_policy"

    data class Routing(
        val root: FileRootCatalog.Root,
        val writable: Boolean,
    )

    sealed interface Decision {
        data class Ok(val routing: Routing) : Decision
        data class Denied(val code: String) : Decision
    }

    /**
     * True only when the live system binder is the Root service. ADB shell
     * being alive means the controller's one binder is the ADB service even if
     * a stale RootStatus still says Enabled, so app-data must stay unusable.
     */
    fun appDataUsable(rootEnabled: Boolean, adbServiceAlive: Boolean): Boolean =
        rootEnabled && !adbServiceAlive

    fun effectiveSelected(
        roots: List<FileRootCatalog.Root>,
        selectedIds: Set<String>,
        appDataUsable: Boolean,
    ): List<FileRootCatalog.Root> = roots.filter { root ->
        root.id in selectedIds &&
            (root.kind != FileRootCatalog.Kind.APP_DATA || appDataUsable)
    }

    fun hasWritableSelection(
        roots: List<FileRootCatalog.Root>,
        selectedIds: Set<String>,
        appDataUsable: Boolean,
    ): Boolean = effectiveSelected(roots, selectedIds, appDataUsable).any { it.writable }

    /**
     * Chooses the exact root and whether the grant scope may be writable.
     * File operations always require an explicit selected id; read-only and
     * diagnostic operations never carry a writable scope.
     */
    fun decide(
        roots: List<FileRootCatalog.Root>,
        selectedIds: Set<String>,
        requestedId: String?,
        fileOperation: Boolean,
        writeOperation: Boolean,
        appDataUsable: Boolean,
        globalWrites: Boolean,
    ): Decision {
        val selected = effectiveSelected(roots, selectedIds, appDataUsable)
        if (fileOperation) {
            if (requestedId == null) return Decision.Denied(CODE_SCOPE_REQUIRED)
            val requested = roots.firstOrNull { it.id == requestedId }
                ?: return Decision.Denied(CODE_SCOPE_UNKNOWN)
            if (requested.kind == FileRootCatalog.Kind.APP_DATA && !appDataUsable) {
                return Decision.Denied(CODE_SCOPE_REQUIRES_ROOT)
            }
            val chosen = selected.firstOrNull { it.id == requestedId }
                ?: return if (selected.isEmpty()) {
                    Decision.Denied(CODE_FILE_SCOPE_REQUIRED)
                } else {
                    Decision.Denied(CODE_SCOPE_UNKNOWN)
                }
            if (writeOperation) {
                if (chosen.kind == FileRootCatalog.Kind.SYSTEM || !chosen.writable) {
                    return Decision.Denied(CODE_SCOPE_READ_ONLY)
                }
                if (!globalWrites) return Decision.Denied(CODE_WRITE_DISABLED)
            }
            return Decision.Ok(Routing(chosen, writable = writeOperation))
        }
        // Diagnostics and package/process/network queries never depend on a
        // user file folder. Use the deterministic read-only platform anchor,
        // so an unmounted public folder or an unreadable app-data folder can
        // never disable them.
        val root = roots.firstOrNull {
            it.id == FileRootCatalog.DIAGNOSTICS_ID &&
                it.kind == FileRootCatalog.Kind.SYSTEM
        } ?: roots.firstOrNull { it.kind == FileRootCatalog.Kind.SYSTEM }
            ?: selected.firstOrNull()
            ?: roots.firstOrNull { it.kind != FileRootCatalog.Kind.APP_DATA }
            ?: return Decision.Denied(CODE_SCOPE_POLICY)
        return Decision.Ok(Routing(root, writable = false))
    }
}
