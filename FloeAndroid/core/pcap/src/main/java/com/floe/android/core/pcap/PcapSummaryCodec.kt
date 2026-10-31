// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.pcap

import java.time.Instant
import org.json.JSONArray
import org.json.JSONObject

/**
 * Bounded structured encoding for the App-private summary. A stored summary
 * has no packets and no payload bytes; it is the actual aggregate produced by
 * [PcapAnalyzer] plus an honest status/limitations envelope. Callers must not
 * treat this JSON as a transport reply: the Agent tool uses
 * [PcapToolSummary], which is page-shaped and capped well below the shared
 * 64 KiB bridge frame.
 */
object PcapSummaryCodec {
    const val SCHEMA = "floe.pcap-analysis.v1"

    fun encode(summary: PcapSummary): String {
        val root = JSONObject()
            .put("schema", SCHEMA)
            .put("analysisID", summary.analysisID)
            .put("createdAt", Instant.ofEpochMilli(summary.createdAtEpochMillis).toString())
            .put("status", summary.status.wire)
            .put("format", summary.format.wire)
            .put("privacy", JSONObject().put("mode", if (summary.detailed) "detailed" else "redacted"))
            .put("source", JSONObject()
                .put("label", summary.sourceLabel ?: JSONObject.NULL)
                .put("bytes", summary.sourceBytes)
                .put("parsedBytes", summary.parsedBytes)
                .put("truncated", summary.sourceTruncated))
            .put("time", JSONObject()
                .put("startEpochMillis", summary.startEpochMillis ?: JSONObject.NULL)
                .put("endEpochMillis", summary.endEpochMillis ?: JSONObject.NULL)
                .put("parseMillis", summary.parseMillis)
                .put("budgetMillis", summary.budgetMillis))
            .put("counts", JSONObject()
                .put("packets", summary.packetCount)
                .put("captured", summary.capturedPacketCount)
                .put("truncatedPackets", summary.truncatedPacketCount)
                .put("malformed", summary.malformedPacketCount)
                .put("unsupported", summary.unsupportedPacketCount)
                .put("nonIp", summary.nonIpPacketCount)
                .put("flowOverflow", summary.flowTableOverflow)
                .put("totalFlows", summary.totalFlowCount)
                .put("bytes", summary.totalByteCount))
            .put("protocols", JSONArray().apply {
                summary.protocols.forEach {
                    put(JSONObject()
                        .put("protocol", it.protocol.wire)
                        .put("packets", it.packetCount)
                        .put("bytes", it.byteCount))
                }
            })
            .put("ipVersions", JSONObject().apply {
                summary.ipVersions.forEach { (version, count) -> put(version.wire, count) }
            })
            .put("interfaces", JSONArray().apply {
                summary.interfaces.forEach {
                    put(JSONObject()
                        .put("index", it.index)
                        .put("linkType", it.linkType)
                        .put("snaplen", it.snaplen)
                        .put("timestampResolution", it.timestampResolution)
                        .put("name", it.name ?: JSONObject.NULL))
                }
            })
            .put("flows", JSONArray().apply { summary.flows.forEach { put(flow(it)) } })
            .put("timeline", JSONArray().apply {
                summary.timeline.forEach {
                    put(JSONObject()
                        .put("startEpochMillis", it.startEpochMillis)
                        .put("bucketMillis", it.bucketMillis)
                        .put("packets", it.packetCount)
                        .put("bytes", it.byteCount))
                }
            })
            .put("dns", JSONArray().apply { summary.dns.forEach { put(dns(it)) } })
            .put("http", JSONArray().apply { summary.http.forEach { put(http(it)) } })
            .put("stoppedReason", summary.stoppedReason ?: JSONObject.NULL)
            .put("cancelled", summary.cancelled)
            .put("limitations", JSONArray().apply { summary.limitations.forEach(::put) })
        val text = root.toString(2)
        require(text.toByteArray(Charsets.UTF_8).size <= PcapLimits.MAX_RESULT_BYTES) {
            "pcap summary exceeds its bounded size"
        }
        return text
    }

