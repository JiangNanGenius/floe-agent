// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.network.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * One operation ownership ledger shared by the App controller's tests and the
 * real coroutine path. The service cancel is ID-scoped; the ledger proves that
 * a user stop keeps the same ID until its typed response arrives while a
 * navigation fence drops the ID immediately.
 */
internal class NetworkOperationLedger {
    var operationID: String? = null
        private set
    var stoppingID: String? = null
        private set
    var delivered: Boolean = false
        private set

    val busy: Boolean get() = operationID != null

    fun begin(id: String): Boolean {
        if (operationID != null) return false
        operationID = id
        stoppingID = null
        delivered = false
        return true
    }

    fun requestStop(id: String): Boolean {
        if (operationID != id || stoppingID == id) return false
        stoppingID = id
        return true
    }

    fun accepts(id: String): Boolean = operationID == id

    /** Marks the typed response as stored so the bounded fallback cannot replace it. */
    fun markDelivered(id: String): Boolean {
        if (operationID != id) return false
        delivered = true
        return true
    }

    fun fallbackEligible(id: String): Boolean =
        operationID == id && stoppingID == id && !delivered

    fun finish(id: String): Boolean {
        if (operationID != id) return false
        operationID = null
        stoppingID = null
        delivered = false
        return true
    }

    /** Drops this owner's ID without publishing anything; used on leave/root stop. */
    fun fence(): String? {
        val id = operationID
        operationID = null
        stoppingID = null
        delivered = false
        return id
    }
}

/** App-owned diagnostics; recomposition/rotation never restarts measurements. */
internal class NetworkWorkbenchController(private val host: RuntimeHost) {
    val ownerID = "network-ui:" + UUID.randomUUID().toString()
    private val mutableState = MutableStateFlow(NetworkWorkbenchState())
    val state: StateFlow<NetworkWorkbenchState> = mutableState.asStateFlow()
    private val lock = Any()
    private var active = false
    private val ledger = NetworkOperationLedger()
    private var job: Job? = null
    private var fallbackJob: Job? = null

    fun isActive(): Boolean = synchronized(lock) { active }

    fun enter() { synchronized(lock) { active = true } }

    fun leave() {
        synchronized(lock) { active = false }
        cancel()
    }

