// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.reporting

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.util.AtomicFile
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.floe.android.BuildConfig
import com.floe.android.FloeApplication
import com.floe.android.R
import com.floe.android.host.entryflow.C07EntryRedactor
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import java.util.Locale
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

internal data class DiagnosticReportRow(val id: String, val kind: String, val state: String,
    val reportID: String?, val errorCode: String?, val attachments: Int,
    val transferred: Long = 0, val transferTotal: Long = 0, val uploading: Boolean = false)
internal data class DiagnosticReportingState(val automatic: Boolean = false,
    val reports: List<DiagnosticReportRow> = emptyList())

/** Consent and transport owner, independent of task execution. Never accepts task exception events. */
internal class DiagnosticReportService(private val context: Context) {
    private val preferences = context.getSharedPreferences("diagnostic_reporting", Context.MODE_PRIVATE)
    private val root = File(context.noBackupFilesDir, "DiagnosticReports")
    private val gate = Any()
    private val uploadLanes = ReportUploadLanes()
    private val transfers = HashMap<String, Pair<Long, Long>>()
    private val transport = ReportUploadTransport()
    private val mutable = MutableStateFlow(DiagnosticReportingState())
    val state = mutable.asStateFlow()
    private var attached = false

    fun attach() {
        if (attached) return
        attached = true
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            if (error !is CancellationException && preferences.getBoolean("automatic", false)) {
                runCatching { recordFault("process_crash", error, enqueue = false) }
            }
            previous?.uncaughtException(thread, error)
        }
        refresh()
        if (preferences.getBoolean("automatic", false)) runCatching { collectPreviousExit() }
        if (state.value.reports.any { it.state == "queued" }) enqueue()
    }

    fun setAutomatic(allowed: Boolean) {
        preferences.edit().putBoolean("automatic", allowed)
            .putLong("consent_at", if (allowed) System.currentTimeMillis() else 0).commit()
        if (!allowed) synchronized(gate) {
            records().filter { it.optString("kind") != "manual" && it.optString("state") != "sent" }
                .forEach(::removeRecord)
        }
        refresh()
    }

    /** Call only for App faults, never provider/tool/task failures or normal cancellation. */
    fun recordAppFault(code: String, error: Throwable) {
        if (!code.matches(Regex("[a-z_]{1,48}")) || error is CancellationException ||
            !preferences.getBoolean("automatic", false)) return
        recordFault(code, error, enqueue = true)
    }

    private fun recordFault(code: String, error: Throwable, enqueue: Boolean) {
        val frames = error.stackTrace.take(20).joinToString("\n") {
            "${it.className}.${it.methodName}:${it.lineNumber}"
        }
        // Throwable messages/locals may contain prompts, paths or API bodies. Exclude them entirely.
        val signature = "${error.javaClass.name}\n$frames"
        val fingerprint = sha256(signature.toByteArray())
        synchronized(gate) {
            if (records().any { it.optString("fingerprint") == fingerprint &&
                    System.currentTimeMillis() - it.optLong("created") < 3_600_000 }) return
            val report = newRecord("app_fault", "$code\n$signature", emptyList(), false)
            report.put("fingerprint", fingerprint)
            save(report)
        }
        refresh()
        if (enqueue) enqueue()
    }

    private fun collectPreviousExit() {
        if (Build.VERSION.SDK_INT < 30) return
        val consentAt = preferences.getLong("consent_at", Long.MAX_VALUE)
        val lastSeen = preferences.getLong("exit_seen", 0)
        val exits = context.getSystemService(ActivityManager::class.java)
            .getHistoricalProcessExitReasons(context.packageName, 0, 4)
        for (exit in exits.sortedBy { it.timestamp }) {
            if (exit.timestamp < consentAt || exit.timestamp <= lastSeen) continue
            if (exit.reason !in setOf(ApplicationExitInfo.REASON_CRASH,
                    ApplicationExitInfo.REASON_CRASH_NATIVE, ApplicationExitInfo.REASON_ANR)) continue
            val row = newRecord("app_fault", "process_exit reason=${exit.reason} sdk=${Build.VERSION.SDK_INT}", emptyList(), false)
            row.put("id", UUID.nameUUIDFromBytes("exit:${exit.pid}:${exit.timestamp}".toByteArray()).toString())
            synchronized(gate) { if (!file(row.getString("id")).exists()) save(row) }
        }
        preferences.edit().putLong("exit_seen", exits.maxOfOrNull { it.timestamp } ?: lastSeen).apply()
        refresh()
    }

    suspend fun submitManual(problem: String, screenshots: List<Uri>, allowAttachmentsOnAnyNetwork: Boolean): String =
        withContext(Dispatchers.IO) {
            require((problem.isNotBlank() || screenshots.isNotEmpty()) && screenshots.size <= 4)
            val id = UUID.randomUUID().toString()
            val images = ArrayList<File>()
            try {
                root.mkdirs()
                screenshots.forEachIndexed { index, uri ->
                    images += importScreenshot(uri, File(root, "$id-$index.jpg"), ReportScreenshot.attachmentBudget(screenshots.size))
                }
                val description = problem.takeIf { it.isNotBlank() }
                    ?: context.getString(R.string.reporting_screenshot_feedback, images.size)
                val row = newRecord("manual", C07EntryRedactor.redact(description.take(8_000)), images,
                    allowAttachmentsOnAnyNetwork).put("id", id)
                synchronized(gate) { save(row) }
                refresh(); enqueue(); id
            } catch (error: Exception) { images.forEach { it.delete() }; throw error }
        }

    private fun importScreenshot(uri: Uri, destination: File, budget: Int): File {
        val source = File(root, "${UUID.randomUUID()}.import")
        val input = context.contentResolver.openInputStream(uri) ?: throw java.io.IOException("image_unreadable")
        return ReportScreenshot.prepare(input, source, destination, budget)
    }

    private fun newRecord(kind: String, message: String, images: List<File>, anyNetwork: Boolean): JSONObject {
        val id = UUID.randomUUID().toString()
        val now = System.currentTimeMillis()
        val event = JSONObject().put("client_event_id", id).put("occurred_at", Instant.ofEpochMilli(now).toString())
            .put("level", if (kind == "manual") "info" else "error")
            .put("category", if (kind == "manual") "feedback" else "app")
            .put("message", boundedText(C07EntryRedactor.redact(message), 7_000))
            .put("app_version", BuildConfig.VERSION_NAME).put("app_build", BuildConfig.VERSION_CODE.toString())
            .put("os_version", "Android ${Build.VERSION.RELEASE}").put("device_model", Build.MODEL.take(80))
            .put("metadata", JSONObject().put("platform", "android").put("kind", kind))
        return JSONObject().put("id", id).put("created", now).put("kind", kind).put("state", "queued")
            .put("any_network", anyNetwork).put("images", JSONArray(images.map { it.name }))
            .put("manifest", JSONObject().put("problem", boundedText(C07EntryRedactor.redact(message), 7_000))
                .put("locale", Locale.getDefault().toLanguageTag()).put("events", JSONArray().put(event)))
    }

    suspend fun flush(reportID: String? = null): Boolean {
        val rows = synchronized(gate) { records().filter {
            it.optString("state") == "queued" && (reportID == null || it.optString("id") == reportID)
        }.sortedBy { it.getJSONArray("images").length() > 0 } }
        for (row in rows) flushOne(row.getString("id"), row.getJSONArray("images").length() > 0)
        refresh()
        return synchronized(gate) { records().none { it.optString("state") == "queued" &&
            (reportID == null || it.optString("id") == reportID) } }
    }

    private suspend fun flushOne(id: String, hasAttachments: Boolean): Unit = uploadLanes.withPermit(hasAttachments) {
        val row = synchronized(gate) { read(id)?.takeIf { it.optString("state") == "queued" } }
            ?: return@withPermit
        if (row.getString("kind") != "manual" && !preferences.getBoolean("automatic", false)) return@withPermit
        val images = row.getJSONArray("images")
        if (images.length() > 0 && !row.optBoolean("any_network") && !onWifi()) {
            synchronized(gate) { read(row.getString("id"))?.takeIf { it.optString("state") == "queued" }
                ?.let { save(it.put("error", "waiting_wifi")) } }
            return@withPermit // A screenshot must not block later text-only reports.
        }
        val attempts = row.optInt("attempts", 0)
        val admitted = synchronized(gate) {
            val current = read(row.getString("id"))
            when {
                current == null || current.optString("state") != "queued" -> false
                row.getString("kind") != "manual" && !preferences.getBoolean("automatic", false) -> false
                attempts >= 5 -> {
                    save(row.put("state", "failed").put("error", "retry_limit"))
                    false
                }
                else -> { row.remove("error"); save(row.put("attempts", attempts + 1)); true }
            }
        }
        if (!admitted) return@withPermit
        refresh() // Clear the previous attempt's error before showing new progress.
        try {
            val receipt = withContext(Dispatchers.IO) { upload(row) }
            synchronized(gate) {
                // A concurrent opt-out/removal must not recreate a deleted report.
                if (file(row.getString("id")).exists()) {
                    row.put("state", "sent").put("report_id", receipt).remove("error")
                    save(row)
                    for (index in 0 until images.length()) File(root, images.getString(index)).delete()
                }
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: ReportReceiptRejected) {
            synchronized(gate) {
                if (file(row.getString("id")).exists())
                    save(row.put("state", "failed").put("error", "invalid_receipt"))
            }
        }
        catch (failure: ReportRejected) {
            synchronized(gate) {
                if (file(row.getString("id")).exists()) save(row.put("state", "failed").put("error", failure.code))
            }
        } catch (failure: Exception) {
            synchronized(gate) {
                if (file(row.getString("id")).exists())
                    save(row.put("state", if (attempts + 1 >= 5) "failed" else "queued")
                        .put("error", when (failure) {
                            is ReportTransportFailure -> failure.code
                            is java.net.UnknownHostException -> "network_dns"
                            is java.io.InterruptedIOException -> "network_timeout"
                            is javax.net.ssl.SSLException -> "network_tls"
                            else -> "network_connection"
                        }))
            }
        }
    }

    private fun upload(row: JSONObject): String {
        val id = row.getString("id")
        try {
            val names = row.getJSONArray("images")
            val images = (0 until names.length()).map { File(root, names.getString(it)) }
            // Previously queued reports keep their identity and images across
            // upgrades. Reduce old oversized attachments before resuming them.
            val budget = if (images.isEmpty()) ReportScreenshot.OUTPUT_LIMIT else ReportScreenshot.attachmentBudget(images.size)
            for (image in images) if (image.length() > budget) {
                val temporary = File(root, "${UUID.randomUUID()}.jpg")
                try {
                    ReportScreenshot.prepare(image.inputStream(), File(root, "${UUID.randomUUID()}.import"), temporary, budget)
                    java.nio.file.Files.move(temporary.toPath(), image.toPath(),
                        java.nio.file.StandardCopyOption.ATOMIC_MOVE, java.nio.file.StandardCopyOption.REPLACE_EXISTING)
                } finally { temporary.delete() }
            }
            val (status, data) = transport.post(ENDPOINT, row.getJSONObject("manifest").toString(), images) { bytes, total ->
                synchronized(gate) {
                    transfers[id] = bytes to total
                    mutable.value = mutable.value.copy(reports = mutable.value.reports.map {
                        if (it.id == id) it.copy(transferred = bytes, transferTotal = total, uploading = true) else it
                    })
                }
            }
            if (status == 429 || status >= 500) throw ReportTransportFailure("http_$status")
            if (status !in 200..299) throw ReportRejected(ReportResponsePolicy.rejectionCode(status, data))
            val receipt = try { JSONObject(data) } catch (_: org.json.JSONException) { throw ReportReceiptRejected() }
            val reportID = receipt.optString("report_id")
            val eventID = row.getJSONObject("manifest").getJSONArray("events").getJSONObject(0).getString("client_event_id")
            // One event is submitted per report. Fresh accepted IDs are server
            // storage IDs; duplicate IDs echo client_event_id (the server contract).
            val accepted = receipt.optJSONArray("accepted")
            val duplicates = receipt.optJSONArray("duplicates")
            val rejected = receipt.optJSONArray("rejected")
            val fresh = accepted?.length() == 1 &&
                accepted.optString(0).matches(Regex("[A-Za-z0-9_-]{8,128}"))
            val duplicate = duplicates?.let { ids ->
                (0 until ids.length()).any { ids.optString(it) == eventID }
            } == true
            if (!reportID.matches(Regex("[A-Za-z0-9_-]{8,128}")) ||
                rejected == null || rejected.length() != 0 || !(fresh || duplicate)) throw ReportReceiptRejected()
            return reportID
        } finally { synchronized(gate) { transfers.remove(id) }; refresh() }
    }

    fun retry(id: String) {
        synchronized(gate) { read(id)?.takeIf { it.optString("state") == "failed" }?.let {
            save(it.put("state", "queued").put("attempts", 0).apply { remove("error") })
        } }
        refresh(); enqueue()
    }
    fun remove(id: String) { synchronized(gate) { read(id)?.let(::removeRecord) }; refresh() }
    private fun removeRecord(row: JSONObject) {
        val images = row.optJSONArray("images") ?: JSONArray()
        for (i in 0 until images.length()) File(root, images.getString(i)).delete()
        AtomicFile(file(row.getString("id"))).delete()
    }
    private fun file(id: String): File { UUID.fromString(id); return File(root, "$id.json") }
    private fun read(id: String): JSONObject? = runCatching {
        val target = file(id)
        require(target.length() <= 65_536)
        JSONObject(AtomicFile(target).openRead().bufferedReader().use { it.readText() }).also { row ->
            require(row.getString("id") == id && row.getLong("created") > 0)
            require(row.getString("kind") in setOf("manual", "app_fault"))
            require(row.getString("state") in setOf("queued", "sent", "failed"))
            row.getJSONObject("manifest").getJSONArray("events")
            val images = row.getJSONArray("images")
            require(images.length() <= 4)
            for (index in 0 until images.length()) require(
                images.getString(index).matches(Regex("[a-f0-9-]{36}-[0-3]\\.jpg")))
        }
    }.getOrNull()
    private fun records(): List<JSONObject> = root.listFiles().orEmpty()
        .filter { it.name.endsWith(".json") }.mapNotNull { read(it.name.removeSuffix(".json")) }
        .sortedBy { it.optLong("created") }
    private fun save(row: JSONObject) {
        root.mkdirs()
        val others = records().filter { it.getString("id") != row.getString("id") }
        require(others.count { it.optString("state") != "sent" } < 20)
        if (!file(row.getString("id")).exists())
            require(root.walkTopDown().filter { it.isFile }.sumOf { it.length() } <= 24L * 1_024 * 1_024)
        others.filter { it.optString("state") == "sent" }.dropLast(49).forEach(::removeRecord)
        val atomic = AtomicFile(file(row.getString("id")))
        val stream = atomic.startWrite()
        try { stream.write(row.toString().toByteArray()); atomic.finishWrite(stream) }
        catch (error: Exception) { atomic.failWrite(stream); throw error }
    }
    private fun refresh() { synchronized(gate) {
        mutable.value = DiagnosticReportingState(preferences.getBoolean("automatic", false), records().map {
            DiagnosticReportRow(it.getString("id"), it.getString("kind"), it.getString("state"),
                it.optString("report_id").takeIf(String::isNotEmpty), it.optString("error").takeIf(String::isNotEmpty),
                it.getJSONArray("images").length(), transfers[it.getString("id")]?.first ?: 0,
                transfers[it.getString("id")]?.second ?: 0, transfers.containsKey(it.getString("id")))
        })
    } }
    private fun onWifi(): Boolean {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        return manager.getNetworkCapabilities(manager.activeNetwork)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
    }
    private fun enqueue() {
        // Each report owns its retry. A waiting Wi-Fi attachment or an older
        // retry backoff must not delay newly submitted text feedback.
        val rows = synchronized(gate) { records().filter { it.optString("state") == "queued" } }
        val work = WorkManager.getInstance(context)
        for (row in rows) {
            val id = row.getString("id")
            work.enqueueUniqueWork("floe.diagnostics.upload.$id", ExistingWorkPolicy.KEEP,
                OneTimeWorkRequestBuilder<DiagnosticReportWorker>().setInputData(workDataOf("report_id" to id))
                    .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS).build())
        }
    }
    private class ReportTransportFailure(val code: String) : java.io.IOException()
    private class ReportReceiptRejected : Exception()
    private class ReportRejected(val code: String) : Exception()
    companion object {
        private const val ENDPOINT = "https://www.floe-agent.com/api/v1/public/reports"
        private fun boundedText(value: String, maxBytes: Int): String {
            var size = 0
            val result = StringBuilder()
            val points = value.codePoints().iterator()
            while (points.hasNext()) {
                val point = points.nextInt()
                val chars = String(Character.toChars(point))
                val count = chars.toByteArray(Charsets.UTF_8).size
                if (size + count > maxBytes) break
                result.append(chars); size += count
            }
            return result.toString()
        }
        private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}

class DiagnosticReportWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val reporter = (applicationContext as? FloeApplication)?.diagnosticReporter ?: return Result.failure()
        return if (reporter.flush(inputData.getString("report_id"))) Result.success() else Result.retry()
    }
}
