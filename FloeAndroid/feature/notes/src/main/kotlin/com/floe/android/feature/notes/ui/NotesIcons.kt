// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

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
 * Feature-local geometric glyphs for Notes roles that the shared Floe icon
 * family does not cover (mind map, bookmark, page stack, layers, connect,
 * export/print …). They follow the same 24×24 grid, 1.8dp round stroke and
 * outline language as [com.floe.android.design.FloeIcons]; this is not a new
 * icon family and it copies no Apple-restricted symbol asset.
 */
internal object NotesIcons {

    private val strokeColor = SolidColor(Color.Black)
    private val fillColor = SolidColor(Color.Black)

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

    private fun ImageVector.Builder.fill(pathData: PathBuilder.() -> Unit) {
        path(
            fill = fillColor,
            pathFillType = PathFillType.NonZero,
            pathBuilder = { pathData() },
        )
    }

    private fun PathBuilder.circle(cx: Float, cy: Float, r: Float) {
        val k = r * 0.5523f
        moveTo(cx - r, cy)
        curveTo(cx - r, cy - k, cx - k, cy - r, cx, cy - r)
        curveTo(cx + k, cy - r, cx + r, cy - k, cx + r, cy)
        curveTo(cx + r, cy + k, cx + k, cy + r, cx, cy + r)
        curveTo(cx - k, cy + r, cx - r, cy + k, cx - r, cy)
        close()
    }

    /** pointy.3.connected.trianglepath.dotted role. */
    val MindMap: ImageVector = icon("notes.mind_map") {
        stroke { moveTo(7.4f, 12f); lineTo(11.2f, 12f) }
        stroke { moveTo(14.4f, 10.8f); lineTo(17.2f, 7.4f) }
        stroke { moveTo(14.4f, 13.2f); lineTo(17.2f, 16.6f) }
        stroke { circle(5.4f, 12f, 2.4f) }
        stroke { circle(18.8f, 6.2f, 2.4f) }
        stroke { circle(18.8f, 17.8f, 2.4f) }
    }

    /** bookmark role. */
    val Bookmark: ImageVector = icon("notes.bookmark") {
        stroke {
            moveTo(6.5f, 3.4f); lineTo(17.5f, 3.4f)
            curveTo(18.2f, 3.4f, 18.6f, 3.8f, 18.6f, 4.5f)
            lineTo(18.6f, 21f); lineTo(12f, 16.2f); lineTo(5.4f, 21f)
            lineTo(5.4f, 4.5f)
            curveTo(5.4f, 3.8f, 5.8f, 3.4f, 6.5f, 3.4f)
            close()
        }
    }

    /** bookmark.fill. */
    val BookmarkFilled: ImageVector = icon("notes.bookmark_filled") {
        fill {
            moveTo(6.5f, 3.4f); lineTo(17.5f, 3.4f)
            curveTo(18.2f, 3.4f, 18.6f, 3.8f, 18.6f, 4.5f)
            lineTo(18.6f, 21f); lineTo(12f, 16.2f); lineTo(5.4f, 21f)
            lineTo(5.4f, 4.5f)
            curveTo(5.4f, 3.8f, 5.8f, 3.4f, 6.5f, 3.4f)
            close()
        }
    }

    /** rectangle.stack / pages. */
    val Pages: ImageVector = icon("notes.pages") {
        stroke {
            moveTo(8f, 3f); lineTo(19f, 3f)
            curveTo(19.7f, 3f, 20.2f, 3.5f, 20.2f, 4.2f)
            lineTo(20.2f, 17.2f)
        }
        stroke {
            moveTo(4.8f, 6.4f); lineTo(15.8f, 6.4f)
            curveTo(16.5f, 6.4f, 17f, 6.9f, 17f, 7.6f)
            lineTo(17f, 20.6f)
            curveTo(17f, 21.3f, 16.5f, 21.8f, 15.8f, 21.8f)
            lineTo(4.8f, 21.8f)
            curveTo(4.1f, 21.8f, 3.6f, 21.3f, 3.6f, 20.6f)
            lineTo(3.6f, 7.6f)
            curveTo(3.6f, 6.9f, 4.1f, 6.4f, 4.8f, 6.4f)
            close()
        }
    }

