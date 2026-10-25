// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.browser.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathBuilder
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/**
 * Feature-authored glyphs for the browser panel in the Floe glyph family
 * style: 24×24 geometric grid, uniform 1.8 stroke, round caps/joins. Shared
 * design-system assets stay untouched; these only cover roles the existing
 * set lacks (globe, hand takeover, tab strip) and are candidates for
 * promotion into FloeIcons by Main when the icon inventory is centralized.
 *
 * Public so the App's exact-owner pane can render the same honest unbound
 * glyph as the sheet (icon parity, no duplicate glyph).
 */
public object FloeBrowserIcons {

    private val strokeColor = SolidColor(Color.Black)

    private fun icon(name: String, block: ImageVector.Builder.() -> Unit): ImageVector =
        ImageVector.Builder(
            name = name,
            defaultWidth = 24.dp,
            defaultHeight = 24.dp,
            viewportWidth = 24f,
            viewportHeight = 24f,
        ).apply(block).build()

    private fun ImageVector.Builder.stroke(pathData: PathBuilder.() -> Unit) {
        path(
            fill = null,
            stroke = strokeColor,
            strokeLineWidth = 1.8f,
            strokeLineCap = StrokeCap.Round,
            strokeLineJoin = StrokeJoin.Round,
            pathFillType = PathFillType.NonZero,
            pathBuilder = { pathData() },
        )
    }

    private fun PathBuilder.rrect(x0: Float, y0: Float, x1: Float, y1: Float, r: Float) {
        val k = r * 0.5523f
        moveTo(x0 + r, y0)
        lineTo(x1 - r, y0)
        curveTo(x1 - k, y0, x1, y0 + k, x1, y0 + r)
        lineTo(x1, y1 - r)
        curveTo(x1, y1 - k, x1 - k, y1, x1 - r, y1)
        lineTo(x0 + r, y1)
        curveTo(x0 + k, y1, x0, y0 + k, x0, y1 - r)
        lineTo(x0, y0 + r)
        curveTo(x0 + k, y0 + k, x0, y0 + k, x0 + r, y0)
    }

    /** globe — the browser role. */
    val Globe = icon("floe.browser.globe") {
        stroke {
            // circle(12, 12, 8)
            val cx = 12f
            val cy = 12f
            val r = 8f
            val k = r * 0.5523f
            moveTo(cx + r, cy)
            curveTo(cx + r, cy + k, cx + k, cy + r, cx, cy + r)
            curveTo(cx - k, cy + r, cx - r, cy + k, cx - r, cy)
            curveTo(cx - r, cy - k, cx - k, cy - r, cx, cy - r)
            curveTo(cx + k, cy - r, cx + r, cy - k, cx + r, cy)
        }
        stroke {
            moveTo(4f, 12f)
            lineTo(20f, 12f)
        }
        stroke {
            moveTo(12f, 4f)
            curveTo(14.8f, 7f, 14.8f, 17f, 12f, 20f)
            moveTo(12f, 4f)
            curveTo(9.2f, 7f, 9.2f, 17f, 12f, 20f)
        }
    }

    /** hand.tap — take control (user takeover). */
    val HandTap = icon("floe.browser.hand_tap") {
        stroke {
            // simplified open hand pressing a surface line
            moveTo(9f, 10.5f)
            lineTo(9f, 5.8f)
            curveTo(9f, 4.8f, 10.6f, 4.8f, 10.6f, 5.8f)
            lineTo(10.6f, 10f)
            moveTo(10.6f, 9.6f)
            lineTo(10.6f, 4.6f)
            curveTo(10.6f, 3.6f, 12.2f, 3.6f, 12.2f, 4.6f)
            lineTo(12.2f, 10f)
            moveTo(12.2f, 9.8f)
            lineTo(12.2f, 5.6f)
            curveTo(12.2f, 4.6f, 13.8f, 4.6f, 13.8f, 5.6f)
            lineTo(13.8f, 12f)
            moveTo(8.4f, 12f)
            curveTo(7.4f, 11f, 6f, 11.4f, 6.6f, 12.8f)
            lineTo(8.6f, 16.4f)
            curveTo(9.4f, 18f, 10.4f, 18.4f, 12f, 18.4f)
            lineTo(13.8f, 18.4f)
        }
        stroke {
            moveTo(4f, 21f)
            lineTo(20f, 21f)
        }
    }

    /** rectangle.stack — the tab strip. */
    val TabStrip = icon("floe.browser.tab_strip") {
        stroke { rrect(4f, 8f, 20f, 19f, 2.4f) }
        stroke {
            moveTo(7f, 8f)
            lineTo(8.4f, 4.6f)
            lineTo(15.6f, 4.6f)
            lineTo(17f, 8f)
        }
    }

    /** arrow.right — commit the typed address (visible Go action). */
    val Go = icon("floe.browser.go") {
        stroke {
            moveTo(5f, 12f)
            lineTo(18.6f, 12f)
        }
        stroke {
            moveTo(13.6f, 7f)
            lineTo(18.8f, 12f)
            lineTo(13.6f, 17f)
        }
    }

    /** arrow.trianglehead.clockwise — reload/retry. */
    val Retry = icon("floe.browser.retry") {
        stroke {
            val cx = 12f
            val cy = 12f
            val r = 7f
            val k = r * 0.5523f
            moveTo(cx + r, cy)
            curveTo(cx + r, cy + k, cx + k, cy + r, cx, cy + r)
            curveTo(cx - k, cy + r, cx - r, cy + k, cx - r, cy)
            curveTo(cx - r, cy - k, cx - k, cy - r, cx, cy - r)
            curveTo(cx + k * 0.6f, cy - r, cx + r * 0.9f, cy - k, cx + r, cy - r * 0.45f)
        }
        stroke {
            moveTo(19f, 4.6f)
            lineTo(19f, 8.4f)
            lineTo(15.2f, 8.4f)
        }
    }
}
