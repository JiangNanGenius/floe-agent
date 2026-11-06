// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.reporting

import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.Response
import okio.Buffer
import okio.BufferedSink
import okio.ForwardingSink
import okio.buffer

/** No automatic transport replay: the durable report queue owns retries. */
internal class ReportUploadTransport(private val client: OkHttpClient = defaultClient) {
    suspend fun post(endpoint: String, manifest: String, images: List<File>,
        session: ReportUploadSession = ReportUploadSession(), progress: (Long, Long) -> Unit): Pair<Int, String> {
        session.checkActive()
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
                        session.checkActive()
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
        return suspendCancellableCoroutine { continuation ->
            val call = client.newCall(request)
            session.bind(call)
            continuation.invokeOnCancellation { call.cancel() }
            try {
                call.enqueue(object : Callback {
                    override fun onFailure(call: Call, error: IOException) {
                        session.unbind(call)
                        continuation.resumeWith(Result.failure(error))
                    }

                    override fun onResponse(call: Call, response: Response) {
                        val result = runCatching { response.use { readResponse(it) } }
                        session.unbind(call)
                        continuation.resumeWith(result)
                    }
                })
            } catch (error: Exception) {
                session.unbind(call)
                call.cancel()
                continuation.resumeWith(Result.failure(error))
            }
        }
    }

    private fun readResponse(response: Response): Pair<Int, String> {
            if (response.code !in 200..299 && response.code != 409) return response.code to ""
            val limit = if (response.code == 409) 8192 else 65536
            val data = response.body?.byteStream()?.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > limit) {
                        if (response.code == 409) return response.code to ""
                        throw IOException("report_response_too_large")
                    }
                    output.write(buffer, 0, count)
                }
                output.toString("UTF-8")
            }.orEmpty()
            return response.code to data
    }

    companion object {
        private val defaultClient = OkHttpClient.Builder()
            // Isolate feedback uploads from HTTP/2 stream/proxy interactions.
            // This is a single-request transport choice, never protocol replay;
            // TLS verification and queue-owned retries are unchanged.
            .protocols(listOf(Protocol.HTTP_1_1))
            .connectTimeout(20, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS).callTimeout(90, TimeUnit.SECONDS)
            .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).build()
    }
}
