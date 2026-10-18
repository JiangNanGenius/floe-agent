// SPDX-License-Identifier: MPL-2.0
package com.floe.android.design

import androidx.compose.runtime.Immutable
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * Typography roles mirroring `FloeTheme.Typography` (title2 semibold /
 * headline / body / footnote / footnote-monospaced). Sizes use sp so the
 * system font-size setting scales them. SF Pro cannot be bundled, so the
 * platform sans (Roboto/system) is used and the metric difference is a
 * documented local adaptation, not a hidden one.
 */
@Immutable
data class FloeTypography(
    /** Screen / section hero title (iOS .title2 semibold, 22pt). */
    val title: TextStyle = TextStyle(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.SemiBold),
    /** Section header inside a screen (iOS .headline, 17 semibold). */
    val section: TextStyle = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold),
    /** Primary reading text (iOS .body, 17pt). */
    val body: TextStyle = TextStyle(fontSize = 17.sp, lineHeight = 24.sp, fontWeight = FontWeight.Normal),
    /** Body emphasis (assistant message leads, row titles). */
    val bodyEmphasized: TextStyle = TextStyle(fontSize = 17.sp, lineHeight = 24.sp, fontWeight = FontWeight.Medium),
    /** Toolbar titles (iOS inline navigation title, 17 semibold). */
    val toolbarTitle: TextStyle = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold),
    /** Large nav title (iOS .largeTitle on detail headers, 34 bold). */
    val navLargeTitle: TextStyle = TextStyle(fontSize = 34.sp, lineHeight = 41.sp, fontWeight = FontWeight.Bold),
    /** Timestamps, counts, secondary context (iOS .footnote, 13pt). */
    val metadata: TextStyle = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Normal),
    /** Section headers above grouped lists (iOS sidebar group headers). */
    val groupHeader: TextStyle = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Normal),
    /** Terminal output, evidence payloads, fingerprints, JSON (iOS .footnote monospaced). */
    val evidence: TextStyle = TextStyle(
        fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Normal,
        fontFamily = FontFamily.Monospace
    ),
    /** Composer input text (iOS body, 17pt). */
    val composerField: TextStyle = TextStyle(fontSize = 17.sp, lineHeight = 24.sp, fontWeight = FontWeight.Normal),
)
