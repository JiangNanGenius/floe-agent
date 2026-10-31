// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.pcap

import java.time.Instant
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

/**
 * Export and model-facing projections. The App-private store can hold a
 * detailed capture summary; `network.pcapAnalyze` never receives that form.
 * Its tool reply is explicitly redacted and page-shaped (<= 32 KiB), leaving
 * headroom inside the shared 64 KiB bridge frame (BridgeProtocol
 * MAX_REQUEST_BYTES / SettingsDomainV1 MAXIMUM_FRAME_BYTES).
 */
object PcapReportRenderer {
    const val MAX_TOOL_REPLY_BYTES = 32 * 1024

    fun renderViewJson(view: PcapSummaryView, detailed: Boolean = view.summary.detailed): String {
        val root = JSONObject(PcapSummaryCodec.encode(view.summary))
            .put("schema", "floe.pcap-analysis-view.v1")
            .put("filters", filters(view.filters, detailed))
            .put("matched", JSONObject()
                .put("flows", view.matchedFlows.size)
                .put("flowPackets", view.matchedPackets)
                .put("flowBytes", view.matchedBytes)
                .put("dns", view.matchedDns.size)
                .put("http", view.matchedHttp.size))
            .put("flows", flowArray(view.matchedFlows, detailed = detailed))
            .put("timeline", timelineArray(view.matchedTimeline))
            .put("dns", dnsArray(view.matchedDns, detailed = detailed))
            .put("http", httpArray(view.matchedHttp, detailed = detailed))
        val text = root.toString(2)
        require(text.toByteArray(Charsets.UTF_8).size <= PcapLimits.MAX_RESULT_BYTES) {
            "pcap view exceeds its bounded size"
        }
        return text
    }

    fun renderMarkdown(view: PcapSummaryView, detailed: Boolean = view.summary.detailed): String {
        val summary = view.summary
        val text = buildString {
            appendLine("# Floe capture analysis")
            appendLine()
            appendLine("- Analysis: `${summary.analysisID}`")
            appendLine("- Created: ${Instant.ofEpochMilli(summary.createdAtEpochMillis)}")
            appendLine("- Privacy: " + if (summary.detailed) {
                "detailed (local identifiers retained; exports must still be handled as private)"
            } else {
                "redacted (addresses and hosts are pseudonymized)"
            })
            appendLine("- Format: ${summary.format.wire}; status: ${summary.status.wire}")
            appendLine("- Source bytes: ${summary.sourceBytes}; parsed: ${summary.parsedBytes}; packets: ${summary.packetCount}")
            appendLine("- Capture span: ${summary.startEpochMillis?.let { Instant.ofEpochMilli(it) } ?: "unknown"} → " +
                "${summary.endEpochMillis?.let { Instant.ofEpochMilli(it) } ?: "unknown"}")
            appendLine("- Parse time: ${summary.parseMillis} ms of a ${summary.budgetMillis} ms budget")
            appendLine("- Flows: ${summary.totalFlowCount} total, ${summary.flows.size} retained by the bounded table")
            if (!view.filters.isEmpty) {
                appendLine("- Filters: ${filterDescription(view.filters)}")
                appendLine("- Matched: ${view.matchedFlows.size} retained flows, ${view.matchedPackets} packets, ${view.matchedBytes} bytes")
            }
            appendLine()
            appendLine("## Protocols")
            appendLine()
            appendLine("| Protocol | Packets | Bytes |")
            appendLine("|---|---:|---:|")
            summary.protocols.forEach {
                appendLine("| ${it.protocol.wire} | ${it.packetCount} | ${it.byteCount} |")
            }
            appendLine()
            appendLine("## Interfaces")
            appendLine()
            appendLine("| Index | Link type | Snap length | Timestamp resolution |")
            appendLine("|---:|---:|---:|---|")
            summary.interfaces.forEach {
                appendLine("| ${it.index} | ${it.linkType} | ${it.snaplen} | ${it.timestampResolution} |")
            }
            if (summary.flows.isNotEmpty()) {
                appendLine()
                appendLine("## Flows")
                appendLine()
                appendLine("| First | Last | Protocol | Source | Destination | Packets | Bytes | Flags |")
                appendLine("|---|---|---|---|---|---:|---:|---|")
                view.matchedFlows.forEach { flow ->
                    appendLine("| ${Instant.ofEpochMilli(flow.firstEpochMillis)} | " +
                        "${Instant.ofEpochMilli(flow.lastEpochMillis)} | ${flow.protocol.wire} | " +
                        "${displayAddress(flow.source, detailed)}${flow.source.port?.let { ":$it" } ?: ""} | " +
                        "${displayAddress(flow.destination, detailed)}${flow.destination.port?.let { ":$it" } ?: ""} | " +
                        "${flow.packetCount} | ${flow.byteCount} | ${flow.tcpFlags ?: ""} |")
                }
            }
            if (view.matchedDns.isNotEmpty()) {
                appendLine()
                appendLine("## DNS (bounded plaintext records)")
                appendLine()
                appendLine("| Time | Direction | Name | Type | RCODE |")
                appendLine("|---|---|---|---|---:|")
                view.matchedDns.forEach { record ->
                    appendLine("| ${Instant.ofEpochMilli(record.timestampEpochMillis)} | ${record.direction} | " +
                        "${displayDnsName(record, detailed)} | ${record.recordType} | ${record.responseCode ?: ""} |")
                }
            }
            if (view.matchedHttp.isNotEmpty()) {
                appendLine()
                appendLine("## HTTP (bounded plaintext records)")
                appendLine()
                appendLine("| Time | Direction | Method/status | Host | Path |")
                appendLine("|---|---|---|---|---|")
                view.matchedHttp.forEach { record ->
                    appendLine("| ${Instant.ofEpochMilli(record.timestampEpochMillis)} | ${record.direction} | " +
                        "${record.methodOrStatus} | ${displayHttpHost(record, detailed)} | " +
                        "${displayHttpPath(record, detailed)} |")
                }
            }
            appendLine()
            appendLine("## Limitations")
            appendLine()
            summary.limitations.forEach { appendLine("- $it") }
        }
        require(text.toByteArray(Charsets.UTF_8).size <= PcapLimits.MAX_MARKDOWN_BYTES) {
            "pcap markdown exceeds its bounded size"
        }
        return text
    }

