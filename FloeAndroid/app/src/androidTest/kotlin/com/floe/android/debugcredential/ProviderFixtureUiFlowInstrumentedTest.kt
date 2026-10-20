// SPDX-License-Identifier: MPL-2.0
//
// REAL first-provider UI flow for the G02 ordinary App (Main acceptance
// refinement 2026-10-20): drive the ACTUAL provider editor through the
// accessibility tree, save ONE clearly synthetic provider + ONE manual model
// with a placeholder key, and assert the provider list shows it.
//
// Fixture (authorized synthetic):
//   name     = "Floe G02 QA"
//   endpoint = https://example.invalid/v1
//   modelID  = deepseek-flash
//   key      = floe-g02-synthetic-placeholder   (never a real credential)
//
// No network request is made by this test: the endpoint is `.invalid` and the
// save path only writes the local credential vault + provider row. The later
// `providersExport` phase reads the real metadata (never the secret value).
package com.floe.android.debugcredential

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.floe.android.MainActivity
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.contentOrNull
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ProviderFixtureUiFlowInstrumentedTest {

    private val fixtureName = "Floe G02 QA"
    private val fixtureEndpoint = "https://example.invalid/v1"
    private val fixtureModelID = "deepseek-flash"
    private val fixtureKey = "floe-g02-synthetic-placeholder"

    private var activityRef: Activity? = null

    private fun arg(name: String): String? =
        InstrumentationRegistry.getArguments().getString(name)

    @Test
    fun createSyntheticProviderThroughTheRealEditor() {
        // Phase-gated exactly like the enrollment harness: a normal
        // CanonicalWire/Settings run must not execute this long UI flow.
        assumeTrue(arg("floeProviderFixturePhase") == "create")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val activity: Activity? = instrumentation.startActivitySync(intent)
        assertNotNull("MainActivity did not start", activity)
        activityRef = activity
        SystemClock.sleep(3_000)

        openProvidersPane(instrumentation)

        // Add Provider -> purpose chooser -> Chat model provider.
        val addProvider = awaitNode(instrumentation, 20_000) {
            matches(it, listOf("Add Provider", "添加提供商"))
        }
        assertNotNull("Add Provider affordance missing:\n${dump(instrumentation)}", addProvider)
        clickNode(instrumentation, addProvider!!)
        SystemClock.sleep(1_500)
        val chatModel = awaitNode(instrumentation, 15_000) {
            matches(it, listOf("Chat model provider", "聊天模型提供商"))
        }
        assertNotNull("Chat-model purpose option missing:\n${dump(instrumentation)}", chatModel)
        clickNode(instrumentation, chatModel!!)
        SystemClock.sleep(2_000)

        // THE regression assert: the editor must leave the host-pending state.
        val nameField = awaitNode(instrumentation, 20_000) {
            matchesExact(it, listOf("Name", "名称"))
        }
        assertNotNull("editor Name field never appeared:\n${dump(instrumentation)}", nameField)
        val stillLoading = findNode(instrumentation) {
            matches(it, listOf("Loading configuration", "正在加载配置"))
        }
        assertTrue("provider editor stayed on the host-pending placeholder",
            stillLoading == null)

        // Provider chooser -> custom compatible endpoint.
        val providerRow = awaitNode(instrumentation, 10_000) {
            matches(it, listOf("Provider: ", "提供商"))
        }
        assertNotNull("Provider chooser row missing:\n${dump(instrumentation)}", providerRow)
        clickNode(instrumentation, providerRow!!)
        SystemClock.sleep(1_500)
        val custom = awaitNode(instrumentation, 15_000) {
            matches(it, listOf("Custom endpoint", "自定义端点"))
        }
        assertNotNull("custom-endpoint preset missing from the chooser:\n${dump(instrumentation)}",
            custom)
        clickNode(instrumentation, custom!!)
        SystemClock.sleep(1_500)

        // Name + endpoint + placeholder key.
        requireField(instrumentation, listOf("Name", "名称"), fixtureName, "name")
        requireField(instrumentation, listOf("Base URL", "基础 URL", "端点"),
            fixtureEndpoint, "base URL")
        requireField(instrumentation, listOf("API key", "API 密钥", "API Key"),
            fixtureKey, "API key")

        // One manual model: Manage Models -> Add Model -> Manual entry.
        val manageModels = ensureVisible(instrumentation,
            listOf("Manage Models", "管理模型"))
        assertNotNull("Manage Models row missing:\n${dump(instrumentation)}", manageModels)
        clickNode(instrumentation, manageModels!!)
        SystemClock.sleep(1_500)
        val addModel = awaitNode(instrumentation, 15_000) {
            matchesExact(it, listOf("Add Model", "添加模型"))
        }
        assertNotNull("Add Model affordance missing:\n${dump(instrumentation)}", addModel)
        clickNode(instrumentation, addModel!!)
        SystemClock.sleep(1_500)
        val manual = findNode(instrumentation) {
            matchesExact(it, listOf("Manual entry", "手动输入", "Manual Entry"))
        }
        if (manual != null) {
            clickNode(instrumentation, manual)
            SystemClock.sleep(1_500)
        }
        // Model identifier + display name fields (labels come from the model
        // editor; the first editable field receives the wire model id).
        val modelIDLabels = listOf("Model ID", "Remote model ID", "模型 ID",
            "Model identifier", "Model name")
        requireField(instrumentation, modelIDLabels, fixtureModelID, "model identifier")
        clickSave(instrumentation, listOf("Add Model", "添加模型", "Save", "保存", "Done", "完成"))

        // Back to the provider editor, then Save the provider.
        SystemClock.sleep(1_500)
        clickBackIfPresent(instrumentation)
        val didSave = clickSaveScrolled(instrumentation, listOf("Save", "保存"))
        assertTrue("provider Save affordance missing:\n${dump(instrumentation)}", didSave)

        // The real save must land: the list shows the fixture row.
        val saved = awaitNode(instrumentation, 30_000) {
            matches(it, listOf(fixtureName))
        }
        assertNotNull("saved provider row never appeared:\n${dump(instrumentation)}", saved)

        // Persist the exact evidence text for the handoff record.
        val evidence = java.io.File(context.filesDir, "floe-provider-fixture-ui.txt")
        evidence.writeText(
            "name=$fixtureName\nendpoint=$fixtureEndpoint\nmodel=$fixtureModelID\n" +
                "savedRowVisible=true\n")
        android.util.Log.i("FloeProviderFixture",
            "FLOE_PROVIDER_FIXTURE_UI ok name=$fixtureName file=${evidence.absolutePath}")
    }

    /**
     * SYNTHETIC producer probe (no credential, no network): submits the EXACT
     * closed candidate the App builds for the fixture draft through the real
     * command client and reports the precise failed-effect payload
     * (value.errorCode/reason + detail.wire), because the binder settles every
     * router error as the generic `ordinaryRuntimeBlocked`. If the candidate
     * is accepted it commits a KEYLESS provider row, reads the list back and
     * deletes it again through the real guarded delete — leaving no residue.
     */
    @Test
    fun probeProviderSaveCandidate() {
        assumeTrue(arg("floeProviderFixturePhase") == "candidateProbe")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        // Wait for the REAL accepted generation first (same discipline as the
        // export harness): submitting before bootstrap admits is refused by
        // the binder and is NOT a domain outcome.
        val epoch = awaitAcceptedEpoch()
        android.util.Log.i("FloeProviderFixture", "FLOE_PROVIDER_CANDIDATE_PROBE epoch=$epoch")
        val client = com.floe.android.host.RuntimeHostCommandClient.system()
        val providerID = java.util.UUID.randomUUID().toString()
        val modelID = java.util.UUID.randomUUID().toString()
        val draft = com.floe.android.feature.providers.ProviderDraftSnapshot(
            role = com.floe.android.feature.providers.ProviderServiceRoleUi.CONVERSATION,
            displayName = "Floe G02 QA",
            supplier = com.floe.android.feature.providers.SupplierChoice(
                presetId = "custom",
                displayName = "Custom endpoint",
                catalogEntryId = null,
                absoluteEndpointDefault = "",
                routeFamily = "",
                authStyle = "",
                supportsPlainHttpChoice = false,
                suggestsToolNameCompatibility = false,
            ),
            protocol = com.floe.android.feature.providers.WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
            baseUrl = "https://example.invalid/v1",
            models = listOf(com.floe.android.feature.providers.ModelDraftRowUi(
                draftModelId = "manual-1",
                savedModelId = null,
                remoteModelID = "deepseek-flash",
                displayName = "DeepSeek Flash",
                enabled = true,
                capabilities = setOf(
                    com.floe.android.feature.providers.ModelCapabilityUi.TEXT,
                    com.floe.android.feature.providers.ModelCapabilityUi.TOOLS),
                contextTokens = 128_000,
                maxOutputTokens = 8_192,
                selectedForSave = true,
            )),
            defaultModelDraftId = "manual-1",
        )
        val candidate = com.floe.android.host.ProviderWire.candidateJson(
            providerID = providerID,
            kind = "custom",
            createIntent = true,
            draft = draft,
            modelUUID = { modelID },
        )
        val correlation = "candidate-probe-${System.nanoTime()}"
        val request = com.floe.android.host.HostCommandRequest(
            command = "config.provider.save",
            scope = com.floe.android.host.HostScope.ApplicationConfiguration("providers"),
            stateful = true,
            correlationID = correlation,
            createIntent = true,
            payload = kotlinx.serialization.json.JsonObject(mapOf(
                "secretIntent" to kotlinx.serialization.json.JsonPrimitive("clear"),
                "candidate" to candidate,
            )),
        )
        val evidence = StringBuilder()
        evidence.append("CANDIDATE\n").append(candidate).append('\n')
        val outcome = runBlocking {
            kotlinx.coroutines.withTimeout(25_000) {
                val submitted = client.submit(request)
                if (submitted !is com.floe.android.host.HostSubmitResult.Accepted) {
                    return@withTimeout submitted.toString() to null
                }
                val done = java.util.concurrent.CountDownLatch(1)
                var terminal: com.floe.android.host.HostEffectTerminal? = null
                var failure: com.floe.android.host.HostPumpFailure? = null
                val handle = client.openEffectStream(
                    operationReceiptID = submitted.operationReceiptID,
                    configurationScope = "providers",
                    onFrame = { },
                    onTerminal = { terminal = it; done.countDown() },
                    onFailure = { failure = it; done.countDown() },
                )
                try {
                    check(done.await(20, java.util.concurrent.TimeUnit.SECONDS)) {
                        "candidate_probe_timeout"
                    }
                } finally {
                    handle.close()
                }
                check(failure == null) { "candidate_probe_pump_failed: $failure" }
                submitted.toString() to terminal
            }
        }
        val submit = outcome.first
        val terminal = outcome.second
        evidence.append("SUBMIT\n").append(submit).append('\n')
        evidence.append("TERMINAL\n").append(terminal).append('\n')
        if (terminal is com.floe.android.host.HostEffectTerminal.Completed) {
            val value = terminal.value as? kotlinx.serialization.json.JsonObject
            val createdID = (value?.get("providerID")
                as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull
            val revision = value?.get("revision") as? kotlinx.serialization.json.JsonObject
            val resourceID = (revision?.get("resourceID")
                as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull
            val version = (revision?.get("version")
                as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull
            evidence.append("COMMITTED providerID=$createdID revision=$resourceID@$version\n")
            // Real read-back through the same binder contract.
            val listCorrelation = "candidate-probe-list-${System.nanoTime()}"
            val listed = runBlocking {
                kotlinx.coroutines.withTimeout(25_000) {
                    val submitted = client.submit(com.floe.android.host.HostCommandRequest(
                        command = "config.providers.list",
                        scope = com.floe.android.host.HostScope.ApplicationConfiguration("providers"),
                        stateful = false,
                        correlationID = listCorrelation,
                        payload = kotlinx.serialization.json.JsonObject(mapOf(
                            "operation" to kotlinx.serialization.json.JsonPrimitive("snapshot"))),
                    ))
                    if (submitted !is com.floe.android.host.HostSubmitResult.Accepted) {
                        return@withTimeout submitted.toString() to null
                    }
                    val done = java.util.concurrent.CountDownLatch(1)
                    var terminal2: com.floe.android.host.HostEffectTerminal? = null
                    val handle = client.openEffectStream(
                        operationReceiptID = submitted.operationReceiptID,
                        configurationScope = "providers",
                        onFrame = { },
                        onTerminal = { terminal2 = it; done.countDown() },
                        onFailure = { done.countDown() },
                    )
                    try {
                        check(done.await(20, java.util.concurrent.TimeUnit.SECONDS)) {
                            "candidate_probe_list_timeout"
                        }
                    } finally {
                        handle.close()
                    }
                    submitted.toString() to terminal2
                }
            }
            evidence.append("LIST\n").append(listed.second).append('\n')
            // Clean up through the REAL guarded delete (current revision).
            if (createdID != null && resourceID != null && version != null) {
                val rid: String = resourceID
                val ver: String = version
                val delete = runBlocking {
                    kotlinx.coroutines.withTimeout(25_000) {
                        val submitted = client.submit(com.floe.android.host.HostCommandRequest(
                            command = "config.provider.delete",
                            scope = com.floe.android.host.HostScope.ApplicationConfiguration("providers"),
                            stateful = true,
                            correlationID = "candidate-probe-del-${System.nanoTime()}",
                            revision = com.floe.android.host.HostRevision(rid, ver),
                        ))
                        if (submitted !is com.floe.android.host.HostSubmitResult.Accepted) {
                            return@withTimeout submitted.toString() to null
                        }
                        val done = java.util.concurrent.CountDownLatch(1)
                        var terminal3: com.floe.android.host.HostEffectTerminal? = null
                        val handle = client.openEffectStream(
                            operationReceiptID = submitted.operationReceiptID,
                            configurationScope = "providers",
                            onFrame = { },
                            onTerminal = { terminal3 = it; done.countDown() },
                            onFailure = { done.countDown() },
                        )
                        try {
                            check(done.await(20, java.util.concurrent.TimeUnit.SECONDS)) {
                                "candidate_probe_delete_timeout"
                            }
                        } finally {
                            handle.close()
                        }
                        submitted.toString() to terminal3
                    }
                }
                evidence.append("DELETE\n").append(delete.second).append('\n')
            }
        }
        val out = java.io.File(context.filesDir, "floe-provider-candidate-probe.txt")
        out.writeText(evidence.toString())
        android.util.Log.i("FloeProviderFixture",
            "FLOE_PROVIDER_CANDIDATE_PROBE file=${out.absolutePath}")
        if (terminal is com.floe.android.host.HostEffectTerminal.Failed) {
            // The binder settles every router error as the generic
            // ordinaryRuntimeBlocked; the PRECISE code travels in
            // detail["wire"] and the reason in `reason`.
            android.util.Log.i("FloeProviderFixture",
                "FLOE_PROVIDER_CANDIDATE_PROBE failed code=${terminal.code} " +
                    "reason=${terminal.reason} detail=${terminal.detail}")
        }
        if (terminal is com.floe.android.host.HostEffectTerminal.Completed) {
            android.util.Log.i("FloeProviderFixture",
                "FLOE_PROVIDER_CANDIDATE_PROBE completed value=${terminal.value}")
        }
        assertNotNull("candidate probe produced no typed terminal", terminal)
    }

    // ---------------------------------------------------------------- helpers

    private fun awaitAcceptedEpoch(): Long {
        val deadline = System.currentTimeMillis() + 30_000
        while (System.currentTimeMillis() < deadline) {
            val raw = runCatching {
                com.floe.android.bridge.RuntimeCoreNative.g02DomainReadiness()
            }.getOrNull()
            if (raw != null) {
                val root = kotlinx.serialization.json.Json
                    .parseToJsonElement(raw) as? kotlinx.serialization.json.JsonObject
                    ?: continue
                fun long(key: String): Long =
                    (root[key] as? kotlinx.serialization.json.JsonPrimitive)
                        ?.content?.toLongOrNull() ?: 0L
                val epoch = long("epoch")
                if (epoch > 0 && long("nativeRootEpoch") == epoch) return epoch
            }
            Thread.sleep(250)
        }
        throw AssertionError("accepted runtime generation not observed")
    }

    private fun openProvidersPane(instrumentation: Instrumentation) {
        val settings = awaitNode(instrumentation, 20_000) {
            matches(it, listOf("Settings", "设置"))
        }
        assertNotNull("Settings affordance not found:\n${dump(instrumentation)}", settings)
        clickNode(instrumentation, settings!!)
        SystemClock.sleep(2_000)
        val providers = awaitNode(instrumentation, 15_000) {
            matches(it, listOf("Model & Provider", "模型与提供商", "Providers", "提供商"))
        }
        assertNotNull("Providers category not found:\n${dump(instrumentation)}", providers)
        clickNode(instrumentation, providers!!)
        SystemClock.sleep(2_000)
        awaitNode(instrumentation, 15_000) {
            matches(it, listOf("Add Provider", "添加提供商", "Add a model provider"))
        }
    }

    /**
     * Sets ONE text field and VERIFIES the real value readback. A missing
     * field, a failed scroll or an unverified write FAILS the flow — nothing
     * is silently skipped (Main 2026-10-20 review of run 1/2).
     */
    private fun typeInto(instrumentation: Instrumentation, labels: List<String>, text: String): Boolean {
        val field = ensureVisible(instrumentation, labels)
        if (field == null) {
            android.util.Log.w("FloeProviderFixture",
                "field ${labels.first()} missing after checked scrolling:\n${dump(instrumentation)}")
            return false
        }
        clickNode(instrumentation, field)
        SystemClock.sleep(500)
        // Replace any prefilled value (select-all + delete) before typing.
        sendKey(instrumentation, android.view.KeyEvent.KEYCODE_A,
            android.view.KeyEvent.META_CTRL_ON or android.view.KeyEvent.META_CTRL_LEFT_ON)
        SystemClock.sleep(120)
        sendKey(instrumentation, android.view.KeyEvent.KEYCODE_DEL, 0)
        SystemClock.sleep(150)
        instrumentation.sendStringSync(text)
        SystemClock.sleep(500)
        dismissIme(instrumentation)
        SystemClock.sleep(300)
        // VERIFIED readback from the live tree: the field must now carry the
        // exact text. A write that the UI never received is a hard failure.
        val verified = findNode(instrumentation) { node ->
            val value = node.text?.toString()
            val desc = node.contentDescription?.toString()
            value == text || desc == text ||
                value?.contains(text, ignoreCase = false) == true
        } != null
        if (!verified) {
            android.util.Log.w("FloeProviderFixture",
                "field ${labels.first()} did not read back '$text':\n${dump(instrumentation)}")
        }
        return verified
    }

    private fun requireField(instrumentation: Instrumentation, labels: List<String>,
                             text: String, what: String) {
        assertTrue("could not set+verify the $what field:\n${dump(instrumentation)}",
            typeInto(instrumentation, labels, text))
    }

    /** Standard IME dismissal through the real window (never a BACK press,
     *  which would navigate away from the retained editor). */
    private fun dismissIme(instrumentation: Instrumentation) {
        val activity = currentActivity(instrumentation) ?: return
        val imm = activity.getSystemService(android.view.inputmethod.InputMethodManager::class.java)
        val token = activity.window?.decorView?.windowToken ?: return
        imm?.hideSoftInputFromWindow(token, 0)
    }

    private fun currentActivity(instrumentation: Instrumentation): Activity? {
        // The test started MainActivity itself; the top resumed activity is
        // the editor's host window owner.
        return activityRef
    }

    private fun sendKey(instrumentation: Instrumentation, keyCode: Int, meta: Int) {
        val now = SystemClock.uptimeMillis()
        val down = android.view.KeyEvent(now, now, android.view.KeyEvent.ACTION_DOWN, keyCode,
            0, meta, -1, 0, 0, InputDevice.SOURCE_KEYBOARD)
        val up = android.view.KeyEvent(now, now + 30, android.view.KeyEvent.ACTION_UP, keyCode,
            0, meta, -1, 0, android.view.KeyEvent.FLAG_SOFT_KEYBOARD,
            InputDevice.SOURCE_KEYBOARD)
        instrumentation.sendKeySync(down)
        instrumentation.sendKeySync(up)
    }

    /**
     * Finds a node that is COMPOSED and visible. Scrolling is CHECKED and
     * tree-bounded: the scrollable node's own bounds are used, we first walk
     * to the TOP, then step DOWN in small real swipes, re-reading the tree
     * after every step. No display-metrics guess and no unchecked
     * ACTION_SCROLL_FORWARD result is treated as success.
     */
    private fun ensureVisible(instrumentation: Instrumentation,
                              labels: List<String>, attempts: Int = 18): AccessibilityNodeInfo? {
        findNode(instrumentation) { matches(it, labels) }?.takeIf { it.isVisibleToUser }?.let { return it }
        // Top first so a full traversal is guaranteed from one known edge.
        repeat(8) {
            val scrollable = scrollableNode(instrumentation) ?: return@repeat
            val moved = scrollable.performAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
            SystemClock.sleep(300)
            if (!moved) return@repeat
            findNode(instrumentation) { matches(it, labels) }?.takeIf { it.isVisibleToUser }
                ?.let { return it }
        }
        repeat(attempts) {
            val scrollable = scrollableNode(instrumentation)
            if (scrollable == null) {
                return null
            }
            val bounds = Rect()
            scrollable.getBoundsInScreen(bounds)
            if (bounds.height() <= 0) return null
            // ONE small step: 30% of the real scrollable height, inside its
            // actual on-screen bounds.
            swipeUp(instrumentation, bounds)
            SystemClock.sleep(350)
            findNode(instrumentation) { matches(it, labels) }?.takeIf { it.isVisibleToUser }
                ?.let { return it }
        }
        return findNode(instrumentation) { matches(it, labels) }?.takeIf { it.isVisibleToUser }
    }

    private fun scrollableNode(instrumentation: Instrumentation): AccessibilityNodeInfo? =
        findNode(instrumentation) { it.isScrollable && it.isVisibleToUser }

    private fun swipeUp(instrumentation: Instrumentation, bounds: Rect) {
        val x = bounds.exactCenterX()
        val startY = bounds.top + bounds.height() * 0.72f
        val endY = bounds.top + bounds.height() * 0.42f
        val down = SystemClock.uptimeMillis()
        val downEvent = MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN, x, startY, 0)
        downEvent.source = InputDevice.SOURCE_TOUCHSCREEN
        instrumentation.uiAutomation.injectInputEvent(downEvent, true)
        var step = 1
        val steps = 6
        while (step <= steps) {
            val t = down + (35L * step)
            val y = startY + (endY - startY) * step / steps
            val move = MotionEvent.obtain(down, t, MotionEvent.ACTION_MOVE, x, y, 0)
            move.source = InputDevice.SOURCE_TOUCHSCREEN
            instrumentation.uiAutomation.injectInputEvent(move, true)
            move.recycle()
            step += 1
        }
        val up = MotionEvent.obtain(down, down + 300, MotionEvent.ACTION_UP, x, endY, 0)
        up.source = InputDevice.SOURCE_TOUCHSCREEN
        instrumentation.uiAutomation.injectInputEvent(up, true)
        downEvent.recycle()
        up.recycle()
    }

    private fun clickSave(instrumentation: Instrumentation, labels: List<String>): Boolean {
        val save = findNode(instrumentation) { matchesExact(it, labels) }
        if (save == null) return false
        clickNode(instrumentation, save)
        return true
    }

    private fun clickSaveScrolled(instrumentation: Instrumentation,
                                  labels: List<String>): Boolean {
        val save = ensureVisible(instrumentation, labels) ?: return false
        clickNode(instrumentation, save)
        return true
    }

    private fun clickBackIfPresent(instrumentation: Instrumentation) {
        val back = findNode(instrumentation) {
            matchesExact(it, listOf("Back", "返回", "Done", "完成", "Close", "关闭"))
        }
        if (back != null) {
            clickNode(instrumentation, back)
            SystemClock.sleep(1_000)
        }
    }

    private fun matches(node: AccessibilityNodeInfo, labels: List<String>): Boolean {
        val text = node.text?.toString()
        val desc = node.contentDescription?.toString()
        return labels.any { label ->
            text?.contains(label, ignoreCase = true) == true ||
                desc?.contains(label, ignoreCase = true) == true
        }
    }

    private fun matchesExact(node: AccessibilityNodeInfo, labels: List<String>): Boolean {
        val text = node.text?.toString()?.trim()
        val desc = node.contentDescription?.toString()?.trim()
        return labels.any { label ->
            text?.equals(label, ignoreCase = true) == true ||
                desc?.equals(label, ignoreCase = true) == true
        }
    }

    private fun awaitNode(instrumentation: Instrumentation, timeoutMillis: Long,
                          predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        val deadline = SystemClock.uptimeMillis() + timeoutMillis
        while (SystemClock.uptimeMillis() < deadline) {
            val node = findNode(instrumentation, predicate)
            if (node != null) return node
            SystemClock.sleep(350)
        }
        return null
    }

    private fun findNode(instrumentation: Instrumentation,
                         predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        val roots = instrumentation.uiAutomation.rootInActiveWindow ?: return null
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(roots)
        var visited = 0
        while (queue.isNotEmpty() && visited < 600) {
            val node = queue.removeFirst()
            visited += 1
            if (predicate(node)) return node
            for (index in 0 until node.childCount) {
                node.getChild(index)?.let(queue::add)
            }
        }
        return null
    }

    private fun dump(instrumentation: Instrumentation): String {
        val roots = instrumentation.uiAutomation.rootInActiveWindow ?: return "(no window)"
        val text = StringBuilder()
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(roots)
        var visited = 0
        while (queue.isNotEmpty() && visited < 400) {
            val node = queue.removeFirst()
            visited += 1
            val t = node.text?.toString()
            val d = node.contentDescription?.toString()
            if (!t.isNullOrBlank() || !d.isNullOrBlank()) {
                text.append('[').append(t ?: "").append('|').append(d ?: "").append("] ")
            }
            for (index in 0 until node.childCount) node.getChild(index)?.let(queue::add)
        }
        return text.toString()
    }

    private fun clickNode(instrumentation: Instrumentation, node: AccessibilityNodeInfo) {
        val bounds = Rect()
        node.getBoundsInScreen(bounds)
        val x = bounds.exactCenterX()
        val y = bounds.exactCenterY()
        val down = SystemClock.uptimeMillis()
        val source = InputDevice.SOURCE_TOUCHSCREEN
        val downEvent = MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN, x, y, 0)
        downEvent.source = source
        val upEvent = MotionEvent.obtain(down, down + 60, MotionEvent.ACTION_UP, x, y, 0)
        upEvent.source = source
        instrumentation.uiAutomation.injectInputEvent(downEvent, true)
        instrumentation.uiAutomation.injectInputEvent(upEvent, true)
        downEvent.recycle()
        upEvent.recycle()
    }
}
