// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.networkartifact

import android.content.Context
import com.floe.android.R

/**
 * Localized presentation for the Wi-Fi coverage limitation bullets.
 *
 * The network core owns the AUTHORITATIVE sentence set (also used verbatim by
 * the tool summary and the JSON/Markdown exports, which stay protocol-facing
 * English). The coverage detail screen rendered those sentences raw, so a
 * Chinese UI showed English restriction copy (G07.3B Samsung QA, 2026-10-31:
 * "coverage limitation sentences still English in Chinese UI").
 *
 * This adapter maps ONLY the core's known user-facing templates to app
 * resources in the current UI language. Unknown text is passed through
 * untouched — no guessed translation of a protocol id or raw error — and the
 * wording keeps every original caveat: user-sampled coverage, strongest
 * access point from a real scan (not a calibrated heatmap), no GPS/RTT/
 * background/synthetic data, cached-scan age, and the real counts.
 */
object CoverageLimitationCopy {

    /** One known template and its bounded integer arguments. */
    data class Matched(
        val resourceId: Int,
        val args: List<Int> = emptyList(),
    )

    private val stale = Regex("""^(\d+) points are older than 10 minutes\.$""")
    private val cached = Regex("""^(\d+) points use a cached scan; its age is shown\.$""")
    private val permission = Regex("""^(\d+) samples lack Wi-Fi scan permission/location services\.$""")
    private val noSignal = Regex("""^(\d+) samples returned no access point\.$""")
    private val unsampled = Regex("""^(\d+) grid cells have no sample\.$""")

    /** Pure template match; null means "leave the original text as-is". */
    fun match(raw: String): Matched? {
        val text = raw.trim()
        return when (text) {
            "Coverage is user-sampled at explicit points; it is not a continuous RF survey." ->
                Matched(R.string.coverage_limitation_sampled)
            "Signal level is the strongest access point seen by a real scan; it is not a calibrated heatmap." ->
                Matched(R.string.coverage_limitation_strongest)
            "No GPS, RTT ranging, background scanning or synthetic access points are used." ->
                Matched(R.string.coverage_limitation_no_telemetry)
            "No floorplan is attached; the grid view is shown." ->
                Matched(R.string.coverage_limitation_no_floorplan)
            else -> countMatch(stale, R.string.coverage_limitation_stale, text)
                ?: countMatch(cached, R.string.coverage_limitation_cached, text)
                ?: countMatch(permission, R.string.coverage_limitation_permission, text)
                ?: countMatch(noSignal, R.string.coverage_limitation_no_signal, text)
                ?: countMatch(unsampled, R.string.coverage_limitation_unsampled, text)
        }
    }

    /** UI-language text for [raw]; unknown text is returned unchanged. */
    fun localize(context: Context, raw: String): String {
        val matched = match(raw) ?: return raw
        return context.getString(matched.resourceId, *matched.args.toTypedArray())
    }

    private fun countMatch(regex: Regex, resourceId: Int, text: String): Matched? =
        regex.matchEntire(text)?.groupValues?.getOrNull(1)?.toIntOrNull()?.let {
            Matched(resourceId, listOf(it))
        }
}
