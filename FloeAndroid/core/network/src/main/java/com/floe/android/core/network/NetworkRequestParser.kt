// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.util.UUID
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

internal data class ParsedRequest(
    val operationID: String,
    val method: NetworkMethod,
    val timeoutMs: Int,
    val host: String? = null,
    val recordType: DnsRecordType = DnsRecordType.A_AND_AAAA,
    val count: Int = 4,
    val port: Int? = null,
    val httpTarget: HttpTarget? = null,
    val maxRedirects: Int = 5,
    val refresh: Boolean = false,
    val lan: LanDiscoveryRequest? = null,
    val speed: SpeedTestRequest? = null,
) {
    val target: String? get() = when (method) {
        NetworkMethod.DNS_LOOKUP, NetworkMethod.PING, NetworkMethod.TCP_PROBE -> host
        NetworkMethod.HTTP -> httpTarget?.redacted
        NetworkMethod.LAN_DISCOVER -> lan?.let { discovery ->
            discovery.subnet?.let { "lan:${it.cidr}" } ?: "lan:mdns"
        }
        NetworkMethod.SPEED_TEST -> speed?.let { test ->
            test.downloadTarget?.redacted ?: test.uploadTarget?.redacted
        }
        NetworkMethod.STATUS, NetworkMethod.WIFI_SCAN -> null
    }
}

internal class RequestParseException(
    val code: String,
    message: String,
    val operationID: String? = null,
    val methodWire: String? = null,
) : Exception(message)

