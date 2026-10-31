// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure policy regression for the changed file-ceiling paths:
 *  - an unselected root is never callable;
 *  - other-app data is routed only while Root is the live system owner, so an
 *    ADB shell service cannot inherit it by selection;
 *  - platform system roots are always read-only, even with write ceiling on;
 *  - an empty selection keeps a deterministic read-only diagnostic base;
 *  - file mutations still need the separate global write ceiling.
 */
class FileScopePolicyTest {

    private val downloads = FileRootCatalog.Root(
        id = "downloads",
        labelRes = 0,
        label = "",
        path = "/storage/emulated/0/Download",
        kind = FileRootCatalog.Kind.SHARED,
        writable = true,
    )
    private val system = FileRootCatalog.systemRoots().first()
    private val appData = FileRootCatalog.Root(
        id = "appdata:0123456789abcdef",
        labelRes = 0,
        label = "/data/user/0/com.example.app",
        path = "/data/user/0/com.example.app",
        kind = FileRootCatalog.Kind.APP_DATA,
        writable = true,
    )
    private val roots = listOf(downloads, system, appData)

    private fun ok(
        selected: Set<String>,
        requested: String?,
        write: Boolean = false,
        appDataUsable: Boolean = true,
        globalWrites: Boolean = true,
        fileOperation: Boolean = true,
    ): FileScopePolicy.Routing {
        val decision = FileScopePolicy.decide(
            roots = roots,
            selectedIds = selected,
            requestedId = requested,
            fileOperation = fileOperation,
            writeOperation = write,
            appDataUsable = appDataUsable,
            globalWrites = globalWrites,
        )
        assertTrue("expected Ok, was $decision", decision is FileScopePolicy.Decision.Ok)
        return (decision as FileScopePolicy.Decision.Ok).routing
    }

    private fun denied(
        selected: Set<String>,
        requested: String?,
        write: Boolean = false,
        appDataUsable: Boolean = true,
        globalWrites: Boolean = true,
        fileOperation: Boolean = true,
    ): String {
        val decision = FileScopePolicy.decide(
            roots = roots,
            selectedIds = selected,
            requestedId = requested,
            fileOperation = fileOperation,
            writeOperation = write,
            appDataUsable = appDataUsable,
            globalWrites = globalWrites,
        )
        assertTrue("expected Denied, was $decision", decision is FileScopePolicy.Decision.Denied)
        return (decision as FileScopePolicy.Decision.Denied).code
    }

    @Test
    fun adbShellNeverCountsAsRootForAppData() {
        assertTrue(FileScopePolicy.appDataUsable(rootEnabled = true, adbServiceAlive = false))
        assertFalse(FileScopePolicy.appDataUsable(rootEnabled = true, adbServiceAlive = true))
        assertFalse(FileScopePolicy.appDataUsable(rootEnabled = false, adbServiceAlive = false))
        assertFalse(FileScopePolicy.appDataUsable(rootEnabled = false, adbServiceAlive = true))
    }

    @Test
    fun effectiveSelectionDropsInactiveAppDataOnly() {
        val selected = setOf("downloads", "system", appData.id)
        assertEquals(
            listOf(downloads, system, appData),
            FileScopePolicy.effectiveSelected(roots, selected, appDataUsable = true),
        )
        assertEquals(
            listOf(downloads, system),
            FileScopePolicy.effectiveSelected(roots, selected, appDataUsable = false),
        )
        assertTrue(FileScopePolicy.hasWritableSelection(
            roots, setOf("downloads"), appDataUsable = false))
        assertFalse("a system-only selection is not writable", FileScopePolicy.hasWritableSelection(
            roots, setOf("system"), appDataUsable = true))
        assertFalse("inactive app data is not writable", FileScopePolicy.hasWritableSelection(
            roots, setOf(appData.id), appDataUsable = false))
    }

    @Test
    fun fileOperationsRequireAnExplicitSelectedRoot() {
        assertEquals(
            FileScopePolicy.CODE_FILE_SCOPE_REQUIRED,
            denied(emptySet(), "downloads"),
        )
        assertEquals(
            FileScopePolicy.CODE_SCOPE_REQUIRED,
            denied(setOf("downloads"), null),
        )
        assertEquals(
            FileScopePolicy.CODE_SCOPE_UNKNOWN,
            denied(emptySet(), "not_a_root"),
        )
        assertEquals(
            FileScopePolicy.CODE_SCOPE_UNKNOWN,
            denied(setOf("system"), "downloads"),
        )
        val routing = ok(setOf("downloads"), "downloads")
        assertSame(downloads, routing.root)
        assertFalse("a read grant is not writable", routing.writable)
    }

    @Test
    fun appDataIsRefusedUnlessRootIsTheLiveBackend() {
        assertEquals(
            FileScopePolicy.CODE_SCOPE_REQUIRES_ROOT,
            denied(setOf(appData.id), appData.id, appDataUsable = false),
        )
        assertEquals(
            FileScopePolicy.CODE_FILE_SCOPE_REQUIRED,
            denied(setOf(appData.id), "downloads", appDataUsable = false),
        )
        val routing = ok(setOf(appData.id), appData.id, write = true)
        assertSame(appData, routing.root)
        assertTrue(routing.writable)
    }

    @Test
    fun systemRootsAreReadOnlyEvenWithGlobalWrites() {
        val read = ok(setOf("system"), "system")
        assertSame(system, read.root)
        assertFalse(read.writable)
        assertEquals(
            FileScopePolicy.CODE_SCOPE_READ_ONLY,
            denied(setOf("system"), "system", write = true, globalWrites = true),
        )
    }

    @Test
    fun sharedWritesStillNeedTheGlobalWriteCeiling() {
        assertEquals(
            FileScopePolicy.CODE_WRITE_DISABLED,
            denied(setOf("downloads"), "downloads", write = true, globalWrites = false),
        )
        val write = ok(setOf("downloads"), "downloads", write = true, globalWrites = true)
        assertTrue(write.writable)
        // Read-only operations never carry a writable scope.
        assertFalse(ok(setOf("downloads"), "downloads", write = false).writable)
    }

    @Test
    fun diagnosticsAlwaysUseTheReadOnlySystemAnchor() {
        val routing = ok(emptySet(), null, fileOperation = false)
        assertSame(system, routing.root)
        assertFalse(routing.writable)
        // A selected or temporarily missing public folder must not become the
        // anchor for process/package/network diagnostics.
        val selected = ok(setOf("downloads"), null, fileOperation = false)
        assertSame(system, selected.root)
        assertFalse(selected.writable)
        // Even an unselected app-data id cannot pull diagnostics into app data.
        val appSelected = ok(setOf(appData.id), null, fileOperation = false)
        assertSame(system, appSelected.root)
        assertFalse(appSelected.writable)
    }

    @Test
    fun noRootsAtAllFailsClosedInsteadOfInventingAPath() {
        val decision = FileScopePolicy.decide(
            roots = emptyList(),
            selectedIds = emptySet(),
            requestedId = null,
            fileOperation = false,
            writeOperation = false,
            appDataUsable = false,
            globalWrites = false,
        )
        assertEquals(
            FileScopePolicy.Decision.Denied(FileScopePolicy.CODE_SCOPE_POLICY),
            decision,
        )
    }
}