    fun decode(json: String): PcapSummary {
        require(json.toByteArray(Charsets.UTF_8).size <= PcapLimits.MAX_RESULT_BYTES) {
            "pcap summary exceeds its bounded size"
        }
        val root = JSONObject(json)
        require(root.optString("schema") == SCHEMA) { "unexpected pcap summary schema" }
        val analysisID = root.getString("analysisID")
        val source = root.optJSONObject("source") ?: JSONObject()
        val time = root.optJSONObject("time") ?: JSONObject()
        val counts = root.optJSONObject("counts") ?: JSONObject()
        val protocols = root.optJSONArray("protocols") ?: JSONArray()
        val ipVersions = root.optJSONObject("ipVersions") ?: JSONObject()
        return PcapSummary(
            analysisID = analysisID,
            createdAtEpochMillis = runCatching {
                Instant.parse(root.getString("createdAt")).toEpochMilli()
            }.getOrElse { throw IllegalArgumentException("invalid createdAt") },
            status = PcapAnalysisStatus.entries.firstOrNull {
                it.wire == root.optString("status")
            } ?: throw IllegalArgumentException("invalid status"),
            format = PcapCaptureFormat.entries.firstOrNull {
                it.wire == root.optString("format")
            } ?: throw IllegalArgumentException("invalid format"),
            sourceLabel = source.opt("label")?.toString()?.takeIf { it != "null" },
            sourceBytes = source.optLong("bytes"),
            parsedBytes = source.optLong("parsedBytes"),
            totalByteCount = counts.optLong("bytes"),
            sourceTruncated = source.optBoolean("truncated"),
            detailed = root.optJSONObject("privacy")?.optString("mode") == "detailed",
            startEpochMillis = longOrNull(time, "startEpochMillis"),
            endEpochMillis = longOrNull(time, "endEpochMillis"),
            parseMillis = time.optLong("parseMillis"),
            budgetMillis = time.optLong("budgetMillis"),
            packetCount = counts.optLong("packets"),
            capturedPacketCount = counts.optLong("captured"),
            truncatedPacketCount = counts.optLong("truncatedPackets"),
            malformedPacketCount = counts.optLong("malformed"),
            unsupportedPacketCount = counts.optLong("unsupported"),
            nonIpPacketCount = counts.optLong("nonIp"),
            flowTableOverflow = counts.optLong("flowOverflow"),
            totalFlowCount = counts.optLong("totalFlows"),
            protocols = (0 until minOf(protocols.length(), PcapProtocol.entries.size)).mapNotNull { index ->
                val item = protocols.optJSONObject(index) ?: return@mapNotNull null
                val protocol = PcapProtocol.fromWire(item.optString("protocol")) ?: return@mapNotNull null
                PcapProtocolStats(protocol, item.optLong("packets"), item.optLong("bytes"))
            },
            ipVersions = buildMap {
                PcapIpVersion.entries.forEach { version ->
                    if (ipVersions.has(version.wire)) put(version, ipVersions.optLong(version.wire))
                }
            },
            interfaces = (root.optJSONArray("interfaces") ?: JSONArray()).let { array ->
                (0 until minOf(array.length(), PcapLimits.MAX_INTERFACES)).mapNotNull { index ->
                    val item = array.optJSONObject(index) ?: return@mapNotNull null
                    PcapInterface(
                        item.optInt("index"), item.optInt("linkType"), item.optLong("snaplen"),
                        item.optString("timestampResolution", "1e-6"),
                        item.opt("name")?.toString()?.takeIf { it != "null" },
                    )
                }
            },
            flows = (root.optJSONArray("flows") ?: JSONArray()).let { array ->
                (0 until minOf(array.length(), PcapLimits.MAX_RETAINED_FLOWS)).mapNotNull { index ->
                    val item = array.optJSONObject(index) ?: return@mapNotNull null
                    decodeFlow(item)
                }
            },
            timeline = (root.optJSONArray("timeline") ?: JSONArray()).let { array ->
                (0 until minOf(array.length(), PcapLimits.MAX_TIMELINE_BUCKETS)).mapNotNull { index ->
                    val item = array.optJSONObject(index) ?: return@mapNotNull null
                    PcapTimelineBucket(
                        item.optLong("startEpochMillis"), item.optLong("bucketMillis", 1_000L),
                        item.optLong("packets"), item.optLong("bytes"),
                    )
                }
            },
            dns = (root.optJSONArray("dns") ?: JSONArray()).let { array ->
                (0 until minOf(array.length(), PcapLimits.MAX_DNS_RECORDS)).mapNotNull { index ->
                    val item = array.optJSONObject(index) ?: return@mapNotNull null
                    decodeDns(item)
                }
            },
            http = (root.optJSONArray("http") ?: JSONArray()).let { array ->
                (0 until minOf(array.length(), PcapLimits.MAX_HTTP_RECORDS)).mapNotNull { index ->
                    val item = array.optJSONObject(index) ?: return@mapNotNull null
                    decodeHttp(item)
                }
            },
            stoppedReason = root.opt("stoppedReason")?.toString()?.takeIf { it != "null" },
            cancelled = root.optBoolean("cancelled"),
            limitations = (root.optJSONArray("limitations") ?: JSONArray()).let { array ->
                (0 until minOf(array.length(), PcapLimits.MAX_LIMITATIONS)).mapNotNull { index ->
                    array.optString(index).takeIf { it.isNotBlank() }?.take(300)
                }
            },
        )
    }

