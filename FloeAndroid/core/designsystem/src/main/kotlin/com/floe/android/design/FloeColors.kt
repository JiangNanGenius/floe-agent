// SPDX-License-Identifier: MPL-2.0
package com.floe.android.design

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

/**
 * Floe semantic colors ported from `FloeAgent/FloeApp/Design/FloeTheme.swift`.
 *
 * The interactive accent is the SYSTEM BLUE observed in the captured iPad
 * references (Local/Private/android-g01-20261018/ios-reference/01-home.png:
 * selected capsule #0081F6, chrome circles, hairlines). It is deliberately
 * distinct from the private brand gradient stop `BrandBlue` (#3D7AF5): the
 * brand cyan-blue-violet ramp belongs to the logo/hero identity, while all
 * iOS navigation/selection controls render system blue (FloeTheme.primary =
 * .accentColor on iOS).
 *
 * Light values were sampled from the current 1.7.34 (275) capture; dark
 * values follow the same iOS system palette roles for dark appearance.
 * Reading surfaces are opaque; translucent roles keep iOS alpha semantics.
 */
@Immutable
data class FloeColors(
    val isDark: Boolean,
    /** Selection, progress and the primary action (iOS `.accentColor`). */
    val accent: Color,
    /** Pressed variant of the capsule selection background. */
    val accentPressed: Color,
    /** Brand ramp (logo/hero identity only; never a blanket chrome tint). */
    val brandCyan: Color,
    val brandBlue: Color,
    val brandViolet: Color,
    /** A decision that needs the user (approvals, provider-missing hints). */
    val pending: Color,
    /** Destructive actions and unambiguous failures. */
    val destructive: Color,
    /** Confirmed success only — never "not failed yet". */
    val success: Color,
    val label: Color,
    val secondaryLabel: Color,
    val tertiaryLabel: Color,
    val placeholderText: Color,
    /** Opaque reading surface (thread content, documents, evidence). */
    val readingSurface: Color,
    /** Opaque grey navigation plane (sidebar / drawer). */
    val sidebarSurface: Color,
    /** Grouped white cards on the grey plane (settings rows, chips). */
    val groupedSurface: Color,
    val sectionCardSurface: Color,
    /** Faint chrome fill for the composer bar and circular toolbar buttons. */
    val chromeSurface: Color,
    /** Circle behind mic-style composer affordances (accent @ ~9%). */
    val accentFillFaint: Color,
    /** User-message bubble (accent @ 14% on reading surface). */
    val accentFillBubble: Color,
    /** Disabled send circle / field wells. */
    val fillTertiary: Color,
    val separator: Color,
    /** Toolbar / hairline strokes over chrome. */
    val chromeHairline: Color,
) {
    companion object {
        /** The brand gradient stops (iOS FloeTheme.swift L24-26). */
        val BrandStopsLight = listOf(
            Color(0xFF1AC7DB), // cyan  (0.10, 0.78, 0.86)
            Color(0xFF3D7AF5), // blue  (0.24, 0.48, 0.96)
            Color(0xFF8F5CF0), // violet (0.56, 0.36, 0.94)
        )

        /** topLeading → bottomTrailing, reserved for selection/progress/primary. */
        fun brandGradient(): Brush = Brush.linearGradient(BrandStopsLight)
    }
}

/**
 * Light scheme values measured from the installed 1.7.34 (275) capture on the
 * canonical iPad (see module KDoc). Alpha roles keep iOS semantics so overlays
 * composite like the platform.
 */
internal val FloeLightColors = FloeColors(
    isDark = false,
    accent = Color(0xFF0081F6),
    accentPressed = Color(0xFF0071D9),
    brandCyan = Color(0xFF1AC7DB),
    brandBlue = Color(0xFF3D7AF5),
    brandViolet = Color(0xFF8F5CF0),
    pending = Color(0xFFFF9500),
    destructive = Color(0xFFFF3B30),
    success = Color(0xFF34C759),
    label = Color(0xFF000000),
    secondaryLabel = Color(0x993C3C43),
    tertiaryLabel = Color(0x4C3C3C43),
    placeholderText = Color(0x4C3C3C43),
    readingSurface = Color(0xFFFFFFFF),
    sidebarSurface = Color(0xFFE6EAEE),
    groupedSurface = Color(0xFFF2F2F7),
    sectionCardSurface = Color(0xFFFFFFFF),
    chromeSurface = Color(0xFFF6F6F7),
    accentFillFaint = Color(0x170081F6), // accent @ ~9%
    accentFillBubble = Color(0x240081F6), // accent @ ~14%
    fillTertiary = Color(0x1F767680),
    separator = Color(0xCCC6C6C8),
    chromeHairline = Color(0x0D000000),
)

internal val FloeDarkColors = FloeColors(
    isDark = true,
    accent = Color(0xFF0A84FF),
    accentPressed = Color(0xFF409CFF),
    brandCyan = Color(0xFF1AC7DB),
    brandBlue = Color(0xFF3D7AF5),
    brandViolet = Color(0xFF8F5CF0),
    pending = Color(0xFFFF9F0A),
    destructive = Color(0xFFFF453A),
    success = Color(0xFF30D158),
    label = Color(0xFFFFFFFF),
    secondaryLabel = Color(0xB3EBEBF5),
    tertiaryLabel = Color(0x59EBEBF5),
    placeholderText = Color(0x59EBEBF5),
    readingSurface = Color(0xFF000000),
    sidebarSurface = Color(0xFF1C1C1E),
    groupedSurface = Color(0xFF1C1C1E),
    sectionCardSurface = Color(0xFF2C2C2E),
    chromeSurface = Color(0xFF1C1C1E),
    accentFillFaint = Color(0x170A84FF),
    accentFillBubble = Color(0x240A84FF),
    fillTertiary = Color(0x33787880),
    separator = Color(0x66545458),
    chromeHairline = Color(0x1AFFFFFF),
)
