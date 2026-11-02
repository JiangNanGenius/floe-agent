// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import android.content.Context
import com.floe.android.runtimeipc.RuntimeConnection
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * C01 truthful environment lifecycle host for the Android PRoot engine.
 *
 * The authority is the EXISTING [LocalRuntimeSetupHost] (component match,
 * install phases, notifications/permission intent) plus the existing runtime
 * service `status` operation. This object never downloads, installs, starts or
 * stops anything by itself: it reports the real setup phase and, for an explicit
 * user/root stop, calls the Main-installed root stop/drain closure only after
 * the same closure's foreign-owned-work gate answers true.
 *
 * No VM shape (vcpus/memoryMB) exists on this platform and no fake host mode is
 * exposed. The model-facing tool source calls this through the bounded mailbox
 * operation `host.environmentControl`; Main installs it from `FloeApplication`.
 */
object C01LinuxEnvironmentOwner {
    private data class Attachment(
        val context: Context,
        val setup: LocalRuntimeSetupHost,
        /** True only when NO foreign run/job/session/service owns the engine. */
        val noForeignOwnedWork: (suspend () -> Boolean)?,
        /** Existing Root stop/drain request. It must not be a model-only path. */
        val requestRootStop: (() -> Unit)?,
    )

    @Volatile
    private var attachment: Attachment? = null

    /** Install/replace the app-owned host. Passing null clears it (fail closed). */
    fun attach(
        context: Context,
        setup: LocalRuntimeSetupHost,
        noForeignOwnedWork: (suspend () -> Boolean)? = null,
        requestRootStop: (() -> Unit)? = null,
    ) {
        attachment = Attachment(context.applicationContext, setup, noForeignOwnedWork, requestRootStop)
        // Load the REAL install/component phase into the existing setup flow
        // even if the Settings card was never opened. This is a read/refresh;
        // it starts no download or install.
        runCatching { setup.refresh() }
    }

    fun detach() {
        attachment = null
    }

    /**
     * Answer one closed control action. Always returns a typed phase; an
     * unattached/unreachable host answers `refused`, never `ready`.
     */
    suspend fun handle(control: JSONObject): JSONObject {
        val attached = attachment ?: return refusal("hostNotWired")
        val action = control.optString("action")
        return when (action) {
            "catalog" -> catalog(attached, control)
            "status" -> status(attached, control)
            "start" -> start(attached, control)
            "stop" -> stop(attached, control)
            else -> refusal("unknownAction")
        }
    }

    /** Metadata only, scoped by the original runtime workspace identity. */
    private fun catalog(attached: Attachment, control: JSONObject): JSONObject = try {
        val projectID = java.util.UUID.fromString(control.getString("projectID")).toString()
        RuntimeConnection(attached.context).use { connection ->
            connection.connect().get(5, TimeUnit.SECONDS)
            val reply = connection.exchange("environment.list", JSONObject().put("projectID", projectID))
            check(reply.optBoolean("ok"))
            reply.getJSONObject("result").put("phase", "ready")
        }
    } catch (_: Exception) {
        refusal("The runtime environment catalog is unavailable.")
    }

