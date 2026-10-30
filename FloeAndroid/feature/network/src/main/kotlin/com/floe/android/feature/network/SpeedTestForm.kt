// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.network

import java.net.URI

enum class SpeedTestDirection(
    val wire: String,
    val includesDownload: Boolean,
    val includesUpload: Boolean,
) {
    DOWNLOAD("download", true, false),
    UPLOAD("upload", false, true),
    BOTH("downloadAndUpload", true, true);

    val count: Int get() = (if (includesDownload) 1 else 0) + (if (includesUpload) 1 else 0)
}

enum class SpeedTestValidationError {
    DOWNLOAD_URL_REQUIRED,
    UPLOAD_URL_REQUIRED,
    URL_INVALID,
    BYTE_CAP,
    DURATION,
    DURATION_BOTH,
}

/** A validated `network.speedTest` request. Endpoints are always user supplied. */
data class SpeedTestInput(
    val direction: SpeedTestDirection = SpeedTestDirection.DOWNLOAD,
    val downloadUrl: String? = null,
    val uploadUrl: String? = null,
    val maxBytesPerDirection: Int = 8 * 1024 * 1024,
    val durationBudgetMs: Int = 10_000,
    val allowMetered: Boolean = false,
) {
    /** Per-direction budget plus the service's fixed connection margin. */
    val timeoutMs: Int get() = durationBudgetMs * direction.count + 1_500

    fun problems(): List<SpeedTestValidationError> {
        val errors = LinkedHashSet<SpeedTestValidationError>()
        if (direction.includesDownload) {
            if (downloadUrl.isNullOrBlank()) errors += SpeedTestValidationError.DOWNLOAD_URL_REQUIRED
            else if (SpeedTestPolicy.parseHttpsEndpoint(downloadUrl) == null) {
                errors += SpeedTestValidationError.URL_INVALID
            }
        }
        if (direction.includesUpload) {
            if (uploadUrl.isNullOrBlank()) errors += SpeedTestValidationError.UPLOAD_URL_REQUIRED
            else if (SpeedTestPolicy.parseHttpsEndpoint(uploadUrl) == null) {
                errors += SpeedTestValidationError.URL_INVALID
            }
        }
        if (maxBytesPerDirection !in 65_536..33_554_432) errors += SpeedTestValidationError.BYTE_CAP
        if (durationBudgetMs !in 1_000..15_000) {
            errors += SpeedTestValidationError.DURATION
        } else if (timeoutMs > SpeedTestPolicy.MAX_OVERALL_TIMEOUT_MS) {
            errors += SpeedTestValidationError.DURATION_BOTH
        }
        return errors.toList()
    }
}

/** Raw, saveable speed form fields exactly as the user typed them. */
data class SpeedTestFormValues(
    val direction: SpeedTestDirection = SpeedTestDirection.DOWNLOAD,
    val downloadUrl: String = "",
    val uploadUrl: String = "",
    val maxMiB: String = "8",
    val durationSeconds: String = "10",
    val allowMetered: Boolean = false,
)

data class SpeedTestFormResult(
    val input: SpeedTestInput? = null,
    val errors: List<SpeedTestValidationError> = emptyList(),
)

/**
 * Pure input policy for the speed page. It never creates a default endpoint:
 * a request is built only from explicit HTTPS URLs and integer bounds the user
 * can see. The service revalidates the same frozen limits.
 */
object SpeedTestPolicy {
    const val MAX_OVERALL_TIMEOUT_MS = 30_000
    const val MIN_BYTES = 65_536
    const val MAX_BYTES = 33_554_432
    const val MIN_DURATION_MS = 1_000
    const val MAX_DURATION_MS = 15_000
    const val CONNECTION_MARGIN_MS = 1_500

    fun parse(values: SpeedTestFormValues): SpeedTestFormResult {
        val errors = LinkedHashSet<SpeedTestValidationError>()
        val direction = values.direction
        val download = parseHttpsEndpoint(values.downloadUrl)
        val upload = parseHttpsEndpoint(values.uploadUrl)

        if (direction.includesDownload) {
            if (values.downloadUrl.isBlank()) {
                errors += SpeedTestValidationError.DOWNLOAD_URL_REQUIRED
            } else if (download == null) {
                errors += SpeedTestValidationError.URL_INVALID
            }
        }
        if (direction.includesUpload) {
            if (values.uploadUrl.isBlank()) {
                errors += SpeedTestValidationError.UPLOAD_URL_REQUIRED
            } else if (upload == null) {
                errors += SpeedTestValidationError.URL_INVALID
            }
        }

        val mib = values.maxMiB.trim().toIntOrNull()
        if (mib == null || mib !in 1..32) errors += SpeedTestValidationError.BYTE_CAP
        val seconds = values.durationSeconds.trim().toIntOrNull()
        if (seconds == null || seconds !in 1..15) {
            errors += SpeedTestValidationError.DURATION
        } else if (direction.count * seconds * 1_000 + CONNECTION_MARGIN_MS > MAX_OVERALL_TIMEOUT_MS) {
            errors += SpeedTestValidationError.DURATION_BOTH
        }

        if (errors.isNotEmpty()) return SpeedTestFormResult(errors = errors.toList())
        return SpeedTestFormResult(
            input = SpeedTestInput(
                direction = direction,
                downloadUrl = if (direction.includesDownload) download else null,
                uploadUrl = if (direction.includesUpload) upload else null,
                maxBytesPerDirection = requireNotNull(mib) * 1024 * 1024,
                durationBudgetMs = requireNotNull(seconds) * 1_000,
                allowMetered = values.allowMetered,
            ),
        )
    }

    /**
     * A full absolute HTTPS URL with a host and no userinfo. It deliberately
     * does not invent a scheme, host or path and does not rewrite the value.
     */
    fun parseHttpsEndpoint(raw: String): String? {
        val value = raw.trim()
        if (value.isEmpty() || value.length > 4_096) return null
        val uri = try {
            URI(value)
        } catch (_: Exception) {
            return null
        }
        if (!uri.scheme.equals("https", ignoreCase = true)) return null
        if (uri.rawUserInfo != null) return null
        if (uri.host.isNullOrBlank()) return null
        return value
    }
}
