// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure regression for the user-facing file ceilings. It does not touch
 * Android APIs: the catalog parser must be deterministic before the backend
 * ever resolves or lists a path.
 *
 * Pinned boundaries:
 *  - only the current user's other-app CE/DE/adopted package folder (and a
 *    subfolder) is accepted; other users, broad parents, system trees and
 *    Floe's own package are refused;
 *  - app-data ids are stable, bounded and never a free-form path to the model;
 *  - platform roots are exposed read-only; shared roots are writable under the
 *    separate write ceiling.
 */
class FileRootCatalogTest {

    private val own = "com.floe.agent.full"

    @Test
    fun currentUserOtherAppFoldersAreAcceptedAndNormalized() {
        assertEquals(
            "/data/user/0/com.example.app",
            FileRootCatalog.normalizeAppDataBase(
                "/data/user/0/com.example.app", own, userId = 0),
        )
        assertEquals(
            "/data/user/0/com.example.app/files/notes",
            FileRootCatalog.normalizeAppDataBase(
                "/data/user/0/com.example.app/files/notes/", own, userId = 0),
        )
        assertEquals(
            "/data/user/0/com.example.app",
            FileRootCatalog.normalizeAppDataBase(
                "/data/user/00/com.example.app", own, userId = 0),
        )
        assertEquals(
            "/data/data/com.example.app",
            FileRootCatalog.normalizeAppDataBase(
                "/data/data/com.example.app", own, userId = 0),
        )
        assertEquals(
            "/data/user_de/0/com.example.app",
            FileRootCatalog.normalizeAppDataBase(
                "/data/user_de/0/com.example.app", own, userId = 0),
        )
        assertEquals(
            "/data/user_de/0/com.example.app/files",
            FileRootCatalog.normalizeAppDataBase(
                "/data/user_de/00/com.example.app/files", own, userId = 0),
        )
        assertEquals(
            "/mnt/expand/1234-ABCD/user/0/com.example.app",
            FileRootCatalog.normalizeAppDataBase(
                "/mnt/expand/1234-ABCD/user/0/com.example.app", own, userId = 0),
        )
        assertEquals(
            "/mnt/expand/1234-ABCD/user_de/0/com.example.app",
            FileRootCatalog.normalizeAppDataBase(
                "/mnt/expand/1234-ABCD/user_de/0/com.example.app", own, userId = 0),
        )
        assertEquals(
            "/mnt/expand/1234-ABCD/app/com.example.app",
            FileRootCatalog.normalizeAppDataBase(
                "/mnt/expand/1234-ABCD/app/com.example.app", own, userId = 0),
        )
    }

    @Test
    fun broadParentsOtherUsersSystemTreesAndFloeAreRefused() {
        val rejected = listOf(
            "",
            "data/user/0/com.example.app",
            "/",
            "/data",
            "/data/data",
            "/data/user",
            "/data/user/0",
            "/data/user/1/com.example.app",
            "/system",
            "/system/app",
            "/data/user/0/$own",
            "/data/user/0/$own.report",
            "/data/user/0/com.floe.agent",
            "/data/user/0/com.floe.agent.runtime.full",
            "/data/user/0/com.floe.agent.runtime.full.dev",
            "/data/user_de/0/$own",
            "/data/user_de/0/com.floe.agent.runtime.full",
            "/data/user_de/0/com.floe.agent.runtime.full.dev",
            "/data/user_de/1/com.example.app",
            "/data/user/0/com.example.app/../other",
            "/data/user/0/com.example.app/\u0000file",
            "/data/user/0/com.example.app\\files",
            "/data/user/0/com..example",
            "/data/user/0/123",
            "/mnt/expand/1234-ABCD/user/1/com.example.app",
        )
        for (path in rejected) {
            assertNull(
                "must be refused: $path",
                FileRootCatalog.normalizeAppDataBase(path, own, userId = 0),
            )
        }
        // The /data/data alias only addresses the device owner's CE data.
        assertNull(FileRootCatalog.normalizeAppDataBase(
            "/data/data/com.example.app", own, userId = 10))
        assertNull(FileRootCatalog.normalizeAppDataBase(
            "/mnt/expand/1234-ABCD/user_de/1/com.example.app", own, userId = 0))
        // Other apps outside the stable Floe family stay usable.
        assertEquals(
            "/data/user/0/com.floe.other",
            FileRootCatalog.normalizeAppDataBase(
                "/data/user/0/com.floe.other", own, userId = 0),
        )
    }

    @Test
    fun appDataRootIdsAreStableBoundedAndOpaque() {
        val first = FileRootCatalog.appDataRoot(
            "/data/user/0/com.example.app/files", own, userId = 0)!!
        val again = FileRootCatalog.appDataRoot(
            "/data/user/00/com.example.app/files", own, userId = 0)!!
        val other = FileRootCatalog.appDataRoot(
            "/data/user/0/com.example.other", own, userId = 0)!!

        assertEquals(first.id, again.id)
        assertNotEquals(first.id, other.id)
        assertTrue(first.id.startsWith("appdata:"))
        assertTrue("ScopeRoot ids are capped at 64 chars", first.id.length <= 64)
        assertTrue(FileRootCatalog.isAppDataId(first.id))
        assertFalse(FileRootCatalog.isAppDataId("downloads"))
        assertEquals("/data/user/0/com.example.app/files", first.label)
        assertEquals(first.label, first.path)
        assertEquals(FileRootCatalog.Kind.APP_DATA, first.kind)
        assertTrue("app data may be writable only through the root tier", first.writable)
        assertFalse(first.readOnly)
    }

    @Test
    fun platformRootsAreDeterministicAndReadOnly() {
        val system = FileRootCatalog.systemRoots()
        assertEquals(
            listOf("/system", "/vendor", "/product", "/system_ext", "/odm", "/apex"),
            system.map { it.path },
        )
        assertTrue(system.all { it.kind == FileRootCatalog.Kind.SYSTEM })
        assertTrue(system.all { it.readOnly && !it.writable })
        assertEquals(FileRootCatalog.DIAGNOSTICS_ID, system.first().id)
        assertEquals(FileRootCatalog.DIAGNOSTICS_BASE, system.first().path)
        assertEquals(system.map { it.id }.toSet().size, system.size)
    }
}
