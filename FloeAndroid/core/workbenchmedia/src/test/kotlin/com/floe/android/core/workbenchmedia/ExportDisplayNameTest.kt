// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia
import com.floe.android.core.workbenchmedia.export.exportDisplayName
import org.junit.Assert.*
import org.junit.Test
class ExportDisplayNameTest {
 @Test fun unicodeNameAndExistingExtensionArePreserved() {
  assertEquals("我的影片.mp4", exportDisplayName("我的影片", "mp4"))
  assertEquals("Movie.mp4", exportDisplayName("Movie.MP4", "mp4"))
 }
 @Test fun pathLikeAndBlankHintsNeverBecomePaths() {
  assertEquals("bad_name.mp4", exportDisplayName("../../bad?name", "mp4"))
  assertEquals("Export.png", exportDisplayName("...", "png"))
 }
 @Test fun longUnicodeHintsStayWithinAFileComponent() {
  val value = exportDisplayName("图".repeat(300), "mp4")
  assertTrue(value.toByteArray(Charsets.UTF_8).size <= 255)
  assertTrue(value.endsWith(".mp4"))
 }
}