    /** square.grid.2x2. */
    val Grid: ImageVector = icon("notes.grid") {
        stroke {
            moveTo(4f, 4f); lineTo(10.4f, 4f); lineTo(10.4f, 10.4f); lineTo(4f, 10.4f); close()
        }
        stroke {
            moveTo(13.6f, 4f); lineTo(20f, 4f); lineTo(20f, 10.4f); lineTo(13.6f, 10.4f); close()
        }
        stroke {
            moveTo(4f, 13.6f); lineTo(10.4f, 13.6f); lineTo(10.4f, 20f); lineTo(4f, 20f); close()
        }
        stroke {
            moveTo(13.6f, 13.6f); lineTo(20f, 13.6f); lineTo(20f, 20f); lineTo(13.6f, 20f); close()
        }
    }

    /** list.bullet. */
    val List: ImageVector = icon("notes.list") {
        stroke { circle(5f, 6.4f, 1.15f) }
        stroke { moveTo(9f, 6.4f); lineTo(20f, 6.4f) }
        stroke { circle(5f, 12f, 1.15f) }
        stroke { moveTo(9f, 12f); lineTo(20f, 12f) }
        stroke { circle(5f, 17.6f, 1.15f) }
        stroke { moveTo(9f, 17.6f); lineTo(20f, 17.6f) }
    }

    /** cursorarrow / select tool. */
    val Cursor: ImageVector = icon("notes.cursor") {
        stroke {
            moveTo(5.4f, 3.6f); lineTo(18.4f, 12.1f); lineTo(12.3f, 12.9f)
            lineTo(15.5f, 19.9f); lineTo(12.3f, 21.4f); lineTo(9.2f, 14.2f); lineTo(4.6f, 18.3f); close()
        }
    }

    /** textformat / text tool. */
    val TextTool: ImageVector = icon("notes.text_tool") {
        stroke { moveTo(5f, 5f); lineTo(19f, 5f) }
        stroke { moveTo(12f, 5f); lineTo(12f, 19.5f) }
        stroke { moveTo(8.6f, 19.5f); lineTo(15.4f, 19.5f) }
    }

    /** square.on.circle / shapes. */
    val Shapes: ImageVector = icon("notes.shapes") {
        stroke {
            moveTo(3.4f, 13.2f); lineTo(10.6f, 13.2f); lineTo(10.6f, 20.4f); lineTo(3.4f, 20.4f); close()
        }
        stroke { circle(16.2f, 8.4f, 4.8f) }
    }

    /** eraser. */
    val Eraser: ImageVector = icon("notes.eraser") {
        stroke {
            moveTo(14.4f, 3.8f); lineTo(20.2f, 9.6f); lineTo(11.2f, 18.6f)
            curveTo(10.4f, 19.4f, 9.4f, 19.4f, 8.7f, 18.7f)
            lineTo(5.3f, 15.3f)
            curveTo(4.6f, 14.6f, 4.6f, 13.6f, 5.4f, 12.8f)
            close()
        }
        stroke { moveTo(10f, 8.2f); lineTo(15.8f, 14f) }
        stroke { moveTo(8.2f, 18.8f); lineTo(20f, 18.8f) }
    }

    /** lasso. */
    val Lasso: ImageVector = icon("notes.lasso") {
        stroke {
            moveTo(12f, 3.4f)
            curveTo(17f, 3.4f, 20.6f, 5.8f, 20.6f, 9.2f)
            curveTo(20.6f, 12.6f, 17f, 15f, 12f, 15f)
            curveTo(7f, 15f, 3.4f, 12.6f, 3.4f, 9.2f)
            curveTo(3.4f, 5.8f, 7f, 3.4f, 12f, 3.4f)
            close()
        }
        stroke { moveTo(9.2f, 15.2f); curveTo(8.8f, 17.4f, 9.4f, 18.8f, 10.6f, 19.8f) }
        stroke { circle(10.6f, 20.4f, 1.2f) }
    }

    /** arrow.uturn.backward (undo). */
    val Undo: ImageVector = icon("notes.undo") {
        stroke {
            moveTo(8.4f, 6f); lineTo(4.2f, 10.2f); lineTo(8.4f, 14.4f)
        }
        stroke {
            moveTo(4.6f, 10.2f); lineTo(14.2f, 10.2f)
            curveTo(17.4f, 10.2f, 20f, 12.8f, 20f, 16f)
            curveTo(20f, 17.6f, 19.4f, 19f, 18.4f, 20f)
        }
    }

    /** arrow.uturn.forward (redo). */
    val Redo: ImageVector = icon("notes.redo") {
        stroke {
            moveTo(15.6f, 6f); lineTo(19.8f, 10.2f); lineTo(15.6f, 14.4f)
        }
        stroke {
            moveTo(19.4f, 10.2f); lineTo(9.8f, 10.2f)
            curveTo(6.6f, 10.2f, 4f, 12.8f, 4f, 16f)
            curveTo(4f, 17.6f, 4.6f, 19f, 5.6f, 20f)
        }
    }

