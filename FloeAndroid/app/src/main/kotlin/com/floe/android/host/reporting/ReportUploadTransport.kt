// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.reporting

import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import okio.Buffer
import okio.BufferedSink
import okio.ForwardingSink
import okio.buffer

/** No automatic transport replay: the durable report queue owns retries. */
internal class ReportUploadTransport(private val client: OkHttpClient = defaultClient) {
    fun post(endpoint: String, manifest: String, images: List<File>, progress: (Long, Long) -> Unit): Pair<Int, String> {
        val multipart = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("manifest", manifest).apply {
                images.forEachIndexed { index, file ->
                    addFormDataPart("screenshots", "image-$index.jpg", file.asRequestBody("image/jpeg".toMediaType()))
                }
            }.build()
        val total = multipart.contentLength()
        val body = object : RequestBody() {
            override fun contentType() = multipart.contentType()
            override fun contentLength() = total
            override fun writeTo(sink: BufferedSink) {
                var written = 0L
                var announced = 0L
                progress(0, total)
                val counting = object : ForwardingSink(sink) {
                    override fun write(source: Buffer, byteCount: Long) {
                        super.write(source, byteCount)
                        written += byteCount
                        if (written - announced >= 65536 || written == total) {
                            announced = written; progress(written, total)
                        }
                    }
                }.buffer()
                multipart.writeTo(counting)
                counting.flush()
            }
        }
        val request = Request.Builder().url(endpoint).post(body).build()
        client.newCall(request).execute().use { response ->
            if (response.code !in 200..299) return response.code to ""
            val data = response.body?.byteStream()?.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > 65536) throw IOException("report_response_too_large")
                    output.write(buffer, 0, count)
                }
                output.toString("UTF-8")
            }.orEmpty()
            return response.code to data
        }
    }

    companion object {
        private val defaultClient = OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS).callTimeout(90, TimeUnit.SECONDS)
            .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).build()
    }
}
