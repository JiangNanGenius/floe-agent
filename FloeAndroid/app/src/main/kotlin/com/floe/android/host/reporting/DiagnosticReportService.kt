// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.reporting

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
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
import com.floe.android.BuildConfig
import com.floe.android.FloeApplication
import com.floe.android.host.entryflow.C07EntryRedactor
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.time.Instant
import java.util.Locale
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

internal data class DiagnosticReportRow(val id: String, val kind: String, val state: String,
    val reportID: String?, val errorCode: String?, val attachments: Int)
internal data class DiagnosticReportingState(val automatic: Boolean = false,
    val reports: List<DiagnosticReportRow> = emptyList())

/** Consent and transport owner, independent of task execution. Never accepts task exception events. */
internal class DiagnosticReportService(private val context: Context) {
    private val preferences = context.getSharedPreferences("diagnostic_reporting", Context.MODE_PRIVATE)
    private val root = File(context.noBackupFilesDir, "DiagnosticReports")
    private val gate = Any()
    private val uploadGate = Mutex()
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
            require(problem.isNotBlank() && screenshots.size <= 3)
            val id = UUID.randomUUID().toString()
            val images = ArrayList<File>()
            try {
                root.mkdirs()
                screenshots.forEachIndexed { index, uri ->
                    images += importScreenshot(uri, File(root, "$id-$index.jpg"))
                }
                val row = newRecord("manual", C07EntryRedactor.redact(problem.take(8_000)), images,
                    allowAttachmentsOnAnyNetwork).put("id", id)
                synchronized(gate) { save(row) }
                refresh(); enqueue(); id
            } catch (error: Exception) { images.forEach { it.delete() }; throw error }
        }

    private fun importScreenshot(uri: Uri, destination: File): File {
        val source = File(root, "${UUID.randomUUID()}.import")
        try {
            context.contentResolver.openInputStream(uri).use { input ->
                requireNotNull(input)
                source.outputStream().use { output ->
                    val buffer = ByteArray(32_768)
                    var size = 0
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        size += count; require(size <= 2 * 1_024 * 1_024)
                        output.write(buffer, 0, count)
                    }
                }
            }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(source.path, bounds)
            require(bounds.outWidth > 0 && bounds.outHeight > 0 &&
                bounds.outWidth.toLong() * bounds.outHeight <= 24_000_000)
            val bitmap = requireNotNull(BitmapFactory.decodeFile(source.path))
            try {
                destination.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it)) }
            } finally { bitmap.recycle() }
            require(destination.length() <= 2 * 1_024 * 1_024)
            return destination
        } catch (error: Exception) { destination.delete(); throw error }
        finally { source.delete() }
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

    suspend fun flush(): Boolean = uploadGate.withLock {
        val rows = synchronized(gate) { records().filter { it.optString("state") == "queued" } }
        for (row in rows.take(3)) {
            if (row.getString("kind") != "manual" && !preferences.getBoolean("automatic", false)) continue
            val images = row.getJSONArray("images")
            if (images.length() > 0 && !row.optBoolean("any_network") && !onWifi()) return@withLock false
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
            catch (failure: ReportRejected) {
                synchronized(gate) {
                    if (file(row.getString("id")).exists()) save(row.put("state", "failed").put("error", "http_${failure.status}"))
                }
            } catch (_: Exception) { refresh(); return@withLock false }
        }
        refresh()
        synchronized(gate) { records().none { it.optString("state") == "queued" } }
    }

    private fun upload(row: JSONObject): String {
        val connection = URL(ENDPOINT).openConnection() as HttpURLConnection
        try {
            val boundary = "Floe${UUID.randomUUID()}"
            connection.requestMethod = "POST"; connection.doOutput = true
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 20_000; connection.readTimeout = 20_000
            connection.setChunkedStreamingMode(32_768)
            connection.setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
            connection.outputStream.use { output ->
                fun text(value: String) { output.write(value.toByteArray(Charsets.UTF_8)) }
                text("--$boundary\r\nContent-Disposition: form-data; name=\"manifest\"\r\nContent-Type: application/json\r\n\r\n")
                text(row.getJSONObject("manifest").toString()); text("\r\n")
                val images = row.getJSONArray("images")
                for (index in 0 until images.length()) {
                    text("--$boundary\r\nContent-Disposition: form-data; name=\"screenshots\"; filename=\"image-$index.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
                    File(root, images.getString(index)).inputStream().use { it.copyTo(output, 32_768) }
                    text("\r\n")
                }
                text("--$boundary--\r\n")
            }
            val status = connection.responseCode
            if (status == 429 || status >= 500) throw java.io.IOException("retryable_report_transport")
            if (status !in 200..299) throw ReportRejected(status)
            val data = connection.inputStream.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(4_096)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    require(output.size() + count <= 65_536)
                    output.write(buffer, 0, count)
                }
                output.toString("UTF-8")
            }
            val receipt = JSONObject(data)
            val reportID = receipt.optString("report_id")
            val eventID = row.getJSONObject("manifest").getJSONArray("events").getJSONObject(0).getString("client_event_id")
            val acknowledged = listOf("accepted", "duplicates").any { key ->
                receipt.optJSONArray(key)?.let { ids -> (0 until ids.length()).any { ids.optString(it) == eventID } } == true
            }
            require(reportID.matches(Regex("[A-Za-z0-9_-]{8,128}")) && acknowledged)
            return reportID
        } finally { connection.disconnect() }
    }

    fun retry(id: String) {
        synchronized(gate) { read(id)?.takeIf { it.optString("state") == "failed" }?.let {
            save(it.put("state", "queued").apply { remove("error") })
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
        JSONObject(AtomicFile(target).openRead().bufferedReader().use { it.readText() })
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
                it.getJSONArray("images").length())
        })
    } }
    private fun onWifi(): Boolean {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        return manager.getNetworkCapabilities(manager.activeNetwork)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
    }
    private fun enqueue() { WorkManager.getInstance(context).enqueueUniqueWork("floe.diagnostics.upload",
        ExistingWorkPolicy.APPEND_OR_REPLACE, OneTimeWorkRequestBuilder<DiagnosticReportWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.MINUTES).build()) }
    private class ReportRejected(val status: Int) : Exception()
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
        return if (reporter.flush()) Result.success() else Result.retry()
    }
}
