// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaEditCommandTest {
    @Test
    fun `update layer distinguishes unchanged clear and set crop`() {
        val unchanged = MediaEditCommand.UpdateLayer(id = "layer")
        val clear = MediaEditCommand.UpdateLayer(
            id = "layer", crop = OptionalUpdate.Clear)
        val set = MediaEditCommand.UpdateLayer(
            id = "layer", crop = OptionalUpdate.Set(NormalizedRect.UNIT))
        assertTrue(unchanged.crop is OptionalUpdate.Unchanged)
        assertTrue(clear.crop is OptionalUpdate.Clear)
        assertEquals(NormalizedRect.UNIT, (set.crop as OptionalUpdate.Set).value)
    }

    @Test
    fun `r1 layer command carries typed text content`() {
        val layer = ImageLayer(
            id = "layer-1",
            kind = "text",
            name = "Title",
            text = ImageTextContent(text = "Hello"))
        val command = MediaEditCommand.AddImageLayer(layer)
        assertEquals("text", command.layer.kind)
        assertEquals("Hello", command.layer.text?.text)
    }
}