    /** square.3.layers.3d. */
    val Layers: ImageVector = icon("notes.layers") {
        stroke { moveTo(12f, 3f); lineTo(20.8f, 7.4f); lineTo(12f, 11.8f); lineTo(3.2f, 7.4f); close() }
        stroke { moveTo(3.2f, 12f); lineTo(12f, 16.4f); lineTo(20.8f, 12f) }
        stroke { moveTo(3.2f, 16.4f); lineTo(12f, 20.8f); lineTo(20.8f, 16.4f) }
    }

    /** point.3.filled.connected.trianglepath.dotted (connect action). */
    val Connect: ImageVector = icon("notes.connect") {
        stroke { moveTo(7f, 17f); lineTo(17f, 7f) }
        stroke { circle(5.4f, 18.6f, 2.4f) }
        stroke { circle(18.6f, 5.4f, 2.4f) }
    }

    /** arrow.up.left.and.arrow.down.right / fit. */
    val Fit: ImageVector = icon("notes.fit") {
        stroke { moveTo(4f, 9f); lineTo(4f, 4f); lineTo(9f, 4f) }
        stroke { moveTo(15f, 4f); lineTo(20f, 4f); lineTo(20f, 9f) }
        stroke { moveTo(20f, 15f); lineTo(20f, 20f); lineTo(15f, 20f) }
        stroke { moveTo(9f, 20f); lineTo(4f, 20f); lineTo(4f, 15f) }
    }

    /** tag. */
    val Tag: ImageVector = icon("notes.tag") {
        stroke {
            moveTo(3.6f, 11.2f); lineTo(11.2f, 3.6f); lineTo(20.4f, 3.6f); lineTo(20.4f, 12.8f)
            lineTo(12.8f, 20.4f)
            curveTo(12.1f, 21.1f, 11f, 21.1f, 10.3f, 20.4f)
            lineTo(3.6f, 13.7f)
            curveTo(2.9f, 13f, 2.9f, 11.9f, 3.6f, 11.2f)
            close()
        }
        stroke { circle(16.2f, 7.8f, 1.4f) }
    }

    /** star / favorite. */
    val Star: ImageVector = icon("notes.star") {
        stroke {
            moveTo(12f, 3.2f); lineTo(14.6f, 8.6f); lineTo(20.5f, 9.4f); lineTo(16.2f, 13.5f)
            lineTo(17.3f, 19.4f); lineTo(12f, 16.6f); lineTo(6.7f, 19.4f); lineTo(7.8f, 13.5f)
            lineTo(3.5f, 9.4f); lineTo(9.4f, 8.6f); close()
        }
    }

    /** star.fill. */
    val StarFilled: ImageVector = icon("notes.star_filled") {
        fill {
            moveTo(12f, 3.2f); lineTo(14.6f, 8.6f); lineTo(20.5f, 9.4f); lineTo(16.2f, 13.5f)
            lineTo(17.3f, 19.4f); lineTo(12f, 16.6f); lineTo(6.7f, 19.4f); lineTo(7.8f, 13.5f)
            lineTo(3.5f, 9.4f); lineTo(9.4f, 8.6f); close()
        }
    }

    /** arrow.up.arrow.down / sort. */
    val Sort: ImageVector = icon("notes.sort") {
        stroke { moveTo(5f, 6.4f); lineTo(19f, 6.4f) }
        stroke { moveTo(7f, 12f); lineTo(17f, 12f) }
        stroke { moveTo(9.4f, 17.6f); lineTo(14.6f, 17.6f) }
    }

    /** minus. */
    val Minus: ImageVector = icon("notes.minus") {
        stroke { moveTo(5f, 12f); lineTo(19f, 12f) }
    }

    /** square.and.arrow.up / share. */
    val Share: ImageVector = icon("notes.share") {
        stroke { moveTo(12f, 15.4f); lineTo(12f, 3.2f) }
        stroke { moveTo(8.2f, 6.8f); lineTo(12f, 3f); lineTo(15.8f, 6.8f) }
        stroke {
            moveTo(6.2f, 11.4f); lineTo(4.2f, 11.4f); lineTo(4.2f, 20.8f); lineTo(19.8f, 20.8f)
            lineTo(19.8f, 11.4f); lineTo(17.8f, 11.4f)
        }
    }

