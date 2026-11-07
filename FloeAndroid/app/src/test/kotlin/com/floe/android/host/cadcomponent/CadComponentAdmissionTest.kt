// SPDX-License-Identifier: MPL-2.0
// Boundary regressions for the exact predicates used by optional split and
// CAD pin admission. Package installation, signatures and rendering are
// independently verified from the produced artifacts and actual App flow.
package com.floe.android.host.cadcomponent

import com.floe.android.host.cad.CadViewerAssets
import com.floe.android.host.optionalsplit.OptionalComponentSpec
import com.floe.android.host.optionalsplit.OptionalComponentState
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CadComponentAdmissionTest {
    private inline fun assertRefused(block: () -> Unit) {
        try {
            block()
        } catch (error: IllegalArgumentException) {
            return
        }
        throw AssertionError("spec identity drift was not refused")
    }

    @Test
    fun specValidationFailsClosedOnIdentityDrift() {
        fun spec(module: String = "cadpreview", prefs: String = "cad_component_install",
            action: String = "com.floe.cad.COMPONENT_INSTALL_RESULT",
            staging: String = "CadComponent") = OptionalComponentSpec(
            module = module,
            prefsName = prefs,
            stagingDir = staging,
            assetName = { CadComponentController.assetName() },
            resultAction = action,
            resultReceiver = null,
            downloadService = null,
            installed = { false },
        )
        // Valid identities construct.
        spec()
        spec(module = "officepreview", prefs = "office_component_install",
            action = "com.floe.office.COMPONENT_INSTALL_RESULT",
            staging = "OfficeComponent")
        // Drift is refused, never silently corrected.
        assertRefused { spec(module = "CADpreview") }
        assertRefused { spec(module = "cad preview") }
        assertRefused { spec(module = "") }
        assertRefused { spec(prefs = "cad component install") }
        assertRefused { spec(action = "http://example.com/x") }
        assertRefused { spec(action = "com.floe.cad." + "x".repeat(200)) }
        assertRefused { spec(staging = "../escape") }
        assertRefused { spec(staging = ".") }
        assertRefused { spec(staging = "..") }
        assertRefused { spec(staging = "a/b") }
    }

    @Test
    fun onlyManifestPinnedNamesWithWellFormedRowsAreServable() {
        assertTrue(CadViewerAssets.validPinnedName("index.html"))
        assertTrue(CadViewerAssets.validPinnedName("floe_cad_engine_bg.wasm"))
        assertTrue(CadViewerAssets.validPinnedName("MiSans-Regular.ttf"))
        assertFalse(CadViewerAssets.validPinnedName("nested/index.html"))
        assertFalse(CadViewerAssets.validPinnedName("..%2fsecret"))
        assertFalse(CadViewerAssets.validPinnedName("a\\b"))
        assertFalse(CadViewerAssets.validPinnedName(""))
        assertFalse(CadViewerAssets.validPinnedName("."))
        assertFalse(CadViewerAssets.validPinnedName(".."))
        assertFalse(CadViewerAssets.validPinnedName("x".repeat(129)))

        val digest = "a".repeat(64)
        assertTrue(CadViewerAssets.validPinRow("viewer.js", 19760, digest))
        assertFalse(CadViewerAssets.validPinRow("viewer.js", -1, digest))
        assertFalse(CadViewerAssets.validPinRow("viewer.js", 65L * 1024 * 1024, digest))
        assertFalse(CadViewerAssets.validPinRow("viewer.js", 19760, digest.uppercase()))
        assertFalse(CadViewerAssets.validPinRow("viewer.js", 19760, digest.take(63)))
    }

}
