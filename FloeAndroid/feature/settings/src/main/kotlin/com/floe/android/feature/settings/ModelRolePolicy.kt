// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.settings

/**
 * Canonical pure policy for the original model-role preferences surface,
 * consumed by the App host and covered by this module's policy fixtures.
 *
 * Everything here is a line-faithful mirror of the frozen iOS original:
 *  * `ModelSelectionPreferences` role slots (FloeCore
 *    ModelSelectionPreferences.swift:11-137);
 *  * `ModelCapabilities` / `ModelUseSurfaces` bit values
 *    (FloeCore ModelProfile.swift:9-45);
 *  * `effectiveUseSurfaces` + the surface predicates
 *    (ModelProfile.swift:170-278);
 *  * the shared↔separate media-mode transition `switchAuxiliaryMode`
 *    (ModelSelectionPreferences.swift:84-116).
 *
 * No Android imports, no I/O: the App host feeds real row capabilities and
 * saved use-surface overrides; this file decides eligibility and the mode
 * transition. Reads never autoassign defaults — null stays null.
 */
object ModelRolePolicy {

    /** One original role slot of the preferences document. */
    enum class RoleSlot(val wireKey: String) {
        DEFAULT_AGENT("defaultAgentModelID"),
        GENERAL_AUXILIARY_LLM("generalAuxiliaryLLMModelID"),
        CANVAS_AGENT("canvasAgentModelID"),
        VISION("visionModelID"),
        CANVAS_VISION("canvasVisionModelID"),
        APPROVAL("approvalModelID"),
        PACKAGE_REVIEW("packageReviewModelID"),
        SHARED_IMAGE("sharedImageModelID"),
        IMAGE_GENERATION("imageGenerationModelID"),
        IMAGE_EDITING("imageEditingModelID"),
        DEFAULT_VIDEO("defaultVideoModelID"),
    }

    // Frozen ModelCapabilities rawValues (bit values are wire-stable).
    object Cap {
        const val TEXT = 1 shl 0
        const val VISION = 1 shl 1
        const val TOOLS = 1 shl 2
        const val IMAGE_GENERATION = 1 shl 3
        const val IMAGE_EDITING = 1 shl 4
        const val APPROVAL = 1 shl 5
        const val VIDEO_GENERATION = 1 shl 6
        const val MEDIA = IMAGE_GENERATION or IMAGE_EDITING or VIDEO_GENERATION
    }

    // Frozen ModelUseSurfaces rawValues.
    object Surface {
        const val CHAT_AGENT = 1 shl 0
        const val AUX_VISION = 1 shl 1
        const val APPROVAL = 1 shl 2
        const val IMAGE_GENERATION = 1 shl 3
        const val VIDEO_GENERATION = 1 shl 4
    }

    const val MODE_SHARED = "shared"
    const val MODE_SEPARATE = "separate"

    private fun Int.has(bit: Int): Boolean = this and bit != 0

    /** The original `effectiveUseSurfaces` (ModelProfile.swift:174-207). */
    fun effectiveSurfaces(capabilities: Int, useSurfaces: Int?): Int {
        var result = useSurfaces ?: 0
        val hasImage = capabilities.has(Cap.IMAGE_GENERATION) ||
            capabilities.has(Cap.IMAGE_EDITING)
        val hasVideo = capabilities.has(Cap.VIDEO_GENERATION)
        val isMedia = hasImage || hasVideo
        if (useSurfaces == null) {
            if (capabilities.has(Cap.TEXT) && !isMedia) result = result or Surface.CHAT_AGENT
            if (capabilities.has(Cap.VISION) && !isMedia) result = result or Surface.AUX_VISION
            if (capabilities.has(Cap.APPROVAL)) result = result or Surface.APPROVAL
            if (hasImage) result = result or Surface.IMAGE_GENERATION
            if (hasVideo) result = result or Surface.VIDEO_GENERATION
        }
        if (capabilities.has(Cap.TEXT) && capabilities.has(Cap.VISION) && !isMedia) {
            result = result or Surface.AUX_VISION
        } else if (!capabilities.has(Cap.VISION)) {
            result = result and Surface.AUX_VISION.inv()
        }
        if (isMedia || result.has(Surface.IMAGE_GENERATION) ||
            result.has(Surface.VIDEO_GENERATION)
        ) {
            result = result and (Surface.CHAT_AGENT or Surface.AUX_VISION or
                Surface.APPROVAL).inv()
        }
        return result
    }