/** Strict, bounded NetworkObservationV1 request parser. */
internal object NetworkRequestParser {
    fun parse(requestJson: String): ParsedRequest {
        val bytes = requestJson.toByteArray(Charsets.UTF_8)
        if (bytes.size > NetworkLimits.MAX_REQUEST_BYTES) {
            throw RequestParseException(
                "requestTooLarge",
                "request exceeds the 16 KiB diagnostic bound",
            )
        }
        val root = try {
            JSONObject(requestJson)
        } catch (_: JSONException) {
            throw RequestParseException("invalidRequest", "request is not a valid JSON object")
        }

        val operationID = (root.opt("operationID") as? String)
            ?.takeIf { it.isNotEmpty() && it.length <= NetworkLimits.MAX_IDENTIFIER_CHARS }
            ?: throw RequestParseException("invalidOperationID", "operationID must be a UUID string")
        try {
            UUID.fromString(operationID)
        } catch (_: IllegalArgumentException) {
            throw RequestParseException("invalidOperationID", "operationID must be a UUID string")
        }

        val methodWire = (root.opt("method") as? String)
            ?: throw RequestParseException("unsupportedMethod", "method is required", operationID)
        val method = NetworkMethod.fromWire(methodWire)
            ?: throw RequestParseException("unsupportedMethod", "unsupported network method", operationID, methodWire)

        val version = if (root.has("version") && !root.isNull("version")) {
            (root.opt("version") as? Number)?.toInt()
        } else {
            null
        }
        if (version != NetworkLimits.VERSION) {
            throw RequestParseException("unsupportedVersion", "version must be 1", operationID, methodWire)
        }

        val arguments = when {
            !root.has("arguments") || root.isNull("arguments") -> JSONObject()
            else -> root.opt("arguments") as? JSONObject
                ?: throw RequestParseException("invalidArguments", "arguments must be an object", operationID, methodWire)
        }

        return try {
            when (method) {
                NetworkMethod.STATUS -> ParsedRequest(
                    operationID = operationID,
                    method = method,
                    timeoutMs = NetworkLimits.DEFAULT_STATUS_TIMEOUT_MS,
                )
                NetworkMethod.WIFI_SCAN -> ParsedRequest(
                    operationID = operationID,
                    method = method,
                    timeoutMs = NetworkLimits.DEFAULT_WIFI_TIMEOUT_MS,
                    refresh = boolArgument(arguments, "refresh", false),
                )
                NetworkMethod.DNS_LOOKUP -> {
                    val host = hostArgument(arguments)
                    ParsedRequest(
                        operationID = operationID,
                        method = method,
                        timeoutMs = timeoutArgument(arguments, NetworkLimits.DEFAULT_DNS_TIMEOUT_MS),
                        host = host,
                        recordType = recordTypeArgument(arguments),
                    )
                }
                NetworkMethod.PING -> {
                    val host = hostArgument(arguments)
                    ParsedRequest(
                        operationID = operationID,
                        method = method,
                        timeoutMs = timeoutArgument(arguments, NetworkLimits.DEFAULT_PING_TIMEOUT_MS),
                        host = host,
                        count = intArgument(
                            arguments,
                            "count",
                            default = 4,
                            minimum = 1,
                            maximum = NetworkLimits.MAX_PING_COUNT,
                        ) ?: 4,
                    )
                }
                NetworkMethod.TCP_PROBE -> {
                    val host = hostArgument(arguments)
                    val port = intArgument(
                        arguments,
                        "port",
                        default = null,
                        minimum = 1,
                        maximum = 65_535,
                    ) ?: throw RequestParseException("invalidArguments", "port is required", operationID, methodWire)
                    ParsedRequest(
                        operationID = operationID,
                        method = method,
                        timeoutMs = timeoutArgument(arguments, NetworkLimits.DEFAULT_TCP_TIMEOUT_MS),
                        host = host,
                        port = port,
                    )
                }
                NetworkMethod.HTTP -> {
                    val rawUrl = stringArgument(arguments, "url")
                    val target = try {
                        NetworkTargetPolicy.parseHttpTarget(rawUrl)
                    } catch (failure: TargetSyntaxException) {
                        throw RequestParseException(
                            "invalidTarget",
                            failure.message ?: "invalid URL",
                            operationID,
                            methodWire,
                        )
                    }
                    ParsedRequest(
                        operationID = operationID,
                        method = method,
                        timeoutMs = timeoutArgument(arguments, NetworkLimits.DEFAULT_HTTP_TIMEOUT_MS),
                        httpTarget = target,
                        maxRedirects = intArgument(
                            arguments,
                            "maxRedirects",
                            default = 5,
                            minimum = 0,
                            maximum = NetworkLimits.MAX_REDIRECTS,
                        ) ?: 5,
                    )
                }
                NetworkMethod.LAN_DISCOVER -> {
                    val serviceTypes = stringArrayArgument(
                        arguments,
                        "serviceTypes",
                        NetworkLimits.MAX_LAN_SERVICE_TYPES,
                    ).map { raw -> LanDiscoveryResult.normalizeServiceType(raw) }
                    if (serviceTypes.distinct().size != serviceTypes.size) {
                        throw RequestParseException(
                            "invalidArguments",
                            "serviceTypes must be unique",
                            operationID,
                            methodWire,
                        )
                    }
                    val subnet = optionalStringArgument(arguments, "subnetCidr")
                        ?.let { raw -> LanDiscoveryResult.parsePrivateSubnet(raw) }
                    val ports = if (subnet != null) {
                        intArrayArgument(
                            arguments,
                            "ports",
                            maxEntries = NetworkLimits.MAX_TCP_PORTS,
                            minimum = 1,
                            maximumValue = 65_535,
                        )
                    } else {
                        if (arguments.has("ports") && !arguments.isNull("ports")) {
                            throw RequestParseException(
                                "invalidArguments",
                                "ports require subnetCidr",
                                operationID,
                                methodWire,
                            )
                        }
                        emptyList()
                    }
                    if (serviceTypes.isEmpty() && subnet == null) {
                        throw RequestParseException(
                            "invalidArguments",
                            "serviceTypes or subnetCidr is required",
                            operationID,
                            methodWire,
                        )
                    }
                    if (subnet != null) LanDiscoveryResult.checkAttemptBudget(subnet, ports)
                    val discoveryDurationMs = intArgument(
                        arguments,
                        "discoveryDurationMs",
                        default = NetworkLimits.DEFAULT_LAN_DISCOVERY_MS,
                        minimum = NetworkLimits.MIN_LAN_DISCOVERY_MS,
                        maximum = NetworkLimits.MAX_LAN_DISCOVERY_MS,
                    ) ?: NetworkLimits.DEFAULT_LAN_DISCOVERY_MS
                    val timeoutMs = timeoutArgument(arguments, NetworkLimits.DEFAULT_LAN_TIMEOUT_MS)
                    val requiredTimeout = when {
                        subnet != null && serviceTypes.isNotEmpty() -> discoveryDurationMs + 2_000
                        subnet != null -> 2_000
                        else -> discoveryDurationMs + 1_000
                    }
                    if (timeoutMs < requiredTimeout) {
                        throw RequestParseException(
                            "invalidArguments",
                            "timeoutMs must be at least $requiredTimeout for this LAN discovery",
                            operationID,
                            methodWire,
                        )
                    }
                    ParsedRequest(
                        operationID = operationID,
                        method = method,
                        timeoutMs = timeoutMs,
                        lan = LanDiscoveryRequest(
                            serviceTypes = serviceTypes,
                            discoveryDurationMs = discoveryDurationMs,
                            includeAttributes = boolArgument(arguments, "includeAttributes", false),
                            subnet = subnet,
                            ports = ports,
                            tcpConnectTimeoutMs = intArgument(
                                arguments,
                                "tcpConnectTimeoutMs",
                                default = NetworkLimits.DEFAULT_TCP_CONNECT_TIMEOUT_MS,
                                minimum = NetworkLimits.MIN_TCP_CONNECT_TIMEOUT_MS,
                                maximum = NetworkLimits.MAX_TCP_CONNECT_TIMEOUT_MS,
                            ) ?: NetworkLimits.DEFAULT_TCP_CONNECT_TIMEOUT_MS,
                            tcpConcurrency = intArgument(
                                arguments,
                                "tcpConcurrency",
                                default = NetworkLimits.DEFAULT_TCP_CONCURRENCY,
                                minimum = 1,
                                maximum = NetworkLimits.MAX_TCP_CONCURRENCY,
                            ) ?: NetworkLimits.DEFAULT_TCP_CONCURRENCY,
                            timeoutMs = timeoutMs,
                        ),
                    )
                }
                NetworkMethod.SPEED_TEST -> {
                    val direction = SpeedDirection.fromWire(
                        optionalStringArgument(arguments, "direction") ?: "download",
                    ) ?: throw RequestParseException(
                        "invalidArguments",
                        "direction must be download, upload or downloadAndUpload",
                        operationID,
                        methodWire,
                    )
                    val downloadTarget = optionalStringArgument(arguments, "downloadUrl")
                        ?.let { raw -> parseTarget(raw, operationID, methodWire) }
                    val uploadTarget = optionalStringArgument(arguments, "uploadUrl")
                        ?.let { raw -> parseTarget(raw, operationID, methodWire) }
                    if (direction.includesDownload && downloadTarget == null) {
                        throw RequestParseException(
                            "invalidArguments",
                            "downloadUrl is required for this direction",
                            operationID,
                            methodWire,
                        )
                    }
                    if (direction.includesUpload && uploadTarget == null) {
                        throw RequestParseException(
                            "invalidArguments",
                            "uploadUrl is required for this direction",
                            operationID,
                            methodWire,
                        )
                    }
                    val maxBytes = strictIntArgument(
                        arguments,
                        "maxBytesPerDirection",
                        NetworkLimits.DEFAULT_SPEED_BYTES,
                        NetworkLimits.MIN_SPEED_BYTES,
                        NetworkLimits.MAX_SPEED_BYTES,
                    )
                    val durationBudgetMs = strictIntArgument(
                        arguments,
                        "durationBudgetMs",
                        NetworkLimits.DEFAULT_SPEED_DURATION_MS,
                        NetworkLimits.MIN_SPEED_DURATION_MS,
                        NetworkLimits.MAX_SPEED_DURATION_MS,
                    )
                    val warmupBytes = strictIntArgument(
                        arguments,
                        "warmupBytes",
                        0,
                        0,
                        NetworkLimits.MAX_SPEED_WARMUP_BYTES,
                    )
                    if (warmupBytes >= maxBytes) {
                        throw RequestParseException(
                            "invalidArguments",
                            "warmupBytes must be less than maxBytesPerDirection",
                            operationID,
                            methodWire,
                        )
                    }
                    val timeoutMs = timeoutArgument(arguments, NetworkLimits.DEFAULT_SPEED_TIMEOUT_MS)
                    val requiredTimeout = durationBudgetMs * direction.count +
                        NetworkLimits.SPEED_CONNECTION_MARGIN_MS
                    if (timeoutMs < requiredTimeout) {
                        throw RequestParseException(
                            "invalidArguments",
                            "timeoutMs must be at least $requiredTimeout for these speed budgets",
                            operationID,
                            methodWire,
                        )
                    }
                    ParsedRequest(
                        operationID = operationID,
                        method = method,
                        timeoutMs = timeoutMs,
                        speed = SpeedTestRequest(
                            direction = direction,
                            downloadTarget = downloadTarget,
                            uploadTarget = uploadTarget,
                            maxBytesPerDirection = maxBytes,
                            durationBudgetMs = durationBudgetMs,
                            warmupBytes = warmupBytes,
                            allowMetered = boolArgument(arguments, "allowMetered", false),
                            timeoutMs = timeoutMs,
                        ),
                    )
                }
            }
        } catch (failure: RequestParseException) {
            throw failure
        } catch (failure: Exception) {
            throw RequestParseException(
                "invalidArguments",
                failure.message ?: "arguments are invalid",
                operationID,
                methodWire,
            )
        }
    }

