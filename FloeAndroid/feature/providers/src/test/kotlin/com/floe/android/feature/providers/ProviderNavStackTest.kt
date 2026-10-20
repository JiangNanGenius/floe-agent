// SPDX-License-Identifier: MPL-2.0
//
// Synthetic unit tests for the innermost-first back stack and its base
// delegation (Back closes model/catalog/menu → editor; at the base the host's
// settings sheet keeps back).

package com.floe.android.feature.providers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderNavStackTest {

    @Test
    fun baseNeverConsumesBack() {
        val stack = ProviderNavStack()
        assertEquals(ProviderPane.LIST, stack.top.pane)
        assertFalse(stack.back())
        assertEquals(1, stack.depth)
    }

    @Test
    fun panesCloseInnermostFirst() {
        val stack = ProviderNavStack()
        stack.push(ProviderPane.ROLE_CHOOSER, "chooser")
        stack.push(ProviderPane.EDITOR, "editor-1")
        stack.push(ProviderPane.SUPPLIER_CHOOSER, "editor-1")

        assertEquals(ProviderPane.SUPPLIER_CHOOSER, stack.top.pane)
        assertTrue(stack.back())
        assertEquals(ProviderPane.EDITOR, stack.top.pane)
        assertTrue(stack.back())
        assertEquals(ProviderPane.ROLE_CHOOSER, stack.top.pane)
        assertTrue(stack.back())
        assertEquals(ProviderPane.LIST, stack.top.pane)
        assertFalse(stack.back())
    }

    @Test
    fun nestedModelPanesStackAboveTheirEditor() {
        val stack = ProviderNavStack()
        stack.push(ProviderPane.EDITOR, "editor-1")
        stack.push(ProviderPane.MODEL_MANAGER, "editor-1")
        stack.push(ProviderPane.MODEL_EDITOR, "staged-1")

        assertEquals(ProviderPane.MODEL_EDITOR, stack.top.pane)
        assertTrue(stack.back())
        assertEquals(ProviderPane.MODEL_MANAGER, stack.top.pane)
        assertTrue(stack.back())
        assertEquals(ProviderPane.EDITOR, stack.top.pane)
    }

    @Test
    fun duplicatePushIsIgnored() {
        val stack = ProviderNavStack()
        stack.push(ProviderPane.EDITOR, "editor-1")
        stack.push(ProviderPane.EDITOR, "editor-1")
        assertEquals(2, stack.depth)
    }

    @Test
    fun closeTopIfOnlyMatchesTheTop() {
        val stack = ProviderNavStack()
        stack.push(ProviderPane.EDITOR, "editor-1")
        stack.push(ProviderPane.MODEL_MANAGER, "editor-1")

        assertFalse(stack.closeTopIf(ProviderPane.EDITOR, "editor-1"))
        assertTrue(stack.closeTopIf(ProviderPane.MODEL_MANAGER, "editor-1"))
        assertTrue(stack.closeTopIf(ProviderPane.EDITOR, "editor-1"))
    }

    @Test
    fun resetToBaseClearsEverythingAboveList() {
        val stack = ProviderNavStack()
        stack.push(ProviderPane.EDITOR, "editor-1")
        stack.push(ProviderPane.MODEL_MANAGER, "editor-1")

        stack.resetToBase()

        assertEquals(1, stack.depth)
        assertEquals(ProviderPane.LIST, stack.top.pane)
    }
}
