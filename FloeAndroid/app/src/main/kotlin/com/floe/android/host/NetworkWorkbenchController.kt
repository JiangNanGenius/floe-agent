// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.network.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** App-owned diagnostics; recomposition/rotation never restarts measurements. */
internal class NetworkWorkbenchController(private val host: RuntimeHost) {
    val ownerID = "network-ui:" + UUID.randomUUID().toString()
    private val mutableState = MutableStateFlow(NetworkWorkbenchState())
    val state: StateFlow<NetworkWorkbenchState> = mutableState.asStateFlow()
    private val lock = Any()
    private var active = false
    private var operationID: String? = null
    private var job: Job? = null
    fun isActive(): Boolean = synchronized(lock) { active }
    fun enter() { synchronized(lock) { active = true } }
    fun leave() { synchronized(lock) { active = false }; cancel() }

    fun execute(page: NetworkPage, arguments: Map<String, String>) {
        val id: String
        val generation: Long
        val epoch: Long?
        synchronized(lock) {
            if (!active || operationID != null) return
            id = UUID.randomUUID().toString()
            operationID = id
            generation = host.commandClient.generation()
            epoch = host.nativeRootEpoch()
            mutableState.update { it.copy(running = page) }
            job = host.scope.launch(host.ioDispatcher) {
                try {
                    val args = JSONObject()
                    arguments.forEach { (key, value) ->
                        args.put(key, when (key) {
                            "refresh" -> value.toBooleanStrictOrNull() ?: false
                            "port" -> value.toIntOrNull() ?: 0
                            else -> value
                        })
                    }
                    val request = JSONObject().put("version", 1).put("operationID", id)
                        .put("method", page.method).put("arguments", args)
                    val response = host.networkService.execute(request.toString())
                    val observation = NetworkWorkbenchProjection.decode(page.method, id, response,
                        host.appContext.resources.configuration.locales[0].language == "zh")
                    synchronized(lock) {
                        if (active && operationID == id && host.commandClient.generation() == generation && host.nativeRootEpoch() == epoch) {
                            mutableState.update { current ->
                                val previous = current.results[page]?.accessPoints.orEmpty().associateBy { it.identity }
                                val withHistory = observation.copy(accessPoints = observation.accessPoints.map { ap ->
                                    val old = previous[ap.identity]
                                    val timestamp = ap.timestampMicros
                                    val signal = ap.signalDbm
                                    val history = when {
                                        ap.bssid == null || timestamp == null || signal == null -> emptyList()
                                        old != null && old.timestampMicros == timestamp -> old.signalHistoryDbm
                                        else -> (old?.signalHistoryDbm.orEmpty() + signal).takeLast(32)
                                    }
                                    ap.copy(signalHistoryDbm = history)
                                })
                                current.copy(results = current.results + (page to withHistory))
                            }
                        }
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    synchronized(lock) {
                        if (active && operationID == id && host.commandClient.generation() == generation && host.nativeRootEpoch() == epoch) {
                            mutableState.update { it.copy(results = it.results + (page to NetworkObservationUi(page.method, "error", ""))) }
                        }
                    }
                } finally {
                    synchronized(lock) {
                        if (operationID == id) { operationID = null; job = null; mutableState.update { it.copy(running = null) } }
                    }
                }
            }
        }
    }

    fun cancel() {
        synchronized(lock) {
            val id = operationID ?: return
            host.networkService.cancel(id)
            job?.cancel()
            // Clear this UI owner only, never another Agent's measurement.
            operationID = null; job = null
            mutableState.update { state ->
                val page = state.running
                state.copy(running = null, results = if (page == null) state.results else state.results +
                    (page to NetworkObservationUi(page.method, "cancelled", "")))
            }
        }
    }
}

internal object NetworkWorkbenchProjection {
    fun decode(method: String, operationID: String, json: String, zh: Boolean): NetworkObservationUi {
        require(json.toByteArray(Charsets.UTF_8).size <= 256 * 1024)
        val root = JSONObject(json)
        require(root.optInt("version") == 1 && root.optString("operationID") == operationID && root.optString("method") == method)
        val observations = root.optJSONObject("observations") ?: JSONObject()
        val aps = (observations.optJSONArray("accessPoints") ?: observations.optJSONArray("scanResults") ?: JSONArray())
        val accessPoints = (0 until minOf(aps.length(), 256)).mapNotNull { index ->
            val ap = aps.optJSONObject(index) ?: return@mapNotNull null
            fun number(vararg names: String): Int? = names.firstNotNullOfOrNull { key ->
                if (ap.isNull(key) || !ap.has(key)) null else ap.opt(key)?.toString()?.toIntOrNull()
            }
            val bssid = ap.optString("bssid").takeIf { it.isNotBlank() }
            WifiAccessPointUi(
                identity = "${bssid ?: "redacted:$index"}:${number("frequencyMhz", "frequencyMHz", "frequency")}",
                name = ap.optString("ssid"), bssid = bssid,
                signalDbm = number("rssiDbm", "rssi", "level", "signalDbm"),
                frequencyMHz = number("frequencyMhz", "frequencyMHz", "frequency"), channel = number("channel"),
                security = ap.optString("security", ap.optString("capabilities")).takeIf { it.isNotBlank() },
                ageMs = if (ap.has("ageMs")) ap.optLong("ageMs") else null,
                timestampMicros = if (ap.has("timestampMicros")) ap.optLong("timestampMicros").takeIf { it > 0 } else null,
            )
        }
        val facts = mutableListOf<NetworkFactUi>()
        fun flatten(obj: JSONObject, depth: Int = 0) {
            if (depth > 2 || facts.size >= 64) return
            obj.keys().asSequence().take(64).forEach { key ->
                if (key in setOf("accessPoints", "scanResults", "raw", "body", "payload")) return@forEach
                when (val value = obj.opt(key)) {
                    null, JSONObject.NULL -> Unit
                    is JSONObject -> flatten(value, depth + 1)
                    is JSONArray -> {
                        val title = label(key, zh) ?: return@forEach
                        val rendered = (0 until minOf(value.length(), 24)).mapNotNull { i ->
                            when (val row = value.opt(i)) { null, JSONObject.NULL -> null; is JSONObject -> row.keys().asSequence().take(8).mapNotNull { k -> label(k, zh)?.let { title -> "$title: ${row.opt(k)}" } }.joinToString(" · "); else -> row.toString() }
                        }.joinToString("\n")
                        if (rendered.isNotBlank()) facts += NetworkFactUi(title, rendered.take(4096))
                    }
                    else -> label(key, zh)?.let { title ->
                        facts += NetworkFactUi(title, when (value) { true -> if (zh) "是" else "Yes"; false -> if (zh) "否" else "No"; else -> value.toString().take(2048) })
                    }
                }
            }
        }
        root.optJSONObject("network")?.let { flatten(it) }
        flatten(observations)
        fun strings(key: String): List<String> = root.optJSONArray(key)?.let { a -> (0 until minOf(a.length(), 32)).map { a.optString(it).take(2048) } } ?: emptyList()
        return NetworkObservationUi(
            method, root.optString("status", "error"), root.optString("measuredAt"), facts.take(64), accessPoints,
            presentLimitations(root, observations, zh), if (root.has("cacheAgeMs") && !root.isNull("cacheAgeMs")) root.optLong("cacheAgeMs") else null,
            strings("missingPermissions"), root.toString(2),
        )
    }