    /** tray.and.arrow.down / import. */
    val Import: ImageVector = icon("notes.import") {
        stroke { moveTo(12f, 3.2f); lineTo(12f, 15f) }
        stroke { moveTo(8.2f, 11.2f); lineTo(12f, 15f); lineTo(15.8f, 11.2f) }
        stroke {
            moveTo(4.2f, 14.4f); lineTo(4.2f, 20.8f); lineTo(19.8f, 20.8f); lineTo(19.8f, 14.4f)
        }
    }

    /** printer. */
    val Print: ImageVector = icon("notes.print") {
        stroke {
            moveTo(6.8f, 8.4f); lineTo(6.8f, 3.4f); lineTo(17.2f, 3.4f); lineTo(17.2f, 8.4f)
        }
        stroke {
            moveTo(6.8f, 17f); lineTo(3.4f, 17f); lineTo(3.4f, 9.4f); lineTo(20.6f, 9.4f)
            lineTo(20.6f, 17f); lineTo(17.2f, 17f)
        }
        stroke {
            moveTo(6.8f, 13.6f); lineTo(17.2f, 13.6f); lineTo(17.2f, 21f)
            lineTo(6.8f, 21f); close()
        }
        stroke { circle(17.2f, 11.6f, 0.7f) }
    }

    /** doc / note. */
    val Document: ImageVector = icon("notes.document") {
        stroke {
            moveTo(5.4f, 3f); lineTo(14f, 3f); lineTo(18.6f, 7.6f); lineTo(18.6f, 21f)
            lineTo(5.4f, 21f); close()
        }
        stroke { moveTo(13.6f, 3.2f); lineTo(13.6f, 7.8f); lineTo(18.2f, 7.8f) }
        stroke { moveTo(8.2f, 12f); lineTo(15.8f, 12f) }
        stroke { moveTo(8.2f, 15.6f); lineTo(15.8f, 15.6f) }
        stroke { moveTo(8.2f, 19.2f); lineTo(13.4f, 19.2f) }
    }

    /** text.viewfinder / OCR. */
    val ScanText: ImageVector = icon("notes.scan_text") {
        stroke { moveTo(4f, 9f); lineTo(4f, 4f); lineTo(9f, 4f) }
        stroke { moveTo(15f, 4f); lineTo(20f, 4f); lineTo(20f, 9f) }
        stroke { moveTo(20f, 15f); lineTo(20f, 20f); lineTo(15f, 20f) }
        stroke { moveTo(9f, 20f); lineTo(4f, 20f); lineTo(4f, 15f) }
        stroke { moveTo(8f, 9.4f); lineTo(16f, 9.4f) }
        stroke { moveTo(8f, 12.6f); lineTo(16f, 12.6f) }
        stroke { moveTo(8f, 15.8f); lineTo(12.8f, 15.8f) }
    }

    /** paperplane / send. */
    val Send: ImageVector = icon("notes.send") {
        fill {
            moveTo(3.2f, 11.2f); lineTo(20.8f, 3.4f); lineTo(14.2f, 20.8f)
            lineTo(11.2f, 13.4f); close()
        }
        stroke { moveTo(11.2f, 13.4f); lineTo(20.2f, 4f) }
    }

    /** ellipsis.circle / more. */
    val MoreCircle: ImageVector = icon("notes.more_circle") {
        stroke { circle(12f, 12f, 9f) }
        stroke { circle(7.4f, 12f, 0.9f) }
        stroke { circle(12f, 12f, 0.9f) }
        stroke { circle(16.6f, 12f, 0.9f) }
    }

    /** square.and.pencil / new note. */
    val NewNote: ImageVector = icon("notes.new_note") {
        stroke {
            moveTo(5.2f, 21f); lineTo(5.2f, 4.6f)
            curveTo(5.2f, 3.9f, 5.7f, 3.4f, 6.4f, 3.4f)
            lineTo(13.2f, 3.4f)
        }
        stroke { moveTo(14.2f, 15.2f); lineTo(20.6f, 8.8f) }
        stroke { circle(19.2f, 7.2f, 1.4f) }
        stroke { moveTo(4.8f, 21f); lineTo(19.8f, 21f) }
    }

    /** checkmark.circle.badge.xmark not needed; simple check badge for saved. */
    val SaveCheck: ImageVector = icon("notes.save_check") {
        stroke { moveTo(4.4f, 5f); lineTo(4.4f, 20f); lineTo(19.6f, 20f); lineTo(19.6f, 8.4f) }
        stroke { moveTo(15.4f, 3.2f); lineTo(20.4f, 8.2f) }
        stroke { moveTo(8.2f, 14.2f); lineTo(11.4f, 17.4f); lineTo(17.4f, 10.4f) }
    }
}
