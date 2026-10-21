// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Canonical policy spec — AUTHORED, NOTRUN (module is staged source-only;
 * Main runs it at registration). Pure JVM: no host, no transport.
 */
class ModelRolePolicyTest {

    private val text = ModelRolePolicy.Cap.TEXT
    private val textVision = ModelRolePolicy.Cap.TEXT or ModelRolePolicy.Cap.VISION
    private val textTools = ModelRolePolicy.Cap.TEXT or ModelRolePolicy.Cap.TOOLS
    private val mediaGen = ModelRolePolicy.Cap.IMAGE_GENERATION
    private val mediaGenEdit = ModelRolePolicy.Cap.IMAGE_GENERATION or
        ModelRolePolicy.Cap.IMAGE_EDITING
    private val approval = ModelRolePolicy.Cap.TEXT or ModelRolePolicy.Cap.APPROVAL
    private val video = ModelRolePolicy.Cap.VIDEO_GENERATION

    @Test
    fun mediaModelNeverLeaksIntoTextSurfaces() {
        for (slot in listOf(
            ModelRolePolicy.RoleSlot.DEFAULT_AGENT,
            ModelRolePolicy.RoleSlot.CANVAS_AGENT,
            ModelRolePolicy.RoleSlot.GENERAL_AUXILIARY_LLM,
            ModelRolePolicy.RoleSlot.VISION,
            ModelRolePolicy.RoleSlot.CANVAS_VISION,
            ModelRolePolicy.RoleSlot.APPROVAL,
            ModelRolePolicy.RoleSlot.PACKAGE_REVIEW,
            ModelRolePolicy.RoleSlot.DEFAULT_VIDEO,
        )) {
            assertFalse(slot.name, ModelRolePolicy.eligibleFor(slot, mediaGen, null))
        }
        assertTrue(
            ModelRolePolicy.eligibleFor(
                ModelRolePolicy.RoleSlot.IMAGE_GENERATION, mediaGen, null),
        )
    }

    @Test
    fun explicitUseSurfacesOverrideDerivedFallback() {
        val noChat = ModelRolePolicy.Surface.AUX_VISION
        assertFalse(
            ModelRolePolicy.eligibleFor(
                ModelRolePolicy.RoleSlot.DEFAULT_AGENT, textVision, noChat),
        )
        assertTrue(
            ModelRolePolicy.eligibleFor(
                ModelRolePolicy.RoleSlot.VISION, textVision, noChat),
        )
    }

    @Test
    fun canvasAgentRequiresTools() {
        assertTrue(
            ModelRolePolicy.eligibleFor(
                ModelRolePolicy.RoleSlot.CANVAS_AGENT, textTools, null),
        )
        assertFalse(
            ModelRolePolicy.eligibleFor(
                ModelRolePolicy.RoleSlot.CANVAS_AGENT, text, null),
        )
    }

    @Test
    fun sharedSeparateTransitionDerivesFromRealCapabilities() {
        val sharedId = "model-shared"
        val caps = { id: String ->
            if (id == sharedId) mediaGenEdit else 0
        }
        val separate = ModelRolePolicy.transitionMediaMode(
            separate = true,
            current = { if (it == ModelRolePolicy.RoleSlot.SHARED_IMAGE) sharedId else null },
            capabilities = caps,
        )
        assertEquals(sharedId, separate[ModelRolePolicy.RoleSlot.IMAGE_GENERATION])
        assertEquals(sharedId, separate[ModelRolePolicy.RoleSlot.IMAGE_EDITING])
        assertNull(separate[ModelRolePolicy.RoleSlot.SHARED_IMAGE])

        val back = ModelRolePolicy.transitionMediaMode(
            separate = false,
            current = {
                when (it) {
                    ModelRolePolicy.RoleSlot.IMAGE_GENERATION -> sharedId
                    ModelRolePolicy.RoleSlot.IMAGE_EDITING -> sharedId
                    else -> null
                }
            },
            capabilities = caps,
        )
        assertEquals(sharedId, back[ModelRolePolicy.RoleSlot.SHARED_IMAGE])
        assertNull(back[ModelRolePolicy.RoleSlot.IMAGE_GENERATION])
        assertNull(back[ModelRolePolicy.RoleSlot.IMAGE_EDITING])
    }

    @Test
    fun transitionClearsCapabilityMissingRoute() {
        val genOnly = "model-gen-only"
        val caps = { id: String ->
            if (id == genOnly) ModelRolePolicy.Cap.IMAGE_GENERATION else 0
        }
        val separate = ModelRolePolicy.transitionMediaMode(
            separate = true,
            current = { if (it == ModelRolePolicy.RoleSlot.SHARED_IMAGE) genOnly else null },
            capabilities = caps,
        )
        assertEquals(genOnly, separate[ModelRolePolicy.RoleSlot.IMAGE_GENERATION])
        // The model cannot edit: the editing route is cleared, never forced.
        assertNull(separate[ModelRolePolicy.RoleSlot.IMAGE_EDITING])
    }

    @Test
    fun videoSurfaceIsolatedFromImageModels() {
        assertTrue(
            ModelRolePolicy.eligibleFor(
                ModelRolePolicy.RoleSlot.DEFAULT_VIDEO, video, null),
        )
        assertFalse(
            ModelRolePolicy.eligibleFor(
                ModelRolePolicy.RoleSlot.DEFAULT_VIDEO, mediaGenEdit, null),
        )
        assertFalse(
            ModelRolePolicy.eligibleFor(
                ModelRolePolicy.RoleSlot.IMAGE_GENERATION, video, null),
        )
    }
}