    /** Original slot eligibility (nil useSurfaces derives from capabilities). */
    fun eligibleFor(slot: RoleSlot, capabilities: Int, useSurfaces: Int?): Boolean {
        val surfaces = effectiveSurfaces(capabilities, useSurfaces)
        val noMediaCaps = !capabilities.has(Cap.IMAGE_GENERATION) &&
            !capabilities.has(Cap.IMAGE_EDITING) &&
            !capabilities.has(Cap.VIDEO_GENERATION)
        return when (slot) {
            RoleSlot.DEFAULT_AGENT ->
                surfaces.has(Surface.CHAT_AGENT) && capabilities.has(Cap.TEXT)
            RoleSlot.CANVAS_AGENT ->
                surfaces.has(Surface.CHAT_AGENT) && capabilities.has(Cap.TEXT) &&
                    capabilities.has(Cap.TOOLS)
            RoleSlot.GENERAL_AUXILIARY_LLM ->
                capabilities.has(Cap.TEXT) && noMediaCaps &&
                    !surfaces.has(Surface.IMAGE_GENERATION) &&
                    !surfaces.has(Surface.VIDEO_GENERATION)
            RoleSlot.VISION, RoleSlot.CANVAS_VISION ->
                surfaces.has(Surface.AUX_VISION) &&
                    capabilities.has(Cap.VISION) && noMediaCaps
            RoleSlot.APPROVAL, RoleSlot.PACKAGE_REVIEW ->
                surfaces.has(Surface.APPROVAL) && capabilities.has(Cap.TEXT) &&
                    noMediaCaps
            RoleSlot.IMAGE_GENERATION ->
                surfaces.has(Surface.IMAGE_GENERATION) &&
                    capabilities.has(Cap.IMAGE_GENERATION) &&
                    !capabilities.has(Cap.VIDEO_GENERATION)
            RoleSlot.IMAGE_EDITING ->
                surfaces.has(Surface.IMAGE_GENERATION) &&
                    capabilities.has(Cap.IMAGE_EDITING) &&
                    !capabilities.has(Cap.VIDEO_GENERATION)
            RoleSlot.SHARED_IMAGE ->
                surfaces.has(Surface.IMAGE_GENERATION) &&
                    capabilities.has(Cap.IMAGE_GENERATION) &&
                    capabilities.has(Cap.IMAGE_EDITING) &&
                    !capabilities.has(Cap.VIDEO_GENERATION)
            RoleSlot.DEFAULT_VIDEO ->
                surfaces.has(Surface.VIDEO_GENERATION) &&
                    capabilities.has(Cap.VIDEO_GENERATION) &&
                    !capabilities.has(Cap.IMAGE_GENERATION) &&
                    !capabilities.has(Cap.IMAGE_EDITING)
        }
    }

    /**
     * The original `switchAuxiliaryMode` transition result: which media
     * slots hold which model ids after switching. `current` supplies the
     * effective slot values (draft-over-saved, explicit nulls preserved);
     * `capabilities` resolves a model's real capability bits. A media model
     * lacking the required capability is cleared rather than forced.
     */
    fun transitionMediaMode(
        separate: Boolean,
        current: (RoleSlot) -> String?,
        capabilities: (String) -> Int?,
    ): Map<RoleSlot, String?> {
        return if (separate) {
            val shared = current(RoleSlot.SHARED_IMAGE)
            val sharedCaps = shared?.let(capabilities) ?: 0
            mapOf(
                RoleSlot.IMAGE_GENERATION to
                    if (shared != null && sharedCaps.has(Cap.IMAGE_GENERATION)) shared else null,
                RoleSlot.IMAGE_EDITING to
                    if (shared != null && sharedCaps.has(Cap.IMAGE_EDITING)) shared else null,
                RoleSlot.SHARED_IMAGE to null,
            )
        } else {
            val generation = current(RoleSlot.IMAGE_GENERATION)
            val editing = current(RoleSlot.IMAGE_EDITING)
            val generationCaps = generation?.let(capabilities) ?: 0
            mapOf(
                RoleSlot.SHARED_IMAGE to
                    if (generation != null && generation == editing &&
                        generationCaps.has(Cap.IMAGE_GENERATION) &&
                        generationCaps.has(Cap.IMAGE_EDITING)
                    ) {
                        generation
                    } else {
                        null
                    },
                RoleSlot.IMAGE_GENERATION to null,
                RoleSlot.IMAGE_EDITING to null,
            )
        }
    }
}