    private fun hostArgument(arguments: JSONObject): String {
        val raw = stringArgument(arguments, "host")
        return try {
            NetworkTargetPolicy.validateHostSyntax(raw)
        } catch (failure: TargetSyntaxException) {
            throw RequestParseException("invalidTarget", failure.message ?: "invalid target host")
        }
    }

    private fun recordTypeArgument(arguments: JSONObject): DnsRecordType {
        if (!arguments.has("recordType") || arguments.isNull("recordType")) {
            return DnsRecordType.A_AND_AAAA
        }
        val raw = arguments.opt("recordType") as? String
            ?: throw RequestParseException("invalidArguments", "recordType must be a string")
        return DnsRecordType.fromWire(raw)
            ?: throw RequestParseException("invalidArguments", "recordType must be A, AAAA or A_AND_AAAA")
    }

    private fun timeoutArgument(arguments: JSONObject, default: Int): Int =
        intArgument(
            arguments,
            "timeoutMs",
            default = default,
            minimum = NetworkLimits.MIN_TIMEOUT_MS,
            maximum = NetworkLimits.MAX_TIMEOUT_MS,
        ) ?: default

    private fun intArgument(
        arguments: JSONObject,
        name: String,
        default: Int?,
        minimum: Int,
        maximum: Int,
    ): Int? {
        if (!arguments.has(name) || arguments.isNull(name)) return default
        val raw = arguments.opt(name)
        val value = when (raw) {
            is Int -> raw
            is Long -> if (raw in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) raw.toInt() else {
                throw RequestParseException("invalidArguments", "$name is outside the supported integer range")
            }
            else -> throw RequestParseException("invalidArguments", "$name must be an integer")
        }
        if (value < minimum || value > maximum) {
            // Timing/count limits are clamped by contract; correctness fields
            // (TCP port) still need an exact valid value.
            if (name == "port") {
                throw RequestParseException("invalidArguments", "port must be between 1 and 65535")
            }
            return value.coerceIn(minimum, maximum)
        }
        return value
    }

