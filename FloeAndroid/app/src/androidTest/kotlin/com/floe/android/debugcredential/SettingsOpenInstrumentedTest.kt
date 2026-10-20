// SPDX-License-Identifier: MPL-2.0
//
// Real open-Settings / Providers anti-crash check (MAIN P0 2026-10-20).
//
// Drives the REAL product MainActivity through the accessibility tree: finds
// the Settings affordance by its text/content description (never a guessed
// coordinate), clicks its ACTUAL bounds centre, then asserts the Settings
// categories and the Providers pane actually appear — a nested-scroll measure
// crash or a blank pane fails the test. No extra dependencies: plain
// UiAutomation + AccessibilityNodeInfo + real input injection.
package com.floe.android.debugcredential

import android.app.Activity
import android.app.Instrumentation
import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.floe.android.MainActivity
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SettingsOpenInstrumentedTest {

    @Test
    fun openSettingsAndProvidersWithoutCrash() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val intent = android.content.Intent(context, MainActivity::class.java)
            .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        val activity: Activity? = instrumentation.startActivitySync(intent)
        assertNotNull("MainActivity did not start", activity)
        SystemClock.sleep(3_000)

        val settingsNode = awaitNode(instrumentation, 25_000) {
            matches(it, listOf("Settings", "设置", "settings"))
        }
        assertNotNull("Settings affordance not found in the real UI tree", settingsNode)
        clickNode(instrumentation, settingsNode!!)
        SystemClock.sleep(2_500)

        // The Settings sheet really composed: its categories are present.
        val general = awaitNode(instrumentation, 15_000) {
            matches(it, listOf("General", "通用"))
        }
        val providers = findNode(instrumentation) {
            matches(it, listOf("Providers", "提供商", "Model & Provider", "模型与提供商"))
        }
        assertTrue("Settings general category did not render", general != null)
        assertNotNull("Providers category not found", providers)
        clickNode(instrumentation, providers!!)
        SystemClock.sleep(2_500)

        // The Providers pane really rendered its content (the cloud model
        // section or the Add-provider affordance), not an empty/blocked page.
        val providersContent = awaitNode(instrumentation, 15_000) {
            matches(it, listOf("Cloud Model", "云端模型", "Add Provider", "添加提供商",
                "Cloud Models", "云端模型服务"))
        }
        assertNotNull("Providers pane content did not render", providersContent)
        assertFalse("MainActivity died after opening Settings/Providers",
            activity!!.isFinishing || activity.isDestroyed)
    }

    private fun matches(node: AccessibilityNodeInfo, labels: List<String>): Boolean {
        val text = node.text?.toString()
        val desc = node.contentDescription?.toString()
        return labels.any { label ->
            text?.contains(label, ignoreCase = true) == true ||
                desc?.contains(label, ignoreCase = true) == true
        }
    }

    private fun findNode(instrumentation: Instrumentation,
                         predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        val root = instrumentation.uiAutomation.rootInActiveWindow ?: return null
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)
        var visited = 0
        while (queue.isNotEmpty() && visited < 4_000) {
            val node = queue.removeFirst()
            visited += 1
            if (predicate(node)) return node
            for (index in 0 until node.childCount) {
                node.getChild(index)?.let { queue.add(it) }
            }
        }
        return null
    }

    private fun awaitNode(instrumentation: Instrumentation, timeoutMillis: Long,
                          predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        val deadline = SystemClock.uptimeMillis() + timeoutMillis
        while (SystemClock.uptimeMillis() < deadline) {
            findNode(instrumentation, predicate)?.let { return it }
            SystemClock.sleep(250)
        }
        return null
    }

    private fun clickNode(instrumentation: Instrumentation, node: AccessibilityNodeInfo) {
        val bounds = Rect()
        node.getBoundsInScreen(bounds)
        val x = bounds.exactCenterX()
        val y = bounds.exactCenterY()
        android.util.Log.i("FloeSettingsCheck",
            "click '${node.text ?: node.contentDescription}' bounds=$bounds")
        val down = SystemClock.uptimeMillis()
        val downEvent = MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN, x, y, 0)
        downEvent.source = InputDevice.SOURCE_TOUCHSCREEN
        instrumentation.uiAutomation.injectInputEvent(downEvent, true)
        downEvent.recycle()
        val upEvent = MotionEvent.obtain(down, down + 40, MotionEvent.ACTION_UP, x, y, 0)
        upEvent.source = InputDevice.SOURCE_TOUCHSCREEN
        instrumentation.uiAutomation.injectInputEvent(upEvent, true)
        upEvent.recycle()
    }
}