    private suspend fun status(attached: Attachment, control: JSONObject): JSONObject {
        val state = attached.setup.state.value
        val runtime = runtimeStatus(attached.context)
        val phase = when (state.phase) {
            LocalRuntimeSetupHost.Phase.COMPONENT_REQUIRED -> "componentRequired"
            LocalRuntimeSetupHost.Phase.COMPONENT_INSTALLING -> "pending"
            LocalRuntimeSetupHost.Phase.SETUP_REQUIRED -> "setupRequired"
            LocalRuntimeSetupHost.Phase.INSTALL_REQUIRED -> "installRequired"
            LocalRuntimeSetupHost.Phase.INSTALLING -> "installing"
            LocalRuntimeSetupHost.Phase.INSTALLED -> if (runtime?.optBoolean("active") == true) "ready" else "installed"
            LocalRuntimeSetupHost.Phase.STOPPING -> "stopping"
            LocalRuntimeSetupHost.Phase.FAILED -> "failed"
            LocalRuntimeSetupHost.Phase.UNKNOWN -> "unknown"
        }
        val componentMatches = runCatching { RuntimeComponentMatch.matches(attached.context) }.getOrDefault(false)
        val installed = state.phase == LocalRuntimeSetupHost.Phase.INSTALLED
        return JSONObject()
            .put("phase", phase)
            .put("environmentID", control.optString("environmentID").take(128))
            .put("installed", installed)
            .put("runtimeActive", runtime?.optBoolean("active") == true)
            .put("runtimeStopping", runtime?.optBoolean("stopping") == true)
            .put("componentMatches", componentMatches)
            .put("readinessQualified", false) // Core overlays its own live answer
            .put("installRequired", phase == "installRequired" || phase == "setupRequired" || phase == "componentRequired")
            .put("retryable", phase == "installing" || phase == "pending" || phase == "stopping")
            .put("contractVersion", runtime?.optString("workloadContractVersion")?.take(64) ?: "")
            .put("detail", detailFor(phase))
    }

    private fun start(attached: Attachment, control: JSONObject): JSONObject {
        val state = attached.setup.state.value
        return when (state.phase) {
            LocalRuntimeSetupHost.Phase.INSTALLED -> statusBlocking(attached, control)
            LocalRuntimeSetupHost.Phase.INSTALLING,
            LocalRuntimeSetupHost.Phase.COMPONENT_INSTALLING,
            LocalRuntimeSetupHost.Phase.STOPPING -> pending(attached, control, "The existing runtime setup/stop operation is still running; nothing new was started.")
            LocalRuntimeSetupHost.Phase.INSTALL_REQUIRED,
            LocalRuntimeSetupHost.Phase.SETUP_REQUIRED -> {
                // Use the EXISTING host flow, not a parallel installer. It
                // returns immediately (pending/intent); readiness is proven
                // later by the install state observer + fresh ingress.
                attached.setup.prepare()
                pending(attached, control,
                    "The existing runtime setup/install flow was started or is waiting for its required user permission. Poll environment.linuxStatus; ready is reported only after the host proves installation.")
            }
            LocalRuntimeSetupHost.Phase.COMPONENT_REQUIRED -> installRequired(attached, control, "The Linux runtime component is missing or does not match the App. Use the existing runtime component install flow; this tool did not start it.")
            LocalRuntimeSetupHost.Phase.FAILED -> failure(attached, control, "The existing runtime install/setup reported a failure. Open Settings > Local Linux runtime for the actionable retry.")
            LocalRuntimeSetupHost.Phase.UNKNOWN -> refusal(attached, control, "The runtime setup state is not readable yet; nothing was started.")
        }
    }

    private suspend fun stop(attached: Attachment, control: JSONObject): JSONObject {
        val request = attached.requestRootStop
            ?: return refusal(attached, control, "The root stop request is not attached in this build; nothing was stopped.")
        when (attached.setup.state.value.phase) {
            LocalRuntimeSetupHost.Phase.COMPONENT_INSTALLING,
            LocalRuntimeSetupHost.Phase.INSTALLING,
            LocalRuntimeSetupHost.Phase.STOPPING ->
                return refusal(attached, control, "The existing runtime setup/stop operation is still running; wait for its real terminal before stopping again.")
            else -> Unit
        }
        val runtime = runtimeStatus(attached.context)
        // The runtime's own `active` is a real owned-work fact. A stop is
        // refused while ANY workload (including another task's) is live; the
        // Swift mailbox wrapper performs the same check across the Core
        // ledger/job surfaces before it reaches this owner.
        val gate = attached.noForeignOwnedWork
        val idle = if (gate != null) {
            try { gate.invoke() } catch (_: Exception) { false }
        } else {
            // No bound runtime service means no owned engine workload.
            runtime == null || (!runtime.optBoolean("active") && !runtime.optBoolean("stopping"))
        }
        if (!idle) {
            return JSONObject(base(attached, control, "refused"))
                .put("detail", "Another task's run, job, terminal or managed service still owns work in this environment; stop it explicitly first.")
                .put("retryable", true)
        }
        if (runtime?.optBoolean("active") != true) {
            return JSONObject(base(attached, control, "stopped"))
                .put("detail", "The runtime service reports no owned work; nothing was running.")
        }
        runCatching(request).onFailure {
            return failure(attached, control, "The existing root stop request failed; the environment was not changed.")
        }
        return JSONObject(base(attached, control, "stopping"))
            .put("runtimeStopping", true)
            .put("retryable", true)
            .put("detail", "The existing Root stop/drain was requested. Poll status until the host proves the stop.")
    }

