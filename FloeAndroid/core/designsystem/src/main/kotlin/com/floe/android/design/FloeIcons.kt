// SPDX-License-Identifier: MPL-2.0
package com.floe.android.design

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathBuilder
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.graphics.vector.group
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/**
 * Floe glyph family for the iOS-shaped shell.
 *
 * Most glyphs are single-fill outlines generated from the MIT-licensed
 * `CupertinoIcons.ttf` (Flutter third_party `cupertino_icons` 2.0.0), which is
 * handcrafted to preserve the SF Symbols style. The generated path data lives
 * in [FloeGlyphPaths] (see that header for the pinned archive/font/tool hashes);
 * the font binary itself is not shipped or depended on at runtime, and the
 * upstream MIT text is bundled at `assets/legal/cupertino-icons/LICENSE`.
 * A small set of roles has no glyph in the pinned family (see
 * `licenses/cupertino-icons/PROVENANCE.json`) and keeps
 * the original source-authored geometric outline style (24x24 grid, 1.8
 * stroke, round caps and joins). No Apple-proprietary font or glyph asset is
 * copied. Tint semantics are unchanged through [IconGlyph]
 * (ColorFilter.tint); default 24dp boxes and public value names are stable.
 */
object FloeIcons {

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

    /** Fill a generated CupertinoIcons-derived outline (nonzero winding). */
    private fun ImageVector.Builder.glyph(key: String) {
        addPath(
            pathData = PathParser().parsePathString(FloeGlyphPaths.all.getValue(key)).toNodes(),
            fill = fillColor,
            pathFillType = PathFillType.NonZero,
        )
    }

    private fun glyphIcon(name: String, key: String): ImageVector =
        icon(name) { glyph(key) }

    /* ---- geometric primitives (fallback family only) ---- */

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

    /* ------------------------------ glyphs ------------------------------ */

    /** iOS square.and.pencil — New Task (Cupertino "square_pencil" U+F417). */
    val NewTask: ImageVector = glyphIcon("floe.new_task", "square_pencil")

    /** checklist — Task Center. Hand-drawn fallback (no 2.0.0 checklist glyph). */
    val Checklist = icon("floe.checklist") {
        stroke { moveTo(3.5f, 6.6f); lineTo(5f, 8.1f); lineTo(7.8f, 5f) }
        stroke { moveTo(10.8f, 6.6f); lineTo(20.5f, 6.6f) }
        stroke { moveTo(3.5f, 17f); lineTo(5f, 18.5f); lineTo(7.8f, 15.4f) }
        stroke { moveTo(10.8f, 17f); lineTo(20.5f, 17f) }
        stroke { moveTo(3.5f, 11.9f); lineTo(7.8f, 11.9f) }
        stroke { circle(15.9f, 11.9f, 1.7f) }
    }

    /** iOS book.pages role — Notes (Cupertino "book" U+F3E7, closest single glyph). */
    val BookPages: ImageVector = glyphIcon("floe.book_pages", "book")

    /** iOS rectangle.and.pencil.and.ellipsis — Creative (Cupertino "pencil_ellipsis_rectangle"). */
    val Creative: ImageVector = glyphIcon("floe.creative", "pencil_ellipsis_rectangle")

    /** puzzlepiece.extension — Plugins. Hand-drawn fallback (no 2.0.0 puzzle glyph). */
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

    /** iOS gearshape — Settings (Cupertino "gear_alt" U+F43C; Main-previewed variant). */
    val Gearshape: ImageVector = glyphIcon("floe.gearshape", "gear_alt")

    /** iOS sidebar.left — collapse/expand the task list (Cupertino "sidebar_left"). */
    val SidebarToggle: ImageVector = glyphIcon("floe.sidebar", "sidebar_left")

    /** iOS sidebar.right — the same generated outline mirrored in its 24x24 viewport. */
    val SidebarTrailing: ImageVector = icon("floe.sidebar_trailing") {
        group(scaleX = -1f, pivotX = 12f) { glyph("sidebar_left") }
    }

    /** iOS bubble.left — conversations / temporary chat (Cupertino "bubble_left"). */
    val Bubble: ImageVector = glyphIcon("floe.bubble", "bubble_left")

    /** iOS folder — workspace rows (Cupertino "folder" U+F434). */
    val Folder: ImageVector = glyphIcon("floe.folder", "folder")

    /** iOS plus (Cupertino "plus"). */
    val Plus: ImageVector = glyphIcon("floe.plus", "plus")

    /** iOS ellipsis.circle chrome pair — compact More toolbar trigger. The
     *  dots glyph is the pinned Cupertino "ellipsis" outline; the enclosing
     *  circle comes from FloeCircleButton (iOS: FileInspectorView.swift:320
     *  workspaceActions, FilePreviewView.swift:841 file.preview.more). */
    val Ellipsis: ImageVector = glyphIcon("floe.ellipsis", "ellipsis")

