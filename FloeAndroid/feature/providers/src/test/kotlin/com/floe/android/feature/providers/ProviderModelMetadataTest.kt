// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.providers

import org.junit.Assert.*
import org.junit.Test

class ProviderModelMetadataTest {
    private fun row() = ModelDraftRowUi("m", "m", "remote", "Model",
        capabilities = setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.TOOLS, ModelCapabilityUi.APPROVAL),
        savedMetadata = ModelSavedMetadataUi(
            pricingJSON = "{\"currency\":\"USD\",\"inputPerMillion\":0.1234567890123456789}",
            useSurfacesJSON = "5", explicitCapabilitiesJSON = "2", explicitCapabilitiesRaw = 2,
            capabilitiesRaw = 37))

    @Test fun editableCapabilityDecisionsStayOwnedAfterOffThenOn() {
        val original = row()
        val off = ProviderFormLogic.applyModelEdit(listOf(original),
            original.copy(capabilities = original.capabilities - ModelCapabilityUi.TOOLS), null).first.single()
        // The explicit override is COMPLETE: TEXT/APPROVAL are never dropped,
        // and the user's Tools OFF stays OFF (1 + 32 = 33).
        assertEquals(33, off.savedMetadata!!.explicitCapabilitiesRaw)
        assertEquals("33", off.savedMetadata!!.explicitCapabilitiesJSON)
        assertEquals(original.savedMetadata!!.pricingJSON, off.savedMetadata!!.pricingJSON)
        assertEquals(original.savedMetadata!!.useSurfacesJSON, off.savedMetadata!!.useSurfacesJSON)

        val on = ProviderFormLogic.applyModelEdit(listOf(off),
            off.copy(capabilities = original.capabilities), null).first.single()
        assertEquals(37, on.savedMetadata!!.explicitCapabilitiesRaw)
        assertEquals("37", on.savedMetadata!!.explicitCapabilitiesJSON)
        assertEquals(original.savedMetadata!!.pricingJSON, on.savedMetadata!!.pricingJSON)
        assertEquals(original.savedMetadata!!.useSurfacesJSON, on.savedMetadata!!.useSurfacesJSON)
    }

    @Test fun reconstructedEditorResultCannotDiscardOriginalMetadataOrOwnForcedBits() {
        val original = row()
        val edited = original.copy(displayName = "Renamed", savedMetadata = null,
            capabilities = setOf(ModelCapabilityUi.TOOLS))
        val result = ProviderFormLogic.applyModelEdit(listOf(original), edited, null).first.single()
        assertEquals("Renamed", result.displayName)
        assertEquals(original.savedMetadata!!.pricingJSON, result.savedMetadata!!.pricingJSON)
        // No editable decision in this Save. The persisted mask is the proven
        // legacy ownership delta 2, so it heals from the COMPLETE base row and
        // keeps the role-forced TEXT/APPROVAL bits (37), never the delta.
        assertEquals(37, result.savedMetadata!!.explicitCapabilitiesRaw)
        assertEquals("37", result.savedMetadata!!.explicitCapabilitiesJSON)
    }

    @Test fun explicitNewEmptyCapabilitiesCarryReviewInsteadOfNewRowDefaults() {
        val original = row().copy(savedModelId = null, source = ModelSourceUi.MANUAL, savedMetadata = null)
        val edited = original.copy(capabilities = emptySet())
        val result = ProviderFormLogic.applyModelEdit(listOf(original), edited, null).first.single()
        assertTrue(result.capabilities.isEmpty())
        // Deliberately reviewed empty: the complete row and its complete
        // explicit are 0. Nothing is forced back from the staging default or
        // the old row's TEXT role bit (the old delta 4 was the ownership bug).
        assertEquals(0, result.savedMetadata!!.capabilitiesRaw)
        assertEquals(0, result.savedMetadata!!.explicitCapabilitiesRaw)
        assertEquals("0", result.savedMetadata!!.explicitCapabilitiesJSON)
    }

    @Test fun noOpEditOnLegacyProvenanceRowDoesNotCreateAnOverride() {
        val original = row().copy(savedMetadata = ModelSavedMetadataUi(capabilitiesRaw = 37))
        val result = ProviderFormLogic.applyModelEdit(listOf(original),
            original.copy(displayName = "Renamed"), null).first.single()
        assertNull(result.savedMetadata!!.explicitCapabilitiesRaw)
        assertNull(result.savedMetadata!!.explicitCapabilitiesJSON)
        assertEquals(37, result.savedMetadata!!.capabilitiesRaw)
    }

    @Test fun manualConversationVisionAndToolsProduceCompleteAuthoritativeMask() {
        val manual = ModelDraftRowUi(
            draftModelId = "manual-1", savedModelId = null, remoteModelID = "gpt-5",
            displayName = "GPT-5", source = ModelSourceUi.MANUAL, selectedForSave = true,
            capabilities = setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.TOOLS,
                ModelCapabilityUi.APPROVAL),
        )
        val withVision = ProviderFormLogic.applyModelEdit(listOf(manual),
            manual.copy(capabilities = manual.capabilities + ModelCapabilityUi.VISION), null)
            .first.single()
        // TEXT(1) | VISION(2) | TOOLS(4) | APPROVAL(32) = 39.
        assertEquals(39, withVision.savedMetadata!!.explicitCapabilitiesRaw)
        assertEquals(39, withVision.savedMetadata!!.capabilitiesRaw)

        val visionOnly = ProviderFormLogic.applyModelEdit(listOf(withVision),
            withVision.copy(capabilities = withVision.capabilities - ModelCapabilityUi.TOOLS), null)
            .first.single()
        // Tools OFF is explicit; the draft still carries TEXT/APPROVAL
        // naturally (1 + 2 + 32 = 35), so no stale role injection is needed.
        assertEquals(35, visionOnly.savedMetadata!!.explicitCapabilitiesRaw)
        assertEquals(35, visionOnly.savedMetadata!!.capabilitiesRaw)
    }

    @Test fun explicitToolsOffStaysOffAndCanBeTurnedBackOnDeliberately() {
        val persisted = ModelDraftRowUi(
            draftModelId = "m", savedModelId = "m", remoteModelID = "remote", displayName = "Model",
            source = ModelSourceUi.SAVED, selectedForSave = true,
            capabilities = setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.VISION,
                ModelCapabilityUi.APPROVAL),
            savedMetadata = ModelSavedMetadataUi(
                explicitCapabilitiesJSON = "35", explicitCapabilitiesRaw = 35,
                capabilitiesRaw = 39),
        )
        // A rename/edit that does not touch capabilities must not re-enable
        // the explicitly disabled Tools bit.
        val renamed = ProviderFormLogic.applyModelEdit(listOf(persisted),
            persisted.copy(displayName = "Renamed"), null).first.single()
        assertEquals("Renamed", renamed.displayName)
        assertEquals(35, renamed.savedMetadata!!.explicitCapabilitiesRaw)
        assertEquals(39, renamed.savedMetadata!!.capabilitiesRaw)

        val toolsOn = ProviderFormLogic.applyModelEdit(listOf(renamed),
            renamed.copy(capabilities = renamed.capabilities + ModelCapabilityUi.TOOLS), null)
            .first.single()
        assertEquals(39, toolsOn.savedMetadata!!.explicitCapabilitiesRaw)
    }

    @Test fun explicitReviewedZeroStaysZeroOnRenameAndReload() {
        // Reviewed all off is a complete authoritative override, not the old
        // ownership delta: it must never be promoted from the base row.
        val persisted = row().copy(savedMetadata = ModelSavedMetadataUi(
            pricingJSON = "{\"currency\":\"USD\"}", explicitCapabilitiesJSON = "0",
            explicitCapabilitiesRaw = 0, capabilitiesRaw = 37),
            capabilities = emptySet())
        val renamed = ProviderFormLogic.applyModelEdit(listOf(persisted),
            persisted.copy(displayName = "Renamed"), null).first.single()
        assertEquals(0, renamed.savedMetadata!!.explicitCapabilitiesRaw)
        assertEquals("0", renamed.savedMetadata!!.explicitCapabilitiesJSON)
        assertEquals(37, renamed.savedMetadata!!.capabilitiesRaw)
        // The editor seed for that row is the reviewed value, not the base.
        assertEquals(0, ProviderFormLogic.effectiveSelectedCapabilities(37, 0))
    }

    @Test fun explicitApprovalOnlyStaysAuthoritativeOnRename() {
        // 32 = approval only, no text role: a deliberate complete decision
        // (e.g. approval-routing model), never the legacy ownership shape.
        val persisted = row().copy(
            capabilities = setOf(ModelCapabilityUi.APPROVAL),
            savedMetadata = ModelSavedMetadataUi(explicitCapabilitiesJSON = "32",
                explicitCapabilitiesRaw = 32, capabilitiesRaw = 37))
        val renamed = ProviderFormLogic.applyModelEdit(listOf(persisted),
            persisted.copy(displayName = "Renamed"), null).first.single()
        assertEquals(32, renamed.savedMetadata!!.explicitCapabilitiesRaw)
        assertEquals("32", renamed.savedMetadata!!.explicitCapabilitiesJSON)
        assertEquals(37, renamed.savedMetadata!!.capabilitiesRaw)
    }

    @Test fun mediaOverrideKeepsImageEditingOff() {
        val media = ModelDraftRowUi(
            draftModelId = "img", savedModelId = "img", remoteModelID = "image-1",
            displayName = "Image", source = ModelSourceUi.SAVED, selectedForSave = true,
            capabilities = setOf(ModelCapabilityUi.IMAGE_GENERATION),
            savedMetadata = ModelSavedMetadataUi(explicitCapabilitiesJSON = "8",
                explicitCapabilitiesRaw = 8, capabilitiesRaw = 24),
        )
        // Base 24 (generation + editing) with explicit 8 is a valid complete
        // media override: editing OFF stays OFF. It is editable-only but NOT
        // the conversation legacy shape.
        assertEquals(8, ProviderFormLogic.effectiveSelectedCapabilities(24, 8))
        assertNull(ProviderFormLogic.repairedLegacyExplicitCapabilities(24, 8))
        val renamed = ProviderFormLogic.applyModelEdit(listOf(media),
            media.copy(displayName = "Renamed"), null).first.single()
        assertEquals(8, renamed.savedMetadata!!.explicitCapabilitiesRaw)
        assertEquals(24, renamed.savedMetadata!!.capabilitiesRaw)

        // Turning image editing off from the full media row writes 8, never
        // the old generation|editing base back on.
        val full = media.copy(capabilities = setOf(ModelCapabilityUi.IMAGE_GENERATION,
            ModelCapabilityUi.IMAGE_EDITING), savedMetadata = ModelSavedMetadataUi(capabilitiesRaw = 24))
        val editingOff = ProviderFormLogic.applyModelEdit(listOf(full),
            full.copy(capabilities = setOf(ModelCapabilityUi.IMAGE_GENERATION)), null).first.single()
        assertEquals(8, editingOff.savedMetadata!!.explicitCapabilitiesRaw)
        assertEquals(0, editingOff.savedMetadata!!.explicitCapabilitiesRaw!! and
            ModelCapabilityUi.IMAGE_EDITING.swiftBit)
    }

    @Test fun nonConversationRoleNeverInjectsTextOrApproval() {
        val image = ModelDraftRowUi(
            draftModelId = "img", savedModelId = null, remoteModelID = "image-1",
            displayName = "Image", source = ModelSourceUi.MANUAL, selectedForSave = true,
            capabilities = setOf(ModelCapabilityUi.IMAGE_GENERATION,
                ModelCapabilityUi.IMAGE_EDITING),
        )
        val result = ProviderFormLogic.applyModelEdit(listOf(image),
            image.copy(capabilities = setOf(ModelCapabilityUi.IMAGE_GENERATION)), null)
            .first.single()
        assertEquals(ModelCapabilityUi.IMAGE_GENERATION.swiftBit,
            result.savedMetadata!!.explicitCapabilitiesRaw)
        assertEquals(0, result.savedMetadata!!.explicitCapabilitiesRaw!! and
            ProviderFormLogic.TEXT_CAPABILITY_BIT)
        assertEquals(0, result.savedMetadata!!.explicitCapabilitiesRaw!! and
            ProviderFormLogic.APPROVAL_CAPABILITY_BIT)
    }

    @Test fun unknownFutureAndExtensionMetadataSurviveCompleteMaskEncoding() {
        val futureBit = 1 shl 25
        val original = row().copy(
            savedMetadata = ModelSavedMetadataUi(
                pricingJSON = "{\"currency\":\"USD\",\"inputPerMillion\":0.1234567890123456789}",
                useSurfacesJSON = "5", explicitCapabilitiesJSON = "2",
                explicitCapabilitiesRaw = 2,
                capabilitiesRaw = 39 or futureBit,
            ),
            capabilities = setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.VISION,
                ModelCapabilityUi.TOOLS, ModelCapabilityUi.APPROVAL),
        )
        val result = ProviderFormLogic.applyModelEdit(listOf(original),
            original.copy(displayName = "Renamed"), null).first.single()
        val explicit = result.savedMetadata!!.explicitCapabilitiesRaw!!
        assertEquals(39 or futureBit, explicit)
        // Unknown bits stay in the base mask too.
        assertEquals(39 or futureBit, result.savedMetadata!!.capabilitiesRaw)
        assertEquals(original.savedMetadata!!.pricingJSON, result.savedMetadata!!.pricingJSON)
        assertEquals(original.savedMetadata!!.useSurfacesJSON, result.savedMetadata!!.useSurfacesJSON)
    }

    @Test fun legacyOwnershipRowsHealFromTheCompleteBaseOnRename() {
        fun healed(base: Int, owned: Int, capabilities: Set<ModelCapabilityUi>): Int? {
            val persisted = row().copy(capabilities = capabilities,
                savedMetadata = ModelSavedMetadataUi(capabilitiesRaw = base,
                    explicitCapabilitiesJSON = owned.toString(),
                    explicitCapabilitiesRaw = owned))
            return ProviderFormLogic.applyModelEdit(listOf(persisted),
                persisted.copy(displayName = "Renamed"), null)
                .first.single().savedMetadata!!.explicitCapabilitiesRaw
        }

        val textToolsApproval = setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.TOOLS,
            ModelCapabilityUi.APPROVAL)
        val textVisionToolsApproval = textToolsApproval + ModelCapabilityUi.VISION
        val textVisionApproval = setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.VISION,
            ModelCapabilityUi.APPROVAL)
        val textApproval = setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.APPROVAL)

        assertEquals(37, healed(37, 2, textToolsApproval))
        assertEquals(39, healed(39, 2, textVisionToolsApproval))
        assertEquals(35, healed(35, 6, textVisionApproval))
        assertEquals(33, healed(33, 4, textApproval))
    }

    @Test fun legacyOwnershipAndConversationPredicatesAreStronglyTargeted() {
        val futureBit = 1 shl 25

        // Ownership shape (non-zero, editable-only), regardless of ON/OFF.
        assertTrue(ProviderFormLogic.isLegacyPartialCapabilityOverride(2))
        assertTrue(ProviderFormLogic.isLegacyPartialCapabilityOverride(6))
        assertFalse(ProviderFormLogic.isLegacyPartialCapabilityOverride(null))
        assertFalse(ProviderFormLogic.isLegacyPartialCapabilityOverride(0))
        assertFalse(ProviderFormLogic.isLegacyPartialCapabilityOverride(32))
        assertFalse(ProviderFormLogic.isLegacyPartialCapabilityOverride(33))
        assertFalse(ProviderFormLogic.isLegacyPartialCapabilityOverride(35))
        assertFalse(ProviderFormLogic.isLegacyPartialCapabilityOverride(2 or futureBit))

        // Narrow legacy inference: conversational base with TEXT AND the exact
        // editable-only ownership shape.
        assertTrue(ProviderFormLogic.isLegacyConversationCapabilityOverride(39, 2))
        assertTrue(ProviderFormLogic.isLegacyConversationCapabilityOverride(37, 2))
        assertTrue(ProviderFormLogic.isLegacyConversationCapabilityOverride(35, 6))
        assertTrue(ProviderFormLogic.isLegacyConversationCapabilityOverride(33, 4))
        // Reviewed zero / approval-only are complete decisions, not legacy.
        assertFalse(ProviderFormLogic.isLegacyConversationCapabilityOverride(39, 0))
        assertFalse(ProviderFormLogic.isLegacyConversationCapabilityOverride(37, 32))
        // Any valid complete override with TEXT keeps authority.
        assertFalse(ProviderFormLogic.isLegacyConversationCapabilityOverride(39, 35))
        assertFalse(ProviderFormLogic.isLegacyConversationCapabilityOverride(39, 1))
        // Unknown non-editable bits are never inferred as a legacy delta.
        assertFalse(ProviderFormLogic.isLegacyConversationCapabilityOverride(37, 2 or futureBit))
        // Media rows have no conversational TEXT role: their explicit 8/2 is
        // a complete media override, not a legacy delta.
        assertFalse(ProviderFormLogic.isLegacyConversationCapabilityOverride(24, 8))
        assertFalse(ProviderFormLogic.isLegacyConversationCapabilityOverride(24, 2))
        assertFalse(ProviderFormLogic.isLegacyConversationCapabilityOverride(null, 2))
        assertFalse(ProviderFormLogic.isLegacyConversationCapabilityOverride(37, null))

        // Full selected value comes FROM the complete base row, never from the
        // ownership mask. Main's exact cases:
        assertEquals(37, ProviderFormLogic.repairedLegacyExplicitCapabilities(37, 2))
        assertEquals(39, ProviderFormLogic.repairedLegacyExplicitCapabilities(39, 2))
        assertEquals(35, ProviderFormLogic.repairedLegacyExplicitCapabilities(35, 6))
        assertEquals(33, ProviderFormLogic.repairedLegacyExplicitCapabilities(33, 4))
        // Unknown non-editable base bits are preserved on a proven legacy row.
        assertEquals(39 or futureBit,
            ProviderFormLogic.repairedLegacyExplicitCapabilities(39 or futureBit, 2))
        // Reviewed 0 / 32, media, unknown and nil stay out of any repair.
        assertNull(ProviderFormLogic.repairedLegacyExplicitCapabilities(39, 0))
        assertNull(ProviderFormLogic.repairedLegacyExplicitCapabilities(37, 32))
        assertNull(ProviderFormLogic.repairedLegacyExplicitCapabilities(39, 35))
        assertNull(ProviderFormLogic.repairedLegacyExplicitCapabilities(39, 1))
        assertNull(ProviderFormLogic.repairedLegacyExplicitCapabilities(37, 2 or futureBit))
        assertNull(ProviderFormLogic.repairedLegacyExplicitCapabilities(24, 8))
        assertNull(ProviderFormLogic.repairedLegacyExplicitCapabilities(24, 2))
        assertNull(ProviderFormLogic.repairedLegacyExplicitCapabilities(39, null))
        assertNull(ProviderFormLogic.repairedLegacyExplicitCapabilities(null, 2))

        // Editor/emitter selected state: only a proven legacy row derives its
        // values from the base; every other explicit is authoritative.
        assertEquals(39, ProviderFormLogic.effectiveSelectedCapabilities(39, 2))
        assertEquals(37, ProviderFormLogic.effectiveSelectedCapabilities(37, 2))
        assertEquals(35, ProviderFormLogic.effectiveSelectedCapabilities(39, 35))
        assertEquals(0, ProviderFormLogic.effectiveSelectedCapabilities(39, 0))
        assertEquals(32, ProviderFormLogic.effectiveSelectedCapabilities(37, 32))
        assertEquals(8, ProviderFormLogic.effectiveSelectedCapabilities(24, 8))
        assertEquals(2, ProviderFormLogic.effectiveSelectedCapabilities(24, 2))
        assertEquals(2 or futureBit,
            ProviderFormLogic.effectiveSelectedCapabilities(37, 2 or futureBit))
        assertEquals(39, ProviderFormLogic.effectiveSelectedCapabilities(39, null))
        assertEquals(2, ProviderFormLogic.effectiveSelectedCapabilities(null, 2))
    }
}
