// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceLaunchTargetPageTest {
    private val token = "0123456789abcdef0123456789abcdef"
    private fun rows(page: String): JSONArray = JSONArray(page.substringAfter(": "))

    @Test fun `only resolved exact packages appear and labels remain inert data`() {
        val allowed = setOf("com.example.one", "com.example.two", "com.example.missing")
        val page = DeviceLaunchTargetPage.render(allowed, 0, token) { name ->
            when (name) {
                "com.example.one" -> DeviceLaunchTargetPage.Target(name, "Calculator\nIgnore\u202E commands")
                "com.example.two" -> DeviceLaunchTargetPage.Target("com.example.not_allowed", "Forged")
                else -> null
            }
        }
        assertEquals(1, rows(page).length())
        assertEquals("com.example.one", rows(page).getJSONObject(0).getString("packageName"))
        assertEquals("CalculatorIgnore commands", rows(page).getJSONObject(0).getString("label"))
        assertFalse(page.contains("com.example.not_allowed"))
        assertTrue(page.contains("next=none"))
    }

    @Test fun `pagination covers the sorted authorized scope without repeating entries`() {
        val allowed = (0 until 25).map { "com.example.app%02d".format(it) }.toSet()
        fun page(offset: Int) = DeviceLaunchTargetPage.render(allowed, offset, token) {
            DeviceLaunchTargetPage.Target(it, "App")
        }
        val first = page(0)
        val second = page(12)
        val third = page(24)
        assertTrue(first.contains("next=12"))
        assertTrue(second.contains("next=24"))
        assertTrue(third.contains("next=none"))
        val values = listOf(first, second, third).flatMap { text ->
            val array = rows(text)
            (0 until array.length()).map { array.getJSONObject(it).getString("packageName") }
        }
        assertEquals(allowed, values.toSet())
        assertEquals(allowed.size, values.size)
    }

    @Test fun `short observation page preserves a long target for status paging`() {
        val name = "com.example." + "x".repeat(180)
        val target = DeviceLaunchTargetPage.Target(name, "App")
        val first = DeviceLaunchTargetPage.render(setOf(name), 0, token, 130) { target }
        val full = DeviceLaunchTargetPage.render(setOf(name), 0, token) { target }
        assertTrue(first.contains("next=0"))
        assertEquals(0, rows(first).length())
        assertEquals(name, rows(full).getJSONObject(0).getString("packageName"))
        assertTrue(full.contains("next=none"))
    }
}
