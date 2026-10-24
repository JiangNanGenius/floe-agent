// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide.ui

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
 * Feature-authored glyphs for the IDE in the Floe glyph family style: 24×24
 * geometric grid, uniform 1.8 stroke, round caps/joins. Shared design-system
 * assets stay untouched; these only cover roles the existing set lacks
 * (document, save, undo, redo, diff, hunk) and are candidates for promotion
 * into FloeIcons by Main when the icon inventory is centralized.
 */
internal object FloeIdeIcons {

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

    /** doc.text — one open page with a folded corner. */
    val DocPage = icon("floe.ide.doc_page") {
        stroke {
            moveTo(7f, 3.5f)
            lineTo(15f, 3.5f)
            lineTo(19.5f, 8f)
            lineTo(19.5f, 20.5f)
            lineTo(7f, 20.5f)
            close()
            moveTo(15f, 3.5f)
            lineTo(15f, 8f)
            lineTo(19.5f, 8f)
        }
    }

    /** square.and.arrow.down — save into the workspace. */
    val Save = icon("floe.ide.save") {
        stroke {
            moveTo(12f, 3.5f)
            lineTo(12f, 14.5f)
            moveTo(7.5f, 10f)
            lineTo(12f, 14.5f)
            lineTo(16.5f, 10f)
            moveTo(4.5f, 16f)
            lineTo(4.5f, 20.5f)
            lineTo(19.5f, 20.5f)
            lineTo(19.5f, 16f)
        }
    }

    /** arrow.uturn.backward — native undo. */
    val Undo = icon("floe.ide.undo") {
        stroke {
            moveTo(8f, 5f)
            lineTo(3.5f, 9.5f)
            lineTo(8f, 14f)
            moveTo(3.5f, 9.5f)
            lineTo(14f, 9.5f)
            curveTo(18.5f, 9.5f, 20.5f, 12.5f, 20.5f, 16.5f)
            lineTo(20.5f, 19f)
        }
    }

    /** arrow.uturn.forward — native redo. */
    val Redo = icon("floe.ide.redo") {
        stroke {
            moveTo(16f, 5f)
            lineTo(20.5f, 9.5f)
            lineTo(16f, 14f)
            moveTo(20.5f, 9.5f)
            lineTo(10f, 9.5f)
            curveTo(5.5f, 9.5f, 3.5f, 12.5f, 3.5f, 16.5f)
            lineTo(3.5f, 19f)
        }
    }

    /** arrow.left.arrow.right — diff / changes view. */
    val Diff = icon("floe.ide.diff") {
        stroke {
            moveTo(3.5f, 8f)
            lineTo(16f, 8f)
            moveTo(13f, 5f)
            lineTo(16f, 8f)
            lineTo(13f, 11f)
            moveTo(20.5f, 16f)
            lineTo(8f, 16f)
            moveTo(11f, 13f)
            lineTo(8f, 16f)
            lineTo(11f, 19f)
        }
    }

    /** textformat.subset — code language chip. */
    val Code = icon("floe.ide.code") {
        stroke {
            moveTo(8.5f, 6f)
            lineTo(4f, 12f)
            lineTo(8.5f, 18f)
            moveTo(15.5f, 6f)
            lineTo(20f, 12f)
            lineTo(15.5f, 18f)
        }
    }
}