    private fun presentLimitations(root: JSONObject, observations: JSONObject, zh: Boolean): List<String> {
        val messages = mutableListOf<Pair<String, String>>()
        val code = observations.optString("errorCode", observations.optString("unsupportedReason"))
        when (code) {
            "noActiveNetwork" -> messages += "Connect to a network and try again." to "请连接网络后重试。"
            "dnsFailure" -> messages += "The host could not be resolved on this network." to "当前网络无法解析此主机。"
            "tlsFailure" -> messages += "The secure connection could not be verified. Check the server certificate and network." to "无法验证安全连接，请检查服务器证书和网络。"
            "icmpv6NotImplemented" -> messages += "IPv6 Ping is not supported yet. DNS and TCP checks support IPv6." to "暂不支持 IPv6 Ping，可使用 DNS 或 TCP 检测。"
        }
        if (observations.has("locationServicesEnabled") && !observations.optBoolean("locationServicesEnabled"))
            messages += "Turn on Location in system settings, then refresh." to "请在系统设置中开启定位后刷新。"
        if (observations.has("scanAccepted") && !observations.optBoolean("scanAccepted"))
            messages += "Android did not accept a new scan. Cached results are shown when available; try again later." to "系统未接受新扫描，当前显示可用的缓存结果，请稍后重试。"
        val raw = root.optJSONArray("limitations")
        if (raw != null && raw.length() > 0 && messages.isEmpty())
            messages += "Some information could not be measured. See Details for the reason." to "部分信息无法获取，可在详细结果中查看原因。"
        return messages.distinct().map { if (zh) it.second else it.first }
    }