    /** iOS chevron.right (Cupertino "chevron_right"). */
    val ChevronForward: ImageVector = glyphIcon("floe.chevron_forward", "chevron_right")

    /** iOS chevron.down (Cupertino "chevron_down"). */
    val ChevronDown: ImageVector = glyphIcon("floe.chevron_down", "chevron_down")

    /** iOS chevron.left (Cupertino "chevron_left"). */
    val ChevronBack: ImageVector = glyphIcon("floe.chevron_back", "chevron_left")

    /** iOS chevron.up (Cupertino "chevron_up"). */
    val ChevronUp: ImageVector = glyphIcon("floe.chevron_up", "chevron_up")

    /** iOS paperclip — composer attachment (Cupertino "paperclip" U+F732). */
    val Paperclip: ImageVector = glyphIcon("floe.paperclip", "paperclip")

    /** iOS mic.fill — voice input affordance is filled on iOS (Cupertino "mic_fill"). */
    val Mic: ImageVector = glyphIcon("floe.mic", "mic_fill")

    /** iOS arrow.up — send (Cupertino "arrow_up"). */
    val ArrowUp: ImageVector = glyphIcon("floe.arrow_up", "arrow_up")

    /** iOS stop.fill — running stop, filled square role (Cupertino "stop_fill"). */
    val StopSquare: ImageVector = glyphIcon("floe.stop", "stop_fill")

    /** cpu — model chip. Hand-drawn fallback (no 2.0.0 cpu glyph). */
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

    /** iOS gauge — reasoning "automatic" (Cupertino "gauge"). */
    val Gauge: ImageVector = glyphIcon("floe.gauge", "gauge")

    /** iOS wand.and.stars — agent mode (Cupertino "wand_stars"). */
    val Wand: ImageVector = glyphIcon("floe.wand", "wand_stars")

    /** list.bullet.clipboard — plan mode. Kept hand-drawn: no 2.0.0 clipboard-bullet
     *  composite; "list_bullet_below_rectangle" reads as rows-under-rectangle (Main review). */
    val PlanList = icon("floe.plan_list") {
        stroke { rrect(5.5f, 4.4f, 18.5f, 20f, 2f) }
        stroke { moveTo(8.5f, 3.6f); lineTo(12.5f, 3.6f) }
        stroke { moveTo(8.5f, 10.5f); lineTo(15.5f, 10.5f) }
        stroke { moveTo(8.5f, 14f); lineTo(15.5f, 14f) }
    }

    /** target — goal mode. Kept hand-drawn: concentric bullseye matches SF target;
     *  the 2.0.0 "scope" crosshair is a different affordance (Main review). */
    val Target = icon("floe.target") {
        stroke { circle(12f, 12f, 7.8f) }
        stroke { circle(12f, 12f, 4.2f) }
        stroke { circle(12f, 12f, 0.4f) }
    }

    /** iOS desktopcomputer — execution target "This device" (Cupertino "desktopcomputer"). */
    val DeviceLocal: ImageVector = glyphIcon("floe.device_local", "desktopcomputer")

    /** iOS checkmark.shield — approval mode chip and permissions (Cupertino "checkmark_shield"). */
    val ShieldCheck: ImageVector = glyphIcon("floe.shield_check", "checkmark_shield")

    /** iOS exclamationmark.shield — pending approval card (Cupertino "exclamationmark_shield"). */
    val ShieldAlert: ImageVector = glyphIcon("floe.shield_alert", "exclamationmark_shield")

    /** stethoscope — diagnostics. Hand-drawn fallback (no 2.0.0 stethoscope glyph). */
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

    /** iOS xmark (Cupertino "xmark"). */
    val Xmark: ImageVector = glyphIcon("floe.xmark", "xmark")

    /** iOS checkmark (Cupertino "checkmark"). */
    val Checkmark: ImageVector = glyphIcon("floe.checkmark", "checkmark")

    /** iOS clock — scheduled section (Cupertino "clock"). */
    val Clock: ImageVector = glyphIcon("floe.clock", "clock")

    /** iOS play.rectangle — runs (Cupertino "play_rectangle"). */
    val PlayRuns: ImageVector = glyphIcon("floe.play_runs", "play_rectangle")

    /** iOS info.circle — honest availability dialogs (Cupertino "info_circle"). */
    val InfoCircle: ImageVector = glyphIcon("floe.info_circle", "info_circle")

    /** terminal — execution environment. Hand-drawn fallback (no 2.0.0 terminal glyph). */
    val Terminal = icon("floe.terminal") {
        stroke { rrect(4.2f, 4.2f, 19.8f, 19.8f, 2.4f) }
        stroke { moveTo(7.5f, 9f); lineTo(11f, 12f); lineTo(7.5f, 15f) }
        stroke { moveTo(13f, 15f); lineTo(16.5f, 15f) }
    }

    /* ---- provider / model configuration glyphs (G02 presentation flow) ---- */