    private fun boolArgument(arguments: JSONObject, name: String, default: Boolean): Boolean {
        if (!arguments.has(name) || arguments.isNull(name)) return default
        return arguments.opt(name) as? Boolean
            ?: throw RequestParseException("invalidArguments", "$name must be a boolean")
    }

    private fun stringArgument(arguments: JSONObject, name: String): String {
        val raw = arguments.opt(name) as? String
            ?: throw RequestParseException("invalidArguments", "$name must be a string")
        val value = raw.trim()
        if (value.isEmpty()) throw RequestParseException("invalidArguments", "$name must not be empty")
        return value
    }

    private fun optionalStringArgument(arguments: JSONObject, name: String): String? {
        if (!arguments.has(name) || arguments.isNull(name)) return null
        val raw = arguments.opt(name) as? String
            ?: throw RequestParseException("invalidArguments", "$name must be a string")
        val value = raw.trim()
        if (value.isEmpty()) throw RequestParseException("invalidArguments", "$name must not be empty")
        return value
    }

    private fun parseTarget(raw: String, operationID: String, methodWire: String): HttpTarget = try {
        NetworkTargetPolicy.parseHttpTarget(raw)
    } catch (failure: TargetSyntaxException) {
        throw RequestParseException(
            "invalidTarget",
            failure.message ?: "invalid URL",
            operationID,
            methodWire,
        )
    }

