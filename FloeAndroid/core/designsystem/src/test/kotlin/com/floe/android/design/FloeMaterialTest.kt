// SPDX-License-Identifier: MPL-2.0
//
// Pure JVM policy checks for the shared Haze-backed material. These do not
// render a device or prove visual acceptance: they pin the old-device/fallback
// boundary, the level hierarchy used by chrome/sheets/popovers, and the
// compact toolbar-control geometry that C07 applies to the six-action document
// and media headers.

package com.floe.android.design

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FloeMaterialTest {

    @Test
    fun sdk31AndOlderUseTheOpaqueFallbackNeverTheRenderNodePath() {
        assertFalse(FloeMaterialSupport.supportsBlur(28))
        assertFalse(FloeMaterialSupport.supportsBlur(30))
        assertFalse(
            "SDK 31 is deliberately excluded for the known RenderNode invalidation defect",
            FloeMaterialSupport.supportsBlur(31),
        )
        assertTrue(FloeMaterialSupport.supportsBlur(32))
        assertTrue(FloeMaterialSupport.supportsBlur(36))
    }

    @Test
    fun disabledPreferenceAndMissingSceneBothKeepTheReadableFallback() {
        assertTrue(
            FloeMaterialSupport.usesOpaqueFallback(sdkInt = 28, userEnabled = true, hasSource = true),
        )
        assertTrue(
            FloeMaterialSupport.usesOpaqueFallback(sdkInt = 33, userEnabled = false, hasSource = true),
        )
        assertTrue(
            FloeMaterialSupport.usesOpaqueFallback(sdkInt = 33, userEnabled = true, hasSource = false),
        )
        assertFalse(
            FloeMaterialSupport.usesOpaqueFallback(sdkInt = 33, userEnabled = true, hasSource = true),
        )
    }

    @Test
    fun sheetAndPopoverStayMoreOpaqueThanChromeAndComposer() {
        assertTrue(FloeMaterialLevel.SHEET.surfaceAlpha(dark = false) > FloeMaterialLevel.COMPOSER.surfaceAlpha(dark = false))
        assertTrue(FloeMaterialLevel.SHEET.surfaceAlpha(dark = true) > FloeMaterialLevel.COMPOSER.surfaceAlpha(dark = true))
        assertTrue(FloeMaterialLevel.POPOVER.surfaceAlpha(dark = false) >= FloeMaterialLevel.CHROME.surfaceAlpha(dark = false))
        assertTrue(FloeMaterialLevel.POPOVER.surfaceAlpha(dark = true) >= FloeMaterialLevel.CHROME.surfaceAlpha(dark = true))
    }

    @Test
    fun everyLevelHasARealBlurRadiusAndReadableSurfaceAlpha() {
        FloeMaterialLevel.entries.forEach { level ->
            assertTrue("$level must request a real blur radius", level.blurRadius > 0.dp)
            assertTrue("$level light alpha", level.surfaceAlpha(dark = false) in 0.5f..1f)
            assertTrue("$level dark alpha", level.surfaceAlpha(dark = true) in 0.5f..1f)
            assertTrue("$level tint", level.tintAlpha(dark = false) in 0f..0.3f)
            assertTrue("$level noise", level.noise in 0f..0.2f)
        }
    }

    @Test
    fun compactToolbarControlKeepsIosGlyphScaleInsideTheAndroidTarget() {
        assertEquals(34.dp, FloeLayout.ToolbarCompactVisualSize)
        assertEquals(17.dp, FloeLayout.ToolbarCompactIconSize)
        assertEquals(48.dp, FloeLayout.MinimumTarget)
        assertTrue(FloeLayout.ToolbarCompactIconSize < FloeLayout.ToolbarButtonSize)
        assertTrue(FloeLayout.ToolbarCompactVisualSize < FloeLayout.ToolbarButtonSize)
    }
}