    /** iOS eye — reveal the session-typed secret, never fetches a stored key (Cupertino "eye"). */
    val Eye: ImageVector = glyphIcon("floe.eye", "eye")

    /** iOS eye.slash — hide the revealed field again (Cupertino "eye_slash"). */
    val EyeSlash: ImageVector = glyphIcon("floe.eye_slash", "eye_slash")

    /** iOS chevron.up.chevron.down — chooser affordance (Cupertino "chevron_up_chevron_down"). */
    val ChevronUpDown: ImageVector = glyphIcon("floe.chevron_up_down", "chevron_up_chevron_down")

    /** key — credential state badge. Hand-drawn fallback (no 2.0.0 key glyph). */
    val Key = icon("floe.key") {
        stroke { circle(8f, 8.4f, 3.6f) }
        stroke { moveTo(10.7f, 11.1f); lineTo(19.2f, 19.6f) }
        stroke { moveTo(15.6f, 16f); lineTo(17.8f, 13.8f) }
    }

    /** iOS antenna.radiowaves.left.and.right — providers (Cupertino "antenna_radiowaves_left_right"). */
    val Antenna: ImageVector = glyphIcon("floe.antenna", "antenna_radiowaves_left_right")

    /** iOS arrow.clockwise — explicit refresh (Cupertino "arrow_clockwise"). */
    val Refresh: ImageVector = glyphIcon("floe.refresh", "arrow_clockwise")

    /** iOS exclamationmark.triangle — pending/validation warning (Cupertino "exclamationmark_triangle"). */
    val WarningTriangle: ImageVector = glyphIcon("floe.warning_triangle", "exclamationmark_triangle")

    /** iOS checkmark.circle — verified/connected success, confirmed only (Cupertino "checkmark_circle"). */
    val CheckCircle: ImageVector = glyphIcon("floe.check_circle", "checkmark_circle")

    /** iOS xmark.octagon — failed connection test marker (Cupertino "xmark_octagon"). */
    val XOctagon: ImageVector = glyphIcon("floe.x_octagon", "xmark_octagon")

    /** iOS magnifyingglass — search affordance (Cupertino "search", same glyph). */
    val Magnifier: ImageVector = glyphIcon("floe.magnifier", "search")

    /** iOS plus.circle — stage a candidate model (Cupertino "plus_circled"). */
    val PlusCircle: ImageVector = glyphIcon("floe.plus_circle", "plus_circled")

    /** iOS trash — delete provider, destructive overflow action (Cupertino "trash"). */
    val Trash: ImageVector = glyphIcon("floe.trash", "trash")

    /** iOS pencil — edit provider (Cupertino "pencil"). */
    val Pencil: ImageVector = glyphIcon("floe.pencil", "pencil")

    /** iOS bubble.left.and.bubble.right — chat model service role (Cupertino "bubble_left_bubble_right"). */
    val ChatRole: ImageVector = glyphIcon("floe.chat_role", "bubble_left_bubble_right")

    /** iOS photo.on.rectangle role — image service (Cupertino "photo_on_rectangle"). */
    val ImageRole: ImageVector = glyphIcon("floe.image_role", "photo_on_rectangle")

    /** video.badge.plus — video service role. Kept hand-drawn: the 2.0.0 set has no
     *  video-plus composite and a plain videocam would lose the badge (Main review). */
    val VideoPlus = icon("floe.video_plus") {
        stroke { rrect(3.4f, 5.4f, 20.6f, 18.6f, 2.2f) }
        stroke { circle(8.4f, 12f, 2.6f) }
        stroke { moveTo(13.4f, 12f); lineTo(18f, 12f) }
        stroke { moveTo(15.7f, 9.6f); lineTo(15.7f, 14.4f) }
    }

    /** iOS photo — per-model verified vision badge (Cupertino "photo"). */
    val Photo: ImageVector = glyphIcon("floe.photo", "photo")

    /* ---- settings-category glyphs correcting earlier semantic substitutes ---- */

    /** iOS person.crop.circle.badge.checkmark — Settings "Memories/Personalization"
     *  (was FloeIcons.BookPages, which is the Notes glyph). Cupertino "person_crop_circle_badge_checkmark". */
    val PersonCircleCheck: ImageVector = glyphIcon("floe.person_circle_check", "person_crop_circle_badge_checkmark")

    /** iOS hand.raised — Settings "Privacy" (was FloeIcons.ShieldCheck, which is the
     *  iOS permissions glyph). Cupertino "hand_raised". */
    val HandRaised: ImageVector = glyphIcon("floe.hand_raised", "hand_raised")

    /** iOS chart.bar — Settings "Usage" (was FloeIcons.Gauge, which is the reasoning
     *  "automatic" chip). Cupertino "chart_bar". */
    val ChartBar: ImageVector = glyphIcon("floe.chart_bar", "chart_bar")
}