    private fun statusBlocking(attached: Attachment, control: JSONObject): JSONObject {
        val runtime = runtimeStatus(attached.context)
        val phase = if (runtime?.optBoolean("active") == true) "ready" else "installed"
        return JSONObject(base(attached, control, phase))
            .put("runtimeActive", runtime?.optBoolean("active") == true)
            .put("contractVersion", runtime?.optString("workloadContractVersion")?.take(64) ?: "")
            .put("detail", if (runtime?.optBoolean("active") == true)
                "The engine rootfs is installed and the runtime service is active."
                else "The engine rootfs is installed; the runtime service is idle and starts on the next admitted workload.")
    }

    private fun pending(attached: Attachment, control: JSONObject, detail: String): JSONObject =
        JSONObject(base(attached, control, "pending")).put("retryable", true).put("detail", detail)

    private fun installRequired(attached: Attachment, control: JSONObject, detail: String): JSONObject =
        JSONObject(base(attached, control, "installRequired"))
            .put("installRequired", true)
            .put("retryable", true)
            .put("detail", detail)

    private fun failure(attached: Attachment, control: JSONObject, detail: String): JSONObject =
        JSONObject(base(attached, control, "failed")).put("retryable", true).put("detail", detail.take(512))

    private fun refusal(detail: String): JSONObject =
        JSONObject().put("phase", "refused").put("detail", detail.take(512))

    private fun refusal(attached: Attachment, control: JSONObject, detail: String): JSONObject =
        JSONObject(base(attached, control, "refused")).put("detail", detail.take(512))

    private fun base(attached: Attachment, control: JSONObject, phase: String): JSONObject {
        val state = attached.setup.state.value
        val componentMatches = runCatching { RuntimeComponentMatch.matches(attached.context) }.getOrDefault(false)
        return JSONObject()
            .put("phase", phase)
            .put("environmentID", control.optString("environmentID").take(128))
            .put("installed", state.phase == LocalRuntimeSetupHost.Phase.INSTALLED)
            .put("runtimeActive", false)
            .put("runtimeStopping", false)
            .put("componentMatches", componentMatches)
            .put("readinessQualified", false)
            .put("installRequired", false)
            .put("retryable", false)
            .put("contractVersion", "")
    }

    /**
     * Read-only runtime status through the SAME authenticated RuntimeConnection
     * used by the setup host. A missing runtime service is "not active", not an
     * error and never a fabricated ready.
     */
    private fun runtimeStatus(context: Context): JSONObject? = try {
        RuntimeConnection(context).use { connection ->
            connection.connect().get(5, TimeUnit.SECONDS)
            val reply = connection.exchange("status")
            if (reply.optBoolean("ok")) reply.optJSONObject("result") else null
        }
    } catch (_: Exception) {
        null
    }

    private fun detailFor(phase: String): String = when (phase) {
        "componentRequired" -> "The Linux runtime component is missing or does not match; use the existing runtime component install flow."
        "setupRequired" -> "Notification/setup permission is still required; open Settings > Local Linux runtime."
        "installRequired" -> "The Linux rootfs is not installed; open Settings > Local Linux runtime and complete the existing install."
        "installing", "pending" -> "The existing setup operation is running; wait for its real terminal."
        "installed" -> "The rootfs is installed; the runtime service is idle and starts on the next admitted workload."
        "ready" -> "The runtime service is active."
        "stopping" -> "An existing Root stop/drain is in progress."
        "failed" -> "The existing setup authority reported a failure; open the runtime settings for the actionable retry."
        else -> "No truthful environment state is available yet."
    }
}