    fun entry(json: String): PcapStoredEntry {
        val summary = decode(json)
        return PcapStoredEntry(
            analysisID = summary.analysisID,
            createdAtEpochMillis = summary.createdAtEpochMillis,
            status = summary.status,
            format = summary.format,
            sourceLabel = summary.sourceLabel,
            detailed = summary.detailed,
            packetCount = summary.packetCount,
            flowCount = summary.totalFlowCount,
            sourceBytes = summary.sourceBytes,
            parseMillis = summary.parseMillis,
        )
    }

    private fun flow(flow: PcapFlow): JSONObject = JSONObject()
        .put("protocol", flow.protocol.wire)
        .put("ipVersion", flow.ipVersion.number)
        .put("src", endpoint(flow.source))
        .put("dst", endpoint(flow.destination))
        .put("packets", flow.packetCount)
        .put("bytes", flow.byteCount)
        .put("firstEpochMillis", flow.firstEpochMillis)
        .put("lastEpochMillis", flow.lastEpochMillis)
        .put("tcpFlags", flow.tcpFlags ?: JSONObject.NULL)

    private fun endpoint(endpoint: PcapEndpoint): JSONObject = JSONObject()
        .put("address", endpoint.address)
        .put("token", endpoint.addressToken)
        .put("port", endpoint.port ?: JSONObject.NULL)

    private fun dns(record: PcapDnsRecord): JSONObject = JSONObject()
        .put("timestampEpochMillis", record.timestampEpochMillis)
        .put("direction", record.direction)
        .put("name", record.name)
        .put("nameToken", record.nameToken)
        .put("recordType", record.recordType)
        .put("responseCode", record.responseCode ?: JSONObject.NULL)
        .put("src", endpoint(record.source))
        .put("dst", endpoint(record.destination))
        .put("overTcp", record.overTcp)
        .put("truncated", record.truncated)

    private fun http(record: PcapHttpRecord): JSONObject = JSONObject()
        .put("timestampEpochMillis", record.timestampEpochMillis)
        .put("direction", record.direction)
        .put("methodOrStatus", record.methodOrStatus)
        .put("host", record.host ?: JSONObject.NULL)
        .put("path", record.path ?: JSONObject.NULL)
        .put("src", endpoint(record.source))
        .put("dst", endpoint(record.destination))
        .put("payloadBytes", record.payloadBytes)
        .put("truncated", record.truncated)

    private fun decodeFlow(item: JSONObject): PcapFlow? = runCatching {
        PcapFlow(
            PcapProtocol.fromWire(item.getString("protocol"))
                ?: throw IllegalArgumentException("protocol"),
            PcapIpVersion.entries.firstOrNull { it.number == item.getInt("ipVersion") }
                ?: throw IllegalArgumentException("ipVersion"),
            decodeEndpoint(item.getJSONObject("src")),
            decodeEndpoint(item.getJSONObject("dst")),
            item.getLong("packets"),
            item.getLong("bytes"),
            item.getLong("firstEpochMillis"),
            item.getLong("lastEpochMillis"),
            item.opt("tcpFlags")?.toString()?.takeIf { it != "null" }?.take(32),
        )
    }.getOrNull()

    private fun decodeDns(item: JSONObject): PcapDnsRecord? = runCatching {
        PcapDnsRecord(
            item.getLong("timestampEpochMillis"),
            item.getString("direction"),
            item.getString("name"),
            item.getString("nameToken"),
            item.getString("recordType"),
            longOrNull(item, "responseCode")?.toInt(),
            decodeEndpoint(item.getJSONObject("src")),
            decodeEndpoint(item.getJSONObject("dst")),
            item.getBoolean("overTcp"),
            item.optBoolean("truncated"),
        )
    }.getOrNull()

    private fun decodeHttp(item: JSONObject): PcapHttpRecord? = runCatching {
        PcapHttpRecord(
            item.getLong("timestampEpochMillis"),
            item.getString("direction"),
            item.getString("methodOrStatus"),
            item.opt("host")?.toString()?.takeIf { it != "null" }?.take(320),
            item.opt("path")?.toString()?.takeIf { it != "null" }?.take(512),
            decodeEndpoint(item.getJSONObject("src")),
            decodeEndpoint(item.getJSONObject("dst")),
            item.getInt("payloadBytes"),
            item.optBoolean("truncated"),
        )
    }.getOrNull()

    private fun decodeEndpoint(item: JSONObject): PcapEndpoint = PcapEndpoint(
        item.getString("address"), item.getString("token"),
        longOrNull(item, "port")?.toInt(),
    )

    private fun longOrNull(value: JSONObject, key: String): Long? =
        if (value.has(key) && !value.isNull(key)) value.optLong(key) else null
}

data class PcapStoredEntry(
    val analysisID: String,
    val createdAtEpochMillis: Long,
    val status: PcapAnalysisStatus,
    val format: PcapCaptureFormat,
    val sourceLabel: String?,
    val detailed: Boolean,
    val packetCount: Long,
    val flowCount: Long,
    val sourceBytes: Long,
    val parseMillis: Long,
    val agentReadable: Boolean = false,
)
