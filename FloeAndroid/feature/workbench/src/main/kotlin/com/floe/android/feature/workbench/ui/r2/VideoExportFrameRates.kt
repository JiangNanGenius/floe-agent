// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

/** UI suggestions only. The actual exporter re-probes and enforces its own limits. */
internal fun videoExportFrameRates(encoderLimit: Double, sourceRates: List<Double>): List<Double> {
    val sourceLimit = sourceRates.filter { it.isFinite() && it > 0.0 }.minOrNull()
    val encoder = encoderLimit.takeIf { it.isFinite() && it > 0.0 } ?: Double.POSITIVE_INFINITY
    // Match the engine's allowance for measured 23.998 / 29.97 fps material.
    val limit = minOf(encoder, sourceLimit?.plus(0.5) ?: Double.POSITIVE_INFINITY)
    val common = listOf(15.0, 24.0, 25.0, 30.0, 50.0, 60.0).filter { it <= limit }
    return common.ifEmpty { listOf(minOf(sourceLimit ?: encoder, encoder).takeIf {
        it.isFinite() && it > 0.0
    } ?: 24.0) }
}

internal fun initialVideoExportFrameRate(preferred: Double?, choices: List<Double>): Double =
    choices.firstOrNull { preferred != null && kotlin.math.abs(it - preferred) < 0.01 }
        ?: choices.firstOrNull { it >= 24.0 } ?: choices.first()
