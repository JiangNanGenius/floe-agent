// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.json.JSONArray
import org.json.JSONObject

/**
 * Bounded JSON projection for the host/Agent bridge. Text fields were already
 * redacted/bounded by the shaper; this projection adds a transport-level node
 * cap so one response cannot grow without limit even if a caller raised the
 * observation request to the maximum.
 *
 * No screenshot bytes are serialized here. The host owns the authorized binary
 * return path and must never persist raw screen content as a log.
 */
object PhoneControlJson {
    const val OBSERVATION_SCHEMA = "floe.phonecontrol.observation/1"
    const val ACTION_SCHEMA = "floe.phonecontrol.action/1"
    const val STATUS_SCHEMA = "floe.phonecontrol.status/1"

    private const val MAX_TRANSPORT_NODES = 300

    fun observation(observation: PhoneControlObservation): String =
        observationObject(observation).toString()

    fun actionResult(result: PhoneControlActionResult): String {
        val root = JSONObject()
            .put("schema", ACTION_SCHEMA)
            .put("action", result.action)
            .put("dispatch", result.dispatch.name)
            .putNullable("gestureCompleted", result.gestureCompleted)
            .putNullable("screenChanged", result.screenChanged)
            .putNullable("note", result.note)
        root.putNullable("observation", result.observation?.let { observationObject(it) })
        return root.toString()
    }

    fun status(status: PhoneControlStatus): String {
        val root = JSONObject()
            .put("schema", STATUS_SCHEMA)
            .put("connected", status.connected)
            .put("enabled", status.enabled)
            .putNullable("blocker", status.blocker?.name)
            .putNullable("activeOwner", status.activeOwner?.let { ownerObject(it) })
            .put("fenceGeneration", status.fenceGeneration)
            .put("pageGeneration", status.pageGeneration)
            .put("screenshotSupport", status.screenshotSupport.name)
        return root.toString()
    }

    private fun observationObject(observation: PhoneControlObservation): JSONObject {
        val nodes = JSONArray()
        var transported = 0
        for (node in observation.nodes) {
            if (transported >= MAX_TRANSPORT_NODES) break
            nodes.put(nodeObject(node))
            transported += 1
        }
        val transportTruncated = observation.nodes.size > transported
        return JSONObject()
            .put("schema", OBSERVATION_SCHEMA)
            .put("observationId", observation.observationId)
            .put("owner", ownerObject(observation.owner))
            .put("fenceGeneration", observation.fenceGeneration)
            .put("pageGeneration", observation.pageGeneration)
            .put("capturedAtElapsedRealtimeMillis", observation.capturedAtElapsedRealtimeMillis)
            .put("expiresAtElapsedRealtimeMillis", observation.expiresAtElapsedRealtimeMillis)
            .putNullable("packageName", observation.packageName)
            .put("windowId", observation.windowId)
            .putNullable("windowType", observation.windowType)
            .putNullable("windowTitle", observation.windowTitle)
            .put("displayId", observation.displayId)
            .putNullable("rootClassName", observation.rootClassName)
            .put("sensitiveWindow", observation.sensitiveWindow)
            .put("navigationOnly", observation.navigationOnly)
            .put("screenshotSupport", observation.screenshotSupport.name)
            .put("truncated", observation.truncated)
            .put("maxDepthReached", observation.maxDepthReached)
            .put("transportTruncated", transportTruncated)
            .put("nodeCount", observation.nodes.size)
            .put("nodes", nodes)
    }

    private fun nodeObject(node: PhoneControlNode): JSONObject = JSONObject()
        .put("ref", node.ref)
        .putNullable("parentRef", node.parentRef)
        .put("depth", node.depth)
        .put("className", node.className)
        .putNullable("packageName", node.packageName)
        .putNullable("viewId", node.viewId)
        .putNullable("text", node.text)
        .putNullable("contentDescription", node.contentDescription)
        .putNullable("hintText", node.hintText)
        .put(
            "bounds",
            JSONObject()
                .put("left", node.bounds.left)
                .put("top", node.bounds.top)
                .put("right", node.bounds.right)
                .put("bottom", node.bounds.bottom),
        )
        .put("visible", node.visible)
        .put("clickable", node.clickable)
        .put("editable", node.editable)
        .put("scrollable", node.scrollable)
        .put("enabled", node.enabled)
        .put("selected", node.selected)
        .put("checkable", node.checkable)
        .put("checked", node.checked)
        .put("password", node.password)
        .put("redacted", node.redacted)
        .put("truncated", node.truncated)

    private fun ownerObject(owner: PhoneControlOwner): JSONObject = JSONObject()
        .put("taskID", owner.taskID.toString())
        .put("runID", owner.runID.toString())

    private fun JSONObject.putNullable(key: String, value: Any?): JSONObject =
        put(key, value ?: JSONObject.NULL)
}