    private fun stringArrayArgument(
        arguments: JSONObject,
        name: String,
        maximum: Int,
    ): List<String> {
        if (!arguments.has(name) || arguments.isNull(name)) return emptyList()
        val array = arguments.opt(name) as? JSONArray
            ?: throw RequestParseException("invalidArguments", "$name must be an array")
        if (array.length() > maximum) {
            throw RequestParseException("invalidArguments", "$name must contain at most $maximum entries")
        }
        val values = ArrayList<String>(array.length())
        for (index in 0 until array.length()) {
            val raw = array.opt(index) as? String
                ?: throw RequestParseException("invalidArguments", "$name must contain strings")
            val value = raw.trim()
            if (value.isEmpty() || value.length > 256) {
                throw RequestParseException("invalidArguments", "$name contains an invalid entry")
            }
            values += value
        }
        return values
    }

    private fun intArrayArgument(
        arguments: JSONObject,
        name: String,
        maxEntries: Int,
        minimum: Int,
        maximumValue: Int,
    ): List<Int> {
        if (!arguments.has(name) || arguments.isNull(name)) return emptyList()
        val array = arguments.opt(name) as? JSONArray
            ?: throw RequestParseException("invalidArguments", "$name must be an array")
        if (array.length() > maxEntries) {
            throw RequestParseException("invalidArguments", "$name must contain at most $maxEntries entries")
        }
        val values = ArrayList<Int>(array.length())
        for (index in 0 until array.length()) {
            val raw = array.opt(index)
            val value = when (raw) {
                is Int -> raw
                is Long -> if (raw in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) {
                    raw.toInt()
                } else {
                    throw RequestParseException("invalidArguments", "$name contains an out-of-range integer")
                }
                else -> throw RequestParseException("invalidArguments", "$name must contain integers")
            }
            if (value < minimum || value > maximumValue) {
                throw RequestParseException(
                    "invalidArguments",
                    "$name entries must be between $minimum and $maximumValue",
                )
            }
            values += value
        }
        return values
    }

    private fun strictIntArgument(
        arguments: JSONObject,
        name: String,
        default: Int,
        minimum: Int,
        maximum: Int,
    ): Int {
        if (!arguments.has(name) || arguments.isNull(name)) return default
        val raw = arguments.opt(name)
        val value = when (raw) {
            is Int -> raw
            is Long -> if (raw in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) {
                raw.toInt()
            } else {
                throw RequestParseException("invalidArguments", "$name is outside the supported integer range")
            }
            else -> throw RequestParseException("invalidArguments", "$name must be an integer")
        }
        if (value < minimum || value > maximum) {
            throw RequestParseException(
                "invalidArguments",
                "$name must be between $minimum and $maximum",
            )
        }
        return value
    }
}
