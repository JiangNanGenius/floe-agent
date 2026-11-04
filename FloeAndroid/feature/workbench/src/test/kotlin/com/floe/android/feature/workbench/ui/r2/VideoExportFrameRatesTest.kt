// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2
import org.junit.Assert.*
import org.junit.Test
class VideoExportFrameRatesTest {
 @Test fun measuredFractional24DoesNotOffer30OrDefaultTo15() {
  val choices = videoExportFrameRates(60.0, listOf(23.998020781791194))
  assertEquals(listOf(15.0, 24.0), choices)
  assertEquals(24.0, initialVideoExportFrameRate(30.0, choices), 0.0001)
 }
 @Test fun mixedSourcesUseSlowestRate() {
  assertEquals(listOf(15.0, 24.0), videoExportFrameRates(60.0, listOf(60.0, 24.0)))
 }
 @Test fun existingSupportedPreferenceIsRetained() {
  val choices = videoExportFrameRates(60.0, listOf(60.0))
  assertEquals(30.0, initialVideoExportFrameRate(30.0, choices), 0.0001)
 }
 @Test fun encoderLimitStillApplies() {
  assertEquals(listOf(15.0, 24.0, 25.0, 30.0), videoExportFrameRates(30.0, listOf(60.0)))
 }
 @Test fun lowRateSourcesKeepTheirMeasuredRate() {
  assertEquals(listOf(12.0), videoExportFrameRates(60.0, listOf(12.0)))
 }
 @Test fun invalidMeasurementsDoNotCreateInvalidChoices() {
  val choices = videoExportFrameRates(Double.NaN, listOf(Double.NaN, -1.0, 0.0))
  assertTrue(choices.isNotEmpty()); assertTrue(choices.all { it.isFinite() && it > 0.0 })
 }
}