    fun execute(command: NetworkExecuteCommand) {
        val page = command.page
        val id: String
        val generation: Long
        val epoch: Long?
        synchronized(lock) {
            if (!active || ledger.busy) return
            id = UUID.randomUUID().toString()
            if (!ledger.begin(id)) return
            generation = host.commandClient.generation()
            epoch = host.nativeRootEpoch()
            mutableState.update { it.copy(running = page, stopping = false) }
            job = host.scope.launch(host.ioDispatcher) {
                try {
                    val args = NetworkWorkbenchRequests.arguments(command) ?: return@launch
                    val request = JSONObject().put("version", 1).put("operationID", id)
                        .put("method", page.method).put("arguments", args)
                    val response = host.networkService.execute(request.toString())
                    val observation = NetworkWorkbenchProjection.decode(
                        page.method, id, response,
                        host.appContext.resources.configuration.locales[0].language == "zh",
                    )
                    synchronized(lock) {
                        if (active && ledger.accepts(id) &&
                            host.commandClient.generation() == generation &&
                            host.nativeRootEpoch() == epoch
                        ) {
                            mutableState.update { current ->
                                val previous = current.results[page]?.accessPoints.orEmpty()
                                    .associateBy { it.identity }
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
                            ledger.markDelivered(id)
                        }
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    synchronized(lock) {
                        if (active && ledger.accepts(id) &&
                            host.commandClient.generation() == generation &&
                            host.nativeRootEpoch() == epoch
                        ) {
                            mutableState.update {
                                it.copy(results = it.results + (page to NetworkObservationUi(page.method, "error", "")))
                            }
                            ledger.markDelivered(id)
                        }
                    }
                } finally {
                    synchronized(lock) {
                        if (ledger.finish(id)) {
                            job = null
                            fallbackJob?.cancel()
                            fallbackJob = null
                            mutableState.update { it.copy(running = null, stopping = false) }
                        }
                    }
                }
            }
        }
    }

    /**
     * User stop: ask the service to cancel this ID but keep ownership until the
     * typed cancelled/partial envelope arrives. A bounded fallback only clears
     * the local run if the service never returns.
     */
    fun stop() {
        val id: String
        synchronized(lock) {
            if (!active) return
            id = ledger.operationID ?: return
            if (!ledger.requestStop(id)) return
            mutableState.update { it.copy(stopping = true) }
        }
        host.networkService.cancel(id)
        val fallback = host.scope.launch(host.ioDispatcher) {
            delay(STOP_FALLBACK_MS)
            synchronized(lock) {
                if (ledger.fallbackEligible(id)) {
                    job?.cancel()
                    job = null
                    ledger.finish(id)
                    mutableState.update { state ->
                        val page = state.running
                        state.copy(
                            running = null,
                            stopping = false,
                            results = if (page == null) state.results else state.results +
                                (page to NetworkObservationUi(page.method, "cancelled", "")),
                        )
                    }
                }
            }
        }
        synchronized(lock) {
            if (ledger.accepts(id) && ledger.stoppingID == id) fallbackJob = fallback
            else fallback.cancel()
        }
    }

    /** Navigation/root fence: discard the owner and never publish its result. */
    fun cancel() {
        val id: String?
        synchronized(lock) {
            id = ledger.fence()
            fallbackJob?.cancel()
            fallbackJob = null
            job?.cancel()
            job = null
            mutableState.update { state ->
                val page = state.running
                state.copy(
                    running = null,
                    stopping = false,
                    results = if (page == null || id == null) state.results else state.results +
                        (page to NetworkObservationUi(page.method, "cancelled", "")),
                )
            }
        }
        id?.let { host.networkService.cancel(it) }
    }

    private companion object {
        const val STOP_FALLBACK_MS = 4_000L
    }
}

/**
 * Exact typed serialization for the two G07.2 methods. Simple pages keep their
 * historical `refresh`/`port` conversion only; every other value remains a
 * string. LAN/speed values are read from typed input objects, never guessed
 * from arbitrary map entries.
 */
internal object NetworkWorkbenchRequests {
    fun arguments(command: NetworkExecuteCommand): JSONObject? = when (command) {
        is NetworkExecuteCommand.Simple -> JSONObject().apply {
            command.arguments.forEach { (key, value) ->
                when (key) {
                    "refresh" -> put(key, value.toBooleanStrictOrNull() ?: false)
                    "port" -> put(key, value.toIntOrNull() ?: 0)
                    else -> put(key, value)
                }
            }
        }
        is NetworkExecuteCommand.LanDiscovery -> {
            val input = command.input
            if (input.problems().isNotEmpty()) {
                null
            } else {
                JSONObject().apply {
                    if (input.serviceTypes.isNotEmpty()) {
                        put("serviceTypes", toJsonArray(input.serviceTypes))
                    }
                    put("discoveryDurationMs", input.discoveryDurationMs)
                    put("includeAttributes", input.includeAttributes)
                    input.subnetCidr?.let { put("subnetCidr", it) }
                    if (input.ports.isNotEmpty()) put("ports", toJsonArray(input.ports))
                    put("tcpConnectTimeoutMs", input.tcpConnectTimeoutMs)
                    put("tcpConcurrency", input.tcpConcurrency)
                    put("timeoutMs", input.timeoutMs)
                }
            }
        }
        is NetworkExecuteCommand.SpeedTest -> {
            val input = command.input
            if (input.problems().isNotEmpty()) {
                null
            } else {
                JSONObject().apply {
                    put("direction", input.direction.wire)
                    input.downloadUrl?.let { put("downloadUrl", it) }
                    input.uploadUrl?.let { put("uploadUrl", it) }
                    put("maxBytesPerDirection", input.maxBytesPerDirection)
                    put("durationBudgetMs", input.durationBudgetMs)
                    put("warmupBytes", 0)
                    put("allowMetered", input.allowMetered)
                    put("timeoutMs", input.timeoutMs)
                }
            }
        }
    }

    private fun toJsonArray(values: Iterable<*>): JSONArray = JSONArray().apply {
        values.forEach { put(it) }
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
        // Keep the captured-network snapshot separate from the method's own
        // observations. The latter is what the user asked for; the former is
        // common metadata that belongs in explicit Details. Each fact carries
        // its stable JSON path, never a label guess.
        val connectionFacts = mutableListOf<NetworkFactUi>()
        val observationFacts = mutableListOf<NetworkFactUi>()
        fun flatten(
            obj: JSONObject,
            target: MutableList<NetworkFactUi>,
            prefix: String,
            depth: Int = 0,
        ) {
            if (depth > 2 || target.size >= 96) return
            // Stable path order: the JVM unit-test JSON implementation does not
            // preserve insertion order, so sort keys to keep the projected
            // groups deterministic on both the test JVM and the device.
            obj.keys().asSequence().sorted().take(96).forEach { key ->
                if (key in setOf("accessPoints", "scanResults", "raw", "body", "payload")) return@forEach
                val path = if (prefix.isEmpty()) key else "$prefix.$key"
                when (val value = obj.opt(key)) {
                    null, JSONObject.NULL -> Unit
                    is JSONObject -> flatten(value, target, path, depth + 1)
                    is JSONArray -> {
                        val title = label(key, zh) ?: return@forEach
                        val rendered = (0 until minOf(value.length(), 24)).mapNotNull { i ->
                            when (val row = value.opt(i)) { null, JSONObject.NULL -> null; is JSONObject -> row.keys().asSequence().take(8).map { k -> "${label(k, zh) ?: k}: ${row.opt(k)}" }.joinToString(" · "); else -> row.toString() }
                        }.joinToString("\n")
                        if (rendered.isNotBlank()) target += NetworkFactUi(title, rendered.take(4096), path)
                    }
                    else -> label(key, zh)?.let { title ->
                        target += NetworkFactUi(title, when (value) { true -> if (zh) "是" else "Yes"; false -> if (zh) "否" else "No"; else -> value.toString().take(2048) }, path)
                    }
                }
            }
        }
        root.optJSONObject("network")?.let { flatten(it, connectionFacts, "network") }
        flatten(observations, observationFacts, "observations")
        val sections = NetworkResultSections.partition(method, connectionFacts, observationFacts)
        val facts = (sections.primary + sections.connection + sections.detail).take(128)
        fun strings(key: String): List<String> = root.optJSONArray(key)?.let { a -> (0 until minOf(a.length(), 32)).map { a.optString(it).take(2048) } } ?: emptyList()
        return NetworkObservationUi(
            method, root.optString("status", "error"), root.optString("measuredAt"), facts, accessPoints,
            presentLimitations(root, observations, zh, method),
            if (root.has("cacheAgeMs") && !root.isNull("cacheAgeMs")) root.optLong("cacheAgeMs") else null,
            strings("missingPermissions"), root.toString(2),
            primaryFacts = sections.primary,
            connectionFacts = sections.connection,
            detailFacts = sections.detail,
            lan = if (method == NetworkPage.LAN.method) decodeLan(observations) else null,
            speed = if (method == NetworkPage.SPEED.method) decodeSpeed(observations) else null,
            certificates = if (method == NetworkPage.HTTPS.method) decodeCertificates(observations) else emptyList(),
        )
    }

    private fun decodeCertificates(observations: JSONObject): List<TlsCertificateUi> {
        val array = observations.optJSONObject("tls")?.optJSONObject("peerCertificates")
            ?.optJSONArray("certificates") ?: return emptyList()
        return (0 until minOf(array.length(), 8)).mapNotNull { index ->
            val item = array.optJSONObject(index) ?: return@mapNotNull null
            val hash = item.optString("sha256")
            val before = item.optString("notBefore")
            val after = item.optString("notAfter")
            if (!hash.matches(Regex("[0-9a-f]{64}")) ||
                runCatching { java.time.Instant.parse(before); java.time.Instant.parse(after) }.isFailure ||
                item.opt("validAtObservation") !is Boolean) return@mapNotNull null
            TlsCertificateUi(item.optInt("chainIndex", index), hash, before, after,
                item.getBoolean("validAtObservation"), item.optString("signatureAlgorithm").take(128),
                item.optString("publicKeyAlgorithm").take(128))
        }
    }

    private fun decodeLan(observations: JSONObject): LanDiscoveryUi {
        val mdns = observations.optJSONObject("mdns")?.let { value ->
            val services = value.optJSONArray("services")?.let { array ->
                (0 until minOf(array.length(), 64)).mapNotNull { index ->
                    val service = array.optJSONObject(index) ?: return@mapNotNull null
                    LanServiceUi(
                        serviceName = service.optString("serviceName").take(128),
                        serviceType = service.optString("serviceType").take(64),
                        hostname = service.stringOrNull("hostname"),
                        addresses = jsonStrings(service.optJSONArray("addresses")).take(16),
                        port = service.intOrNull("port")?.takeIf { it in 1..65_535 },
                        state = service.optString("state", "active"),
                        resolution = service.optString("resolution", "unresolved"),
                        resolveError = service.stringOrNull("resolveError"),
                    )
                }
            }.orEmpty()
            LanMdnsUi(
                requestedServiceTypes = jsonStrings(value.optJSONArray("requestedServiceTypes")),
                scope = value.optString("scope"),
                networkScoped = value.optBoolean("networkScoped"),
                discoveryDurationMs = value.optInt("discoveryDurationMs"),
                elapsedMs = value.optLong("elapsedMs"),
                services = services,
                serviceCount = if (value.has("serviceCount")) value.optInt("serviceCount") else services.size,
                activeServiceCount = value.optInt("activeServiceCount"),
                unresolvedCount = value.optInt("unresolvedCount"),
                lostCount = value.optInt("lostCount"),
                filteredForeignNetwork = value.optInt("filteredForeignNetwork"),
                truncated = value.optBoolean("truncated"),
                noReplies = value.optBoolean("noReplies"),
                stoppedReason = value.optString("stoppedReason"),
            )
        }
        val tcp = observations.optJSONObject("tcp")?.let { value ->
            val openPorts = value.optJSONArray("openPorts")?.let { array ->
                (0 until minOf(array.length(), 256)).mapNotNull { index ->
                    val open = array.optJSONObject(index) ?: return@mapNotNull null
                    LanOpenPortUi(
                        address = open.optString("address").take(45),
                        port = open.optInt("port"),
                        connectTimeMs = open.optLong("connectTimeMs"),
                    )
                }
            }.orEmpty()
            LanTcpUi(
                subnetCidr = value.optString("subnetCidr"),
                ports = jsonInts(value.optJSONArray("ports")).take(8),
                hostCount = value.optInt("hostCount"),
                excludedSelfAddresses = jsonStrings(value.optJSONArray("excludedSelfAddresses")).take(16),
                attemptedHosts = value.optInt("attemptedHosts"),
                plannedAttempts = value.optInt("plannedAttempts"),
                completedAttempts = value.optInt("completedAttempts"),
                openPorts = openPorts,
                refusedAttempts = value.optInt("refusedAttempts"),
                timedOutAttempts = value.optInt("timedOutAttempts"),
                errorAttempts = value.optInt("errorAttempts"),
                unreachableAttempts = value.optInt("unreachableAttempts"),
                hostsWithResponse = value.optInt("hostsWithResponse"),
                hostsWithOpenPort = value.optInt("hostsWithOpenPort"),
                truncated = value.optBoolean("truncated"),
                stoppedReason = value.optString("stoppedReason"),
                cancelled = value.optBoolean("cancelled"),
                elapsedMs = value.optLong("elapsedMs"),
            )
        }
        return LanDiscoveryUi(
            mdns = mdns,
            tcp = tcp,
            noReplies = observations.optBoolean("noReplies"),
            networkChanged = observations.optBoolean("networkChanged"),
            cancelled = observations.optBoolean("cancelled"),
            errorCode = observations.stringOrNull("errorCode"),
        )
    }

    private fun decodeSpeed(observations: JSONObject): SpeedTestUi {
        val budget = observations.optJSONObject("budget")
        val transfers = buildList {
            observations.optJSONObject("download")?.let { add(decodeSpeedTransfer("download", it)) }
            observations.optJSONObject("upload")?.let { add(decodeSpeedTransfer("upload", it)) }
        }
        val proxy = observations.optJSONObject("proxy")
        return SpeedTestUi(
            direction = observations.optString("direction"),
            maxBytesPerDirection = budget?.longOrNull("maxBytesPerDirection"),
            durationBudgetMs = budget?.longOrNull("durationBudgetMs"),
            warmupBytes = budget?.longOrNull("warmupBytes"),
            timeoutMs = budget?.longOrNull("timeoutMs"),
            metered = observations.booleanOrNull("metered"),
            allowMetered = observations.optBoolean("allowMetered"),
            singleTransfer = observations.optBoolean("singleTransfer"),
            sampleAdequate = observations.booleanOrNull("sampleAdequate"),
            transfers = transfers,
            networkChanged = observations.optBoolean("networkChanged"),
            proxyConfigured = proxy?.optBoolean("configured") ?: false,
            proxyHost = proxy?.stringOrNull("host"),
            proxyPort = proxy?.intOrNull("port")?.takeIf { it in 1..65_535 },
            cancelled = observations.optBoolean("cancelled"),
            errorCode = observations.stringOrNull("errorCode"),
        )
    }

    private fun decodeSpeedTransfer(direction: String, value: JSONObject): SpeedTransferUi = SpeedTransferUi(
        direction = direction,
        endpoint = value.optString("endpoint"),
        status = value.optString("status", "error"),
        payloadBytes = value.longOrNull("payloadBytes"),
        measuredBytes = value.longOrNull("measuredBytes"),
        warmupBytes = value.longOrNull("warmupBytes"),
        measurementElapsedMs = value.longOrNull("measurementElapsedMs"),
        totalElapsedMs = value.longOrNull("totalElapsedMs"),
        bitsPerSecond = value.doubleOrNull("bitsPerSecond"),
        rateAvailable = value.optBoolean("rateAvailable"),
        rateOmittedReason = value.stringOrNull("rateOmittedReason"),
        completionReason = value.stringOrNull("completionReason"),
        contentComplete = value.optBoolean("contentComplete"),
        clientStopped = value.optBoolean("clientStopped"),
        httpStatus = value.intOrNull("httpStatus"),
        contentLength = value.longOrNull("contentLength"),
        contentEncoding = value.stringOrNull("contentEncoding"),
        tlsProtocol = value.stringOrNull("tlsProtocol"),
        cipherSuite = value.stringOrNull("cipherSuite"),
        payloadBytesMeaning = value.stringOrNull("payloadBytesMeaning"),
        networkChanged = value.optBoolean("networkChanged"),
    )

    private fun presentLimitations(
        root: JSONObject,
        observations: JSONObject,
        zh: Boolean,
        method: String,
    ): List<String> {
        val messages = mutableListOf<Pair<String, String>>()
        val code = observations.optString("errorCode", observations.optString("unsupportedReason", observations.optString("stoppedReason")))
        when (code) {
            "noActiveNetwork" -> messages += "Connect to a network and try again." to "请连接网络后重试。"
            "dnsFailure" -> messages += "The host could not be resolved on this network." to "当前网络无法解析此主机。"
            "tlsCertificateExpired" -> messages += "The server certificate has expired. Check the device date and server certificate." to "服务器证书已过期，请检查设备日期和服务器证书。"
            "tlsCertificateNotYetValid" -> messages += "The server certificate is not valid yet. Check the device date." to "服务器证书尚未生效，请检查设备日期。"
            "tlsTrustVerificationFailed" -> messages += "Android could not verify the certificate chain. The connection was stopped." to "Android 无法验证证书链，连接已停止。"
            "tlsHostnameVerificationFailed" -> messages += "The certificate does not match this host. The connection was stopped." to "证书与主机不匹配，连接已停止。"
            "tlsFailure" -> messages += "The secure connection could not be verified. Check the server certificate and network." to "无法验证安全连接，请检查服务器证书和网络。"
            "icmpv6NotImplemented" -> messages += "IPv6 Ping is not supported yet. DNS and TCP checks support IPv6." to "暂不支持 IPv6 Ping，可使用 DNS 或 TCP 检测。"
            "meteredNetworkDisallowed" -> messages += "This network is metered. Enable metered transfers and start again." to "当前网络按流量计费，请允许按流量计费传输后重试。"
            "nsdNetworkScopeUnsupported" -> messages += "mDNS discovery needs Android 13 or later. Use the private subnet scan." to "mDNS 发现需要 Android 13 或更高版本，请使用私有子网扫描。"
            "nsdPermissionDenied" -> messages += "Local network access is needed. Allow it, then start a new check." to "需要局域网访问权限，允许后请重新开始检测。"
            "localNetworkPermissionRequired" -> messages += "This local endpoint needs Local Network access. Allow it, then start a new check." to "此本地地址需要局域网访问权限，允许后请重新开始检测。"
        }
        if (observations.has("locationServicesEnabled") && !observations.optBoolean("locationServicesEnabled"))
            messages += "Turn on Location in system settings, then refresh." to "请在系统设置中开启定位后刷新。"
        if (observations.has("scanAccepted") && !observations.optBoolean("scanAccepted"))
            messages += "Android did not accept a new scan. Cached results are shown when available; try again later." to "系统未接受新扫描，当前显示可用的缓存结果，请稍后重试。"
        val raw = root.optJSONArray("limitations")
        val structured = method == NetworkPage.LAN.method || method == NetworkPage.SPEED.method
        if (raw != null && raw.length() > 0 && messages.isEmpty() && !structured)
            messages += "Some information could not be measured. See Details for the reason." to "部分信息无法获取，可在详细结果中查看原因。"
        return messages.distinct().map { if (zh) it.second else it.first }
    }

    private fun jsonStrings(array: JSONArray?): List<String> {
        if (array == null) return emptyList()
        return (0 until minOf(array.length(), 64)).mapNotNull { index ->
            array.opt(index)?.toString()?.takeIf { it.isNotBlank() }?.take(2_048)
        }
    }

    private fun jsonInts(array: JSONArray?): List<Int> {
        if (array == null) return emptyList()
        return (0 until minOf(array.length(), 64)).mapNotNull { index ->
            if (array.isNull(index)) null else array.optInt(index)
        }
    }

    private fun JSONObject.stringOrNull(key: String): String? =
        optString(key).takeIf { it.isNotBlank() }

    private fun JSONObject.intOrNull(key: String): Int? =
        if (has(key) && !isNull(key)) optInt(key) else null

    private fun JSONObject.longOrNull(key: String): Long? =
        if (has(key) && !isNull(key)) optLong(key) else null

    private fun JSONObject.booleanOrNull(key: String): Boolean? =
        if (has(key) && !isNull(key)) optBoolean(key) else null

    private fun JSONObject.doubleOrNull(key: String): Double? =
        if (has(key) && !isNull(key)) optDouble(key).takeIf { it.isFinite() && it >= 0.0 } else null

    private fun label(key: String, zh: Boolean): String? {
        val labels = mapOf(
            "typeName" to ("Connection" to "连接方式"), "transports" to ("Connections" to "连接方式"),
            "subtypeName" to ("Mobile network" to "移动网络"), "state" to ("State" to "状态"),
            "linkAddresses" to ("Addresses" to "地址"), "mtu" to ("MTU" to "MTU"),
            "privateDnsActive" to ("Private DNS active" to "私人 DNS 已启用"),
            "captivePortal" to ("Sign-in required" to "需要网络登录"),
            "internet" to ("Internet capability" to "互联网连接"),
            "localNetwork" to ("Local network capability" to "本地网络能力"),
            "roaming" to ("Roaming" to "漫游"),
            "rxLinkSpeedMbps" to ("Receive link (Mbps)" to "接收速率（Mbps）"),
            "txLinkSpeedMbps" to ("Transmit link (Mbps)" to "发送速率（Mbps）"),
            "wifiStandard" to ("Wi-Fi standard" to "Wi-Fi 标准"), "band" to ("Band" to "频段"),
            "widthMhz" to ("Channel width (MHz)" to "信道宽度（MHz）"),
            "totalAccessPoints" to ("Access points" to "接入点数量"),
            "scanAccepted" to ("Scan request accepted" to "扫描请求已接受"),
            "locationServicesEnabled" to ("Location enabled" to "定位已开启"),
            "freshness" to ("Scan freshness" to "扫描新鲜度"),
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
            "truncated" to ("Result truncated" to "结果已截断"),
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
            "sent" to ("Sent" to "已发送"), "received" to ("Received" to "已接收"),
            "lost" to ("Lost" to "丢失"), "packetLossPercent" to ("Loss (%)" to "丢包率（%）"),
            "lossPercent" to ("Loss (%)" to "丢包率（%）"),
            "minMs" to ("Minimum (ms)" to "最短（毫秒）"), "maxMs" to ("Maximum (ms)" to "最长（毫秒）"),
            "averageMs" to ("Average (ms)" to "平均（毫秒）"),
            "rttMinMs" to ("Minimum RTT (ms)" to "最短 RTT（毫秒）"),
            "rttMaxMs" to ("Maximum RTT (ms)" to "最长 RTT（毫秒）"),
            "rttAvgMs" to ("Average RTT (ms)" to "平均 RTT（毫秒）"),
            "countRequested" to ("Probes requested" to "请求探测数"),
            "resolvedAddress" to ("Resolved address" to "解析地址"),
            "resolvedAddresses" to ("Resolved addresses" to "解析地址"),
            "remoteAddress" to ("Remote address" to "远端地址"),
            "localAddress" to ("Local address" to "本地地址"), "localPort" to ("Local port" to "本地端口"),
            "family" to ("Address family" to "地址类型"),
            "attempts" to ("Connection attempts" to "连接尝试"), "refused" to ("Refused" to "已拒绝"),
            "connectTimeMs" to ("Connection (ms)" to "连接（毫秒）"),
            "timeoutBudgetMs" to ("Timeout budget (ms)" to "超时预算（毫秒）"),
            "probeIntervalMs" to ("Probe interval (ms)" to "探测间隔（毫秒）"),
            "socketType" to ("Socket type" to "套接字类型"), "probes" to ("Probes" to "探测记录"),
            "sequence" to ("Sequence" to "序号"), "replied" to ("Replied" to "已响应"),
            "contentType" to ("Content type" to "内容类型"),
            "stoppedReason" to ("Stopped reason" to "停止原因"),
            "bodyRead" to ("Body read" to "读取正文"),
            "ttlSupported" to ("TTL supported" to "支持 TTL"),
            "queryTypes" to ("Query types" to "查询类型"),
            "queryFailures" to ("Query failures" to "查询失败"),
            "address" to ("Address" to "地址"),
            "host" to ("Host" to "主机"), "port" to ("Port" to "端口"), "connected" to ("Connected" to "已连接"),
            // G07.2 LAN/speed summaries.
            "scope" to ("Discovery scope" to "发现范围"),
            "networkScoped" to ("Network scoped" to "已限定网络"),
            "discoveryDurationMs" to ("Discovery time (ms)" to "发现时长（毫秒）"),
            "serviceCount" to ("Services found" to "发现的服务"),
            "activeServiceCount" to ("Active services" to "活跃服务"),
            "unresolvedCount" to ("Unresolved services" to "未解析服务"),
            "lostCount" to ("Lost services" to "已丢失服务"),
            "filteredForeignNetwork" to ("Excluded on other networks" to "其他网络已排除"),
            "noReplies" to ("No replies" to "无响应"),
            "hostCount" to ("Hosts" to "主机数"),
            "plannedAttempts" to ("Planned attempts" to "计划尝试"),
            "completedAttempts" to ("Completed attempts" to "已完成尝试"),
            "openPortCount" to ("Open ports" to "开放端口数"),
            "hostsWithResponse" to ("Hosts with a response" to "有响应的主机"),
            "hostsWithOpenPort" to ("Hosts with an open port" to "有开放端口的主机"),
            "refusedAttempts" to ("Refused attempts" to "已拒绝尝试"),
            "timedOutAttempts" to ("Timed-out attempts" to "超时尝试"),
            "errorAttempts" to ("Failed attempts" to "失败尝试"),
            "unreachableAttempts" to ("Unreachable attempts" to "不可达尝试"),
            "excludedSelfAddresses" to ("Excluded device addresses" to "已排除的本机地址"),
            "subnetCidr" to ("Subnet" to "子网"),
            "cancelled" to ("Cancelled" to "已取消"),
            "reason" to ("Reason" to "原因"),
            "direction" to ("Direction" to "方向"),
            "maxBytesPerDirection" to ("Data cap per direction (bytes)" to "每个方向数据上限（字节）"),
            "durationBudgetMs" to ("Time budget (ms)" to "时间预算（毫秒）"),
            "warmupBytes" to ("Warm-up bytes" to "预热字节"),
            "timeoutMs" to ("Overall timeout (ms)" to "总超时（毫秒）"),
            "allowMetered" to ("Metered allowed" to "允许按流量计费"),
            "singleTransfer" to ("Single transfer" to "单次传输"),
            "sampleAdequate" to ("Sample adequate" to "样本足够"),
            "networkChanged" to ("Network changed" to "网络已变化"),
            "errorCode" to ("Error code" to "错误代码"),
            "message" to ("Message" to "消息"),
            // Per-direction speed facts (Details only; the page renders the
            // structured transfer rows).
            "status" to ("Status" to "状态"),
            "endpoint" to ("Endpoint" to "地址"),
            "payloadBytes" to ("Payload bytes" to "负载字节"),
            "measuredBytes" to ("Measured bytes" to "测量字节"),
            "measurementElapsedMs" to ("Measurement interval (ms)" to "测量区间（毫秒）"),
            "totalElapsedMs" to ("Total time (ms)" to "总耗时（毫秒）"),
            "bitsPerSecond" to ("Rate (bit/s)" to "速率（bit/s）"),
            "rateAvailable" to ("Rate available" to "速率可用"),
            "rateOmittedReason" to ("Rate omitted" to "未计算速率原因"),
            "completionReason" to ("Completion reason" to "结束原因"),
            "contentComplete" to ("Payload complete" to "负载已完成"),
            "clientStopped" to ("Stopped by client" to "客户端已停止"),
            "payloadBytesMeaning" to ("Byte meaning" to "字节含义"),
            "httpStatus" to ("HTTP status" to "HTTP 状态"),
            "contentLength" to ("Reported length" to "声明的长度"),
            "contentEncoding" to ("Content encoding" to "内容编码"),
            "requestContentLength" to ("Request length" to "请求长度"),
            "responseBytesRead" to ("Response bytes read" to "已读取响应字节"),
            "tlsProtocol" to ("TLS protocol" to "TLS 协议"),
            "configured" to ("Configured" to "已配置"),
            "used" to ("Used" to "已使用"),
            "requestHeadersMs" to ("Request headers (ms)" to "请求头（毫秒）"),
        )
        val entry = labels[key]
        return entry?.let { if (zh) it.second else it.first }
    }
}