    fun renderCsv(view: PcapSummaryView, detailed: Boolean = view.summary.detailed): String {
        val builder = StringBuilder("firstSeen,lastSeen,protocol,ipVersion,source,sourcePort,destination,destinationPort,packets,bytes,tcpFlags\n")
        for (flow in view.matchedFlows.take(PcapLimits.MAX_RETAINED_FLOWS)) {
            builder.append(csv(Instant.ofEpochMilli(flow.firstEpochMillis).toString())).append(',')
            builder.append(csv(Instant.ofEpochMilli(flow.lastEpochMillis).toString())).append(',')
            builder.append(csv(flow.protocol.wire)).append(',')
            builder.append(flow.ipVersion.number).append(',')
            builder.append(csv(displayAddress(flow.source, detailed))).append(',')
            builder.append(flow.source.port ?: "").append(',')
            builder.append(csv(displayAddress(flow.destination, detailed))).append(',')
            builder.append(flow.destination.port ?: "").append(',')
            builder.append(flow.packetCount).append(',')
            builder.append(flow.byteCount).append(',')
            builder.append(csv(flow.tcpFlags ?: ""))
            builder.append('\n')
            if (builder.length > PcapLimits.MAX_CSV_BYTES) break
        }
        val text = builder.toString()
        require(text.toByteArray(Charsets.UTF_8).size <= PcapLimits.MAX_CSV_BYTES) {
            "pcap CSV exceeds its bounded size"
        }
        return text
    }

