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
        val on = ProviderFormLogic.applyModelEdit(listOf(off),
            off.copy(capabilities = original.capabilities), null).first.single()
        assertEquals(6, on.savedMetadata!!.explicitCapabilitiesRaw)
        assertEquals("6", on.savedMetadata!!.explicitCapabilitiesJSON)
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
        assertEquals(2, result.savedMetadata!!.explicitCapabilitiesRaw)
        assertEquals("2", result.savedMetadata!!.explicitCapabilitiesJSON)
    }

    @Test fun explicitNewEmptyCapabilitiesCarryReviewInsteadOfNewRowDefaults() {
        val original = row().copy(savedModelId = null, source = ModelSourceUi.MANUAL, savedMetadata = null)
        val edited = original.copy(capabilities = emptySet())
        val result = ProviderFormLogic.applyModelEdit(listOf(original), edited, null).first.single()
        assertTrue(result.capabilities.isEmpty())
        assertEquals(0, result.savedMetadata!!.capabilitiesRaw)
        assertEquals(4, result.savedMetadata!!.explicitCapabilitiesRaw)
    }
}
