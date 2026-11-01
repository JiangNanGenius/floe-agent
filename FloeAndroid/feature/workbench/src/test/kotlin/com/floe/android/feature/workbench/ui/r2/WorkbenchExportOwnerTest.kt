// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CreativeProjectContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkbenchExportOwnerTest {
    @Test
    fun reauthorizedSessionMatchesTheSameOwner() {
        val owner = WorkbenchExportOwner.from(
            context(token = "old-token", storage = CreativeStorageLayer.AppOwned),
        )
        assertTrue(owner.matches(context(token = "new-token")))
        assertFalse(owner.matches(context(token = "new-token", projectID = "other")))
    }

    @Test
    fun nullAndStandaloneOriginAreTheSameOwner() {
        val nullOrigin = WorkbenchExportOwner.from(
            CreativeProjectContext(
                projectID = "project",
                sessionToken = "token",
                storage = CreativeStorageLayer.AppOwned,
                origin = null,
            ),
        )
        val standalone = WorkbenchExportOwner.from(
            context(
                origin = CreativeOriginContext.standalone(),
            ),
        )
        assertEquals(nullOrigin.key, standalone.key)
        assertTrue(nullOrigin.matches(context(origin = CreativeOriginContext.standalone())))
    }

    @Test
    fun storageAndOriginOwnersNeverCollide() {
        val owner = WorkbenchExportOwner.from(context())
        assertFalse(
            owner.matches(
                context(storage = CreativeStorageLayer.Workspace("workspace-a")),
            ),
        )
        assertFalse(
            owner.matches(
                context(
                    origin = CreativeOriginContext(
                        kind = CreativeOriginContext.CHAT,
                        ownerID = "11111111-1111-1111-1111-111111111111",
                    ),
                ),
            ),
        )
        assertFalse(
            owner.matches(
                context(
                    storage = CreativeStorageLayer.Workspace("workspace-b"),
                ),
            ),
        )
    }

    private fun context(
        token: String = "token",
        projectID: String = "project",
        storage: CreativeStorageLayer = CreativeStorageLayer.AppOwned,
        origin: CreativeOriginContext? = null,
    ) = CreativeProjectContext(
        projectID = projectID,
        sessionToken = token,
        storage = storage,
        origin = origin,
    )
}