    fun renderToolSummary(view: PcapSummaryView): String {
        val summary = view.summary
        var flowRows = minOf(view.matchedFlows.size, 40)
        var dnsRows = minOf(view.matchedDns.size, 20)
        var httpRows = minOf(view.matchedHttp.size, 20)
        var timelineRows = minOf(view.matchedTimeline.size, 24)
        while (true) {
            val root = JSONObject()
                .put("version", 1)
                .put("source", "phone")
                .put("schema", "floe.pcap-tool-summary.v1")
                .put("analysisID", summary.analysisID)
                .put("status", summary.status.wire)
                .put("format", summary.format.wire)
                .put("createdAt", Instant.ofEpochMilli(summary.createdAtEpochMillis).toString())
                .put("privacy", "redacted")
                .put("totals", JSONObject()
                    .put("packets", summary.packetCount)
                    .put("bytes", summary.totalByteCount)
                    .put("flows", summary.totalFlowCount)
                    .put("retainedFlows", summary.flows.size)
                    .put("dnsRecords", summary.dns.size)
                    .put("httpRecords", summary.http.size)
                    .put("startEpochMillis", summary.startEpochMillis ?: JSONObject.NULL)
                    .put("endEpochMillis", summary.endEpochMillis ?: JSONObject.NULL)
                    .put("parseMillis", summary.parseMillis))
                .put("filters", filters(view.filters, false))
                .put("matched", JSONObject()
                    .put("flows", view.matchedFlows.size)
                    .put("flowPackets", view.matchedPackets)
                    .put("flowBytes", view.matchedBytes)
                    .put("dns", view.matchedDns.size)
                    .put("http", view.matchedHttp.size))
                .put("protocols", JSONArray().apply {
                    summary.protocols.forEach {
                        put(JSONObject().put("protocol", it.protocol.wire)
                            .put("packets", it.packetCount).put("bytes", it.byteCount))
                    }
                })
                .put("flows", flowArray(view.matchedFlows.take(flowRows), detailed = false))
                .put("timeline", timelineArray(view.matchedTimeline.take(timelineRows)))
                .put("dns", dnsArray(view.matchedDns.take(dnsRows), detailed = false))
                .put("http", httpArray(view.matchedHttp.take(httpRows), detailed = false))
                .put("stoppedReason", summary.stoppedReason ?: JSONObject.NULL)
                .put("cancelled", summary.cancelled)
                .put("limitations", JSONArray().apply { summary.limitations.forEach(::put) })
            val text = root.toString()
            if (text.toByteArray(Charsets.UTF_8).size <= MAX_TOOL_REPLY_BYTES) return text
            when {
                flowRows > 10 -> flowRows -= 10
                httpRows > 0 -> httpRows = 0
                dnsRows > 0 -> dnsRows = 0
                timelineRows > 0 -> timelineRows = 0
                flowRows > 0 -> flowRows = 0
                else -> throw IllegalStateException("pcap tool summary cannot fit its bounded reply")
            }
        }
    }

    fun unavailableReply(analysisID: String?, code: String): String = JSONObject()
        .put("version", 1)
        .put("source", "phone")
        .put("schema", "floe.pcap-tool-summary.v1")
        .put("analysisID", analysisID ?: JSONObject.NULL)
        .put("status", "unavailable")
        .put("errorCode", code)
        .put("privacy", "redacted")
        .put("limitations", JSONArray().put("The requested offline analysis is not available."))
        .toString()

    private fun filters(filters: PcapFilters, detailed: Boolean): JSONObject = JSONObject()
        .put("protocols", JSONArray().apply { filters.protocols.forEach { put(it.wire) } })
        .put("services", JSONArray().apply { filters.services.forEach { put(it.name.lowercase(Locale.ROOT)) } })
        .put("address", filters.address?.let {
            if (detailed) it else "ip:" + PcapIdentifiers.token(it).take(12)
        } ?: JSONObject.NULL)
        .put("port", filters.port ?: JSONObject.NULL)
        .put("startEpochMillis", filters.startEpochMillis ?: JSONObject.NULL)
        .put("endEpochMillis", filters.endEpochMillis ?: JSONObject.NULL)