    private fun label(key: String, zh: Boolean): String? {
        val labels = mapOf(
            "typeName" to ("Connection" to "连接方式"), "transports" to ("Connections" to "连接方式"),
            "subtypeName" to ("Mobile network" to "移动网络"), "state" to ("State" to "状态"),
            "linkAddresses" to ("Addresses" to "地址"), "mtu" to ("MTU" to "MTU"),
            "privateDnsActive" to ("Private DNS active" to "私人 DNS 已启用"),
            "captivePortal" to ("Sign-in required" to "需要网络登录"),
            "internet" to ("Internet capability" to "互联网连接"), "roaming" to ("Roaming" to "漫游"),
            "rxLinkSpeedMbps" to ("Receive link (Mbps)" to "接收速率（Mbps）"),
            "txLinkSpeedMbps" to ("Transmit link (Mbps)" to "发送速率（Mbps）"),
            "wifiStandard" to ("Wi-Fi standard" to "Wi-Fi 标准"), "band" to ("Band" to "频段"),
            "widthMhz" to ("Channel width (MHz)" to "信道宽度（MHz）"),
            "totalAccessPoints" to ("Access points" to "接入点数量"),
            "scanAccepted" to ("Scan request accepted" to "扫描请求已接受"),
            "locationServicesEnabled" to ("Location enabled" to "定位已开启"),
            "value" to ("Value" to "结果"), "name" to ("Name" to "名称"),
            "rcodeName" to ("DNS status" to "DNS 状态"),
            "type" to ("Connection" to "连接方式"), "transport" to ("Connection" to "连接方式"),
            "interface" to ("Interface" to "网络接口"), "interfaceName" to ("Interface" to "网络接口"),
            "addresses" to ("Addresses" to "地址"), "ipAddresses" to ("Addresses" to "地址"),
            "dnsServers" to ("DNS servers" to "DNS 服务器"), "routes" to ("Routes" to "路由"),
            "validated" to ("Internet access" to "互联网访问"), "metered" to ("Metered" to "按流量计费"),
            "vpn" to ("VPN" to "VPN"), "isVpn" to ("VPN" to "VPN"), "privateDnsServerName" to ("Private DNS" to "私人 DNS"),
            "ssid" to ("Network name" to "网络名称"), "bssid" to ("Access point" to "接入点"),
            "rssiDbm" to ("Signal (dBm)" to "信号（dBm）"), "frequencyMHz" to ("Frequency (MHz)" to "频率（MHz）"),
            "frequencyMhz" to ("Frequency (MHz)" to "频率（MHz）"),
            "channel" to ("Channel" to "信道"), "channelWidthMHz" to ("Channel width (MHz)" to "信道宽度（MHz）"),
            "linkSpeedMbps" to ("Link speed (Mbps)" to "连接速率（Mbps）"),
            "scanRequested" to ("Scan requested" to "已请求扫描"), "scanUpdated" to ("Scan updated" to "扫描已更新"),
            "throttled" to ("Scan limited" to "扫描受限"), "wifiEnabled" to ("Wi-Fi enabled" to "Wi-Fi 已开启"),
            "answers" to ("Answers" to "查询结果"), "records" to ("Records" to "记录"), "recordType" to ("Record type" to "记录类型"),
            "ttl" to ("TTL (seconds)" to "TTL（秒）"), "ttlSeconds" to ("TTL (seconds)" to "TTL（秒）"),
            "elapsedMs" to ("Elapsed (ms)" to "耗时（毫秒）"), "durationMs" to ("Elapsed (ms)" to "耗时（毫秒）"),
            "connectMs" to ("Connection (ms)" to "连接（毫秒）"), "dnsMs" to ("DNS (ms)" to "DNS（毫秒）"),
            "tlsMs" to ("TLS (ms)" to "TLS（毫秒）"), "statusCode" to ("HTTP status" to "HTTP 状态"),
            "protocol" to ("Protocol" to "协议"), "cipherSuite" to ("Cipher suite" to "密码套件"),
            "finalURL" to ("Final URL" to "最终地址"), "finalUrl" to ("Final URL" to "最终地址"),
            "requestedUrl" to ("URL" to "地址"), "redirectCount" to ("Redirect count" to "重定向次数"),
            "dnsDurationMs" to ("DNS (ms)" to "DNS（毫秒）"),
            "connectTlsMs" to ("Connection and TLS (ms)" to "连接与 TLS（毫秒）"),
            "tcpConnectMs" to ("TCP connection (ms)" to "TCP 连接（毫秒）"),
            "tlsHandshakeMs" to ("TLS handshake (ms)" to "TLS 握手（毫秒）"),
            "probeTotalMs" to ("Total with redirects (ms)" to "含重定向总耗时（毫秒）"),
            "responseHeadersMs" to ("Response headers (ms)" to "响应头（毫秒）"),
            "totalMs" to ("Total (ms)" to "总耗时（毫秒）"), "redirects" to ("Redirects" to "重定向"),
            "sent" to ("Sent" to "已发送"), "received" to ("Received" to "已接收"), "lossPercent" to ("Loss (%)" to "丢包率（%）"),
            "minMs" to ("Minimum (ms)" to "最短（毫秒）"), "maxMs" to ("Maximum (ms)" to "最长（毫秒）"),
            "averageMs" to ("Average (ms)" to "平均（毫秒）"), "address" to ("Address" to "地址"),
            "host" to ("Host" to "主机"), "port" to ("Port" to "端口"), "connected" to ("Connected" to "已连接"),
        )
        val entry = labels[key]
        return entry?.let { if (zh) it.second else it.first }
    }
}
