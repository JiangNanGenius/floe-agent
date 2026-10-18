// SPDX-License-Identifier: MPL-2.0
package com.floe.android.design

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
 * Floe glyph family: source-authored geometric outline icons on a 24x24 grid,
 * uniform 1.8 stroke, round caps and joins. They cover the semantic roles of
 * the iOS shell without copying SF Symbol path data or shipping the extended
 * Material icon catalog. Tint through [IconGlyph] (ColorFilter.tint).
 */
object FloeIcons {

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

    /* ---- geometric primitives (Bézier approximations, no arcTo) ---- */

    private fun PathBuilder.rrect(x0: Float, y0: Float, x1: Float, y1: Float, r: Float) {
        val k = r * 0.5523f
        moveTo(x0 + r, y0)
        lineTo(x1 - r, y0)
        curveTo(x1 - k, y0, x1, y0 + k, x1, y0 + r)
        lineTo(x1, y1 - r)
        curveTo(x1, y1 - k, x1 - k, y1, x1 - r, y1)
        lineTo(x0 + r, y1)
        curveTo(x0 + k, y1, x0, y1 - k, x0, y1 - r)
        lineTo(x0, y0 + r)
        curveTo(x0, y0 + k, x0 + k, y0, x0 + r, y0)
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

    /** Polyline; closes the subpath when asked. */
    private fun PathBuilder.poly(vararg pts: Pair<Float, Float>, closeIt: Boolean = false) {
        moveTo(pts.first().first, pts.first().second)
        pts.drop(1).forEach { lineTo(it.first, it.second) }
        if (closeIt) close()
    }

    private fun polar(cx: Float, cy: Float, angle: Float, radius: Float): Pair<Float, Float> =
        Pair(cx + kotlin.math.cos(angle) * radius, cy + kotlin.math.sin(angle) * radius)

    /**
     * True toothed gear outline: eight trapezoidal teeth on a root circle plus
     * the hub circle. The previous glyph drew a slotted circle with eight rays,
     * which read as a sun rather than the iPad `gearshape` (finish review F07).
     */
    private fun PathBuilder.gearOutline(cx: Float, cy: Float, teeth: Int, outer: Float, root: Float) {
        val step = (Math.PI * 2.0 / teeth).toFloat()
        val tipHalf = step * 0.15f
        val baseHalf = step * 0.30f
        for (i in 0 until teeth) {
            val angle = -Math.PI.toFloat() / 2f + i * step
            val p1 = polar(cx, cy, angle - baseHalf, root)
            val p2 = polar(cx, cy, angle - tipHalf, outer)
            val p3 = polar(cx, cy, angle + tipHalf, outer)
            val p4 = polar(cx, cy, angle + baseHalf, root)
            if (i == 0) moveTo(p1.first, p1.second) else lineTo(p1.first, p1.second)
            lineTo(p2.first, p2.second)
            lineTo(p3.first, p3.second)
            lineTo(p4.first, p4.second)
        }
        close()
    }

    /* ------------------------------ glyphs ------------------------------ */

    /** square.and.pencil — New Task. */
    val NewTask = icon("floe.new_task") {
        stroke {
            moveTo(10f, 3.5f); lineTo(7.6f, 3.5f)
            curveTo(5.3f, 3.5f, 3.5f, 5.3f, 3.5f, 7.6f)
            lineTo(3.5f, 16.4f)
            curveTo(3.5f, 18.7f, 5.3f, 20.5f, 7.6f, 20.5f)
            lineTo(16.4f, 20.5f)
            curveTo(18.7f, 20.5f, 20.5f, 18.7f, 20.5f, 16.4f)
            lineTo(20.5f, 14f)
        }
        stroke { moveTo(13.2f, 11.1f); lineTo(18.9f, 5.4f) }
        stroke { moveTo(12f, 12.3f); lineTo(11.2f, 14.9f); lineTo(13.8f, 14.1f) }
        stroke {
            moveTo(17.8f, 4.3f); lineTo(19.9f, 2.6f); lineTo(21.4f, 4.2f); lineTo(19.9f, 6.5f); lineTo(17.8f, 4.3f)
        }
    }

    /** checklist — Task Center. */
    val Checklist = icon("floe.checklist") {
        stroke { moveTo(3.5f, 6.6f); lineTo(5f, 8.1f); lineTo(7.8f, 5f) }
        stroke { moveTo(10.8f, 6.6f); lineTo(20.5f, 6.6f) }
        stroke { moveTo(3.5f, 17f); lineTo(5f, 18.5f); lineTo(7.8f, 15.4f) }
        stroke { moveTo(10.8f, 17f); lineTo(20.5f, 17f) }
        stroke { moveTo(3.5f, 11.9f); lineTo(7.8f, 11.9f) }
        stroke { circle(15.9f, 11.9f, 1.7f) }
    }

    /** book.pages — Notes. */
    val BookPages = icon("floe.book_pages") {
        stroke {
            moveTo(12f, 6.2f)
            curveTo(10.2f, 4.6f, 6.8f, 4.4f, 4.2f, 5.1f)
            lineTo(4.2f, 18.2f)
            curveTo(6.8f, 17.5f, 10.2f, 17.7f, 12f, 19.3f)
        }
        stroke {
            moveTo(12f, 6.2f)
            curveTo(13.8f, 4.6f, 17.2f, 4.4f, 19.8f, 5.1f)
            lineTo(19.8f, 18.2f)
            curveTo(17.2f, 17.5f, 13.8f, 17.7f, 12f, 19.3f)
        }
        stroke { moveTo(12f, 6.2f); lineTo(12f, 19.3f) }
    }

    /** rectangle.and.pencil.and.ellipsis — Creative mode. */
    val Creative = icon("floe.creative") {
        stroke {
            moveTo(9.5f, 3.8f); lineTo(6f, 3.8f)
            curveTo(4.6f, 3.8f, 3.5f, 4.9f, 3.5f, 6.3f)
            lineTo(3.5f, 17.5f)
            curveTo(3.5f, 18.9f, 4.6f, 20f, 6f, 20f)
            lineTo(17.5f, 20f)
            curveTo(18.9f, 20f, 20f, 18.9f, 20f, 17.5f)
            lineTo(20f, 13.5f)
        }
        stroke { circle(7.3f, 11.9f, 0.9f) }
        stroke { circle(11f, 11.9f, 0.9f) }
        stroke { circle(14.7f, 11.9f, 0.9f) }
        stroke { moveTo(15.5f, 7.5f); lineTo(20.5f, 2.5f) }
        stroke { moveTo(14.4f, 8.6f); lineTo(13.9f, 10.1f); lineTo(15.4f, 9.6f) }
    }

    /** puzzlepiece.extension — Plugins. */
    val Puzzle = icon("floe.puzzle") {
        stroke {
            moveTo(4f, 8.8f); lineTo(9.2f, 8.8f)
            curveTo(9.2f, 7f, 11.8f, 7f, 11.8f, 8.8f)
            lineTo(17f, 8.8f)
            lineTo(17f, 14.2f)
            curveTo(15.2f, 14.2f, 15.2f, 16.8f, 17f, 16.8f)
            lineTo(17f, 20.4f)
            lineTo(7f, 20.4f)
            curveTo(5.3f, 20.4f, 4f, 19.1f, 4f, 17.4f)
            close()
        }
    }

    /** gearshape — Settings (real toothed outline, source-authored). */
    val Gearshape = icon("floe.gearshape") {
        stroke { gearOutline(12f, 12f, teeth = 8, outer = 9.2f, root = 7.0f) }
        stroke { circle(12f, 12f, 3.0f) }
    }

    /** sidebar.left — collapse/expand the task list. */
    val SidebarToggle = icon("floe.sidebar") {
        stroke { rrect(3.5f, 4f, 19f, 20f, 2.5f) }
        stroke { moveTo(9.6f, 4.2f); lineTo(9.6f, 19.8f) }
    }

    /** bubble.left — conversations / temporary chat. */
    val Bubble = icon("floe.bubble") {
        stroke {
            moveTo(12.5f, 4.2f)
            curveTo(7.4f, 4.2f, 3.6f, 7.1f, 3.6f, 10.7f)
            curveTo(3.6f, 12.8f, 5f, 14.6f, 7.1f, 15.7f)
            lineTo(6.5f, 19.4f)
            lineTo(10.6f, 17.1f)
            curveTo(11.2f, 17.2f, 11.9f, 17.2f, 12.5f, 17.2f)
            curveTo(17.6f, 17.2f, 21.4f, 14.3f, 21.4f, 10.7f)
            curveTo(21.4f, 7.1f, 17.6f, 4.2f, 12.5f, 4.2f)
        }
    }

    /** folder — workspace rows. */
    val Folder = icon("floe.folder") {
        stroke {
            moveTo(3.8f, 9.4f)
            lineTo(3.8f, 6.6f)
            curveTo(3.8f, 5.7f, 4.5f, 5f, 5.4f, 5f)
            lineTo(8.9f, 5f)
            lineTo(10.9f, 7.2f)
            lineTo(18.6f, 7.2f)
            curveTo(19.5f, 7.2f, 20.2f, 7.9f, 20.2f, 8.8f)
            lineTo(20.2f, 17.4f)
            curveTo(20.2f, 18.3f, 19.5f, 19f, 18.6f, 19f)
            lineTo(5.4f, 19f)
            curveTo(4.5f, 19f, 3.8f, 18.3f, 3.8f, 17.4f)
            close()
        }
    }

    val Plus = icon("floe.plus") { stroke { moveTo(12f, 5f); lineTo(12f, 19f); moveTo(5f, 12f); lineTo(19f, 12f) } }
    val ChevronForward = icon("floe.chevron_forward") { stroke { moveTo(9f, 5f); lineTo(16f, 12f); lineTo(9f, 19f) } }
    val ChevronDown = icon("floe.chevron_down") { stroke { moveTo(5.5f, 9f); lineTo(12f, 15.5f); lineTo(18.5f, 9f) } }
    val ChevronBack = icon("floe.chevron_back") { stroke { moveTo(15f, 5f); lineTo(8f, 12f); lineTo(15f, 19f) } }
    val ChevronUp = icon("floe.chevron_up") { stroke { moveTo(5.5f, 15f); lineTo(12f, 8.5f); lineTo(18.5f, 15f) } }

    /** paperclip — composer attachment. */
    val Paperclip = icon("floe.paperclip") {
        stroke {
            moveTo(15.6f, 4.6f)
            lineTo(7.9f, 12.3f)
            curveTo(6.4f, 13.8f, 6.4f, 16.1f, 7.9f, 17.6f)
            curveTo(9.4f, 19.1f, 11.7f, 19.1f, 13.2f, 17.6f)
            lineTo(19.7f, 11.1f)
            curveTo(21f, 9.8f, 21f, 7.7f, 19.7f, 6.4f)
        }
    }

    /** mic — voice input affordance. */
    val Mic = icon("floe.mic") {
        stroke {
            rrect(9.4f, 3.2f, 14.6f, 14f, 2.6f)
        }
        stroke {
            moveTo(6.2f, 11.4f)
            curveTo(6.2f, 14.6f, 8.8f, 16.9f, 12f, 16.9f)
            curveTo(15.2f, 16.9f, 17.8f, 14.6f, 17.8f, 11.4f)
        }
        stroke { moveTo(12f, 16.9f); lineTo(12f, 20.8f) }
    }

    /** arrow.up — send. */
    val ArrowUp = icon("floe.arrow_up") {
        stroke { moveTo(12f, 19.2f); lineTo(12f, 5f); moveTo(5.8f, 11.2f); lineTo(12f, 5f); lineTo(18.2f, 11.2f) }
    }

    /** stop — running stop. */
    val StopSquare = icon("floe.stop") { stroke { rrect(6.4f, 6.4f, 17.6f, 17.6f, 2.6f) } }

    /** cpu — model chip. */
    val Chip = icon("floe.chip") {
        stroke { rrect(6.8f, 6.8f, 17.2f, 17.2f, 1.6f) }
        stroke { circle(12f, 12f, 2.4f) }
        stroke {
            moveTo(9.5f, 3.6f); lineTo(9.5f, 6.2f)
            moveTo(14.5f, 3.6f); lineTo(14.5f, 6.2f)
            moveTo(9.5f, 17.8f); lineTo(9.5f, 20.4f)
            moveTo(14.5f, 17.8f); lineTo(14.5f, 20.4f)
            moveTo(3.6f, 9.5f); lineTo(6.2f, 9.5f)
            moveTo(3.6f, 14.5f); lineTo(6.2f, 14.5f)
            moveTo(17.8f, 9.5f); lineTo(20.4f, 9.5f)
            moveTo(17.8f, 14.5f); lineTo(20.4f, 14.5f)
        }
    }

    /** gauge — reasoning "automatic". */
    val Gauge = icon("floe.gauge") {
        stroke {
            moveTo(3.8f, 15.5f)
            curveTo(3.8f, 10.3f, 7.4f, 6.6f, 12f, 6.6f)
            curveTo(16.6f, 6.6f, 20.2f, 10.3f, 20.2f, 15.5f)
        }
        stroke { moveTo(12f, 15.5f); lineTo(15.6f, 10.6f) }
        stroke { circle(12f, 15.5f, 0.9f) }
    }

    /** wand.and.sparkles — agent mode. */
    val Wand = icon("floe.wand") {
        stroke { moveTo(4.5f, 19.5f); lineTo(13.5f, 10.5f) }
        stroke { moveTo(12.4f, 7.2f); lineTo(16.8f, 11.6f); moveTo(16.8f, 7.2f); lineTo(12.4f, 11.6f) }
        stroke { moveTo(19f, 3f); lineTo(19f, 5.6f); moveTo(17.7f, 4.3f); lineTo(20.3f, 4.3f) }
        stroke { moveTo(6.5f, 4.5f); lineTo(6.5f, 6.5f); moveTo(5.5f, 5.5f); lineTo(7.5f, 5.5f) }
    }

    /** list.bullet.clipboard — plan mode. */
    val PlanList = icon("floe.plan_list") {
        stroke { rrect(5.5f, 4.4f, 18.5f, 20f, 2f) }
        stroke { moveTo(8.5f, 3.6f); lineTo(12.5f, 3.6f) }
        stroke { moveTo(8.5f, 10.5f); lineTo(15.5f, 10.5f) }
        stroke { moveTo(8.5f, 14f); lineTo(15.5f, 14f) }
    }

    /** target — goal mode. */
    val Target = icon("floe.target") {
        stroke { circle(12f, 12f, 7.8f) }
        stroke { circle(12f, 12f, 4.2f) }
        stroke { circle(12f, 12f, 0.4f) }
    }

    /** desktopcomputer — execution target "This device". */
    val DeviceLocal = icon("floe.device_local") {
        stroke { rrect(3.5f, 5f, 20.5f, 15.5f, 1.8f) }
        stroke { moveTo(9f, 19.5f); lineTo(15f, 19.5f); moveTo(12f, 15.5f); lineTo(12f, 19.5f) }
    }

    /** checkmark.shield — approval mode chip. */
    val ShieldCheck = icon("floe.shield_check") {
        stroke {
            moveTo(12f, 3.2f); lineTo(19.2f, 5.9f); lineTo(19.2f, 11f)
            curveTo(19.2f, 15.7f, 16f, 19.2f, 12f, 20.6f)
            curveTo(8f, 19.2f, 4.8f, 15.7f, 4.8f, 11f)
            lineTo(4.8f, 5.9f); close()
        }
        stroke { moveTo(9.4f, 11.6f); lineTo(11.4f, 13.6f); lineTo(15f, 9.4f) }
    }

    /** exclamationmark.shield — pending approval card. */
    val ShieldAlert = icon("floe.shield_alert") {
        stroke {
            moveTo(12f, 3.2f); lineTo(19.2f, 5.9f); lineTo(19.2f, 11f)
            curveTo(19.2f, 15.7f, 16f, 19.2f, 12f, 20.6f)
            curveTo(8f, 19.2f, 4.8f, 15.7f, 4.8f, 11f)
            lineTo(4.8f, 5.9f); close()
        }
        stroke { moveTo(12f, 8.4f); lineTo(12f, 12.6f) }
        stroke { circle(12f, 15.6f, 0.7f) }
    }

    /** stethoscope — diagnostics. */
    val Stethoscope = icon("floe.stethoscope") {
        stroke {
            moveTo(5.5f, 3.2f); lineTo(5.5f, 8.5f)
            curveTo(5.5f, 10.4f, 7.1f, 11.9f, 8.9f, 11.9f)
            curveTo(10.7f, 11.9f, 12.3f, 10.4f, 12.3f, 8.5f)
            lineTo(12.3f, 3.2f)
        }
        stroke {
            moveTo(8.9f, 11.9f); lineTo(8.9f, 14.5f)
            curveTo(8.9f, 16.8f, 10.7f, 18.5f, 13f, 18.5f)
            curveTo(15.3f, 18.5f, 17.1f, 16.8f, 17.1f, 14.5f)
            lineTo(17.1f, 13f)
        }
        stroke { circle(17.1f, 10.5f, 2.4f) }
    }

    val Xmark = icon("floe.xmark") { stroke { moveTo(6f, 6f); lineTo(18f, 18f); moveTo(18f, 6f); lineTo(6f, 18f) } }
    val Checkmark = icon("floe.checkmark") { stroke { moveTo(4.5f, 12.8f); lineTo(9.4f, 17.7f); lineTo(19.5f, 6.6f) } }

    /** clock — scheduled section. */
    val Clock = icon("floe.clock") {
        stroke { circle(12f, 12f, 8f) }
        stroke { moveTo(12f, 7.6f); lineTo(12f, 12f); lineTo(15.2f, 13.9f) }
    }

    /** play.rectangle — runs. */
    val PlayRuns = icon("floe.play_runs") {
        stroke { rrect(4.2f, 4.2f, 19.8f, 19.8f, 2.4f) }
        stroke { poly(Pair(10f, 9f), Pair(15f, 12f), Pair(10f, 15f), closeIt = true) }
    }

    /** info.circle — honest availability dialogs. */
    val InfoCircle = icon("floe.info_circle") {
        stroke { circle(12f, 12f, 8f) }
        stroke { moveTo(12f, 11f); lineTo(12f, 16f) }
        stroke { circle(12f, 8.2f, 0.7f) }
    }

    /** terminal — execution environment placeholder. */
    val Terminal = icon("floe.terminal") {
        stroke { rrect(4.2f, 4.2f, 19.8f, 19.8f, 2.4f) }
        stroke { moveTo(7.5f, 9f); lineTo(11f, 12f); lineTo(7.5f, 15f) }
        stroke { moveTo(13f, 15f); lineTo(16.5f, 15f) }
    }
}