    private fun flowArray(flows: List<PcapFlow>, detailed: Boolean): JSONArray = JSONArray().apply {
        flows.forEach { flow ->
            put(JSONObject()
                .put("protocol", flow.protocol.wire)
                .put("ipVersion", flow.ipVersion.number)
                .put("src", JSONObject()
                    .put("address", if (detailed) flow.source.address else redactedAddress(flow.source))
                    .put("port", flow.source.port ?: JSONObject.NULL))
                .put("dst", JSONObject()
                    .put("address", if (detailed) flow.destination.address else redactedAddress(flow.destination))
                    .put("port", flow.destination.port ?: JSONObject.NULL))
                .put("packets", flow.packetCount)
                .put("bytes", flow.byteCount)
                .put("firstEpochMillis", flow.firstEpochMillis)
                .put("lastEpochMillis", flow.lastEpochMillis)
                .put("tcpFlags", flow.tcpFlags ?: JSONObject.NULL))
        }
    }

    private fun timelineArray(buckets: List<PcapTimelineBucket>): JSONArray = JSONArray().apply {
        buckets.forEach {
            put(JSONObject()
                .put("startEpochMillis", it.startEpochMillis)
                .put("bucketMillis", it.bucketMillis)
                .put("packets", it.packetCount)
                .put("bytes", it.byteCount))
        }
    }

    private fun dnsArray(records: List<PcapDnsRecord>, detailed: Boolean): JSONArray = JSONArray().apply {
        records.forEach {
            put(JSONObject()
                .put("timestampEpochMillis", it.timestampEpochMillis)
                .put("direction", it.direction)
                .put("name", if (detailed) it.name else redactedHost(it.nameToken))
                .put("recordType", it.recordType)
                .put("responseCode", it.responseCode ?: JSONObject.NULL)
                .put("overTcp", it.overTcp)
                .put("truncated", it.truncated))
        }
    }

    private fun httpArray(records: List<PcapHttpRecord>, detailed: Boolean): JSONArray = JSONArray().apply {
        records.forEach {
            put(JSONObject()
                .put("timestampEpochMillis", it.timestampEpochMillis)
                .put("direction", it.direction)
                .put("methodOrStatus", it.methodOrStatus)
                .put("host", when {
                    it.host == null -> JSONObject.NULL
                    detailed -> it.host
                    else -> redactedHost(PcapIdentifiers.token(it.host))
                })
                .put("path", when {
                    it.path == null -> JSONObject.NULL
                    detailed -> it.path
                    else -> redactedHost(PcapIdentifiers.token(it.path))
                })
                .put("payloadBytes", it.payloadBytes)
                .put("truncated", it.truncated))
        }
    }

    private fun displayAddress(endpoint: PcapEndpoint, detailed: Boolean): String =
        if (detailed) endpoint.address else redactedAddress(endpoint)

    private fun displayDnsName(record: PcapDnsRecord, detailed: Boolean): String =
        if (detailed) record.name else redactedHost(record.nameToken)

    private fun displayHttpHost(record: PcapHttpRecord, detailed: Boolean): String =
        record.host?.let { if (detailed) it else redactedHost(PcapIdentifiers.token(it)) } ?: ""

    private fun displayHttpPath(record: PcapHttpRecord, detailed: Boolean): String =
        record.path?.let { if (detailed) it else redactedHost(PcapIdentifiers.token(it)) } ?: ""

    private fun redactedAddress(endpoint: PcapEndpoint): String = "ip:" + endpoint.addressToken.take(12)

    private fun redactedHost(token: String): String = "host:" + token.take(12)

    private fun filterDescription(filters: PcapFilters): String = buildList {
        if (filters.protocols.isNotEmpty()) add("protocols=" + filters.protocols.joinToString(","))
        if (filters.services.isNotEmpty()) add("services=" + filters.services.joinToString(","))
        filters.address?.let { add("address token=" + PcapIdentifiers.token(it).take(12)) }
        filters.port?.let { add("port=$it") }
        filters.startEpochMillis?.let { add("from=${Instant.ofEpochMilli(it)}") }
        filters.endEpochMillis?.let { add("to=${Instant.ofEpochMilli(it)}") }
    }.joinToString("; ").ifBlank { "none" }

    private fun csv(value: String): String =
        if (value.any { it == ',' || it == '"' || it == '\n' || it == '\r' }) {
            "\"" + value.replace("\"", "\"\"") + "\""
        } else {
            value
        }
}
