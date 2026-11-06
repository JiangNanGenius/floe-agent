// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import com.caverock.androidsvg.SVG
import java.io.ByteArrayInputStream
import java.io.File
import java.util.Base64
import javax.xml.parsers.SAXParserFactory
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.SAXParseException
import org.xml.sax.ext.DefaultHandler2
import kotlin.math.roundToInt

/** Bounded static SVG only. No provider, network, path or editor authority. */
internal object WorkspaceSvgPolicy {
    const val MAX_BYTES = 2L * 1024 * 1024
    const val MAX_EDGE = 2048
    const val MAX_PIXELS = 4_194_304L
    private const val SVG_NS = "http://www.w3.org/2000/svg"
    enum class Reason { INVALID, UNSUPPORTED, TOO_LARGE }
    class Rejected(val reason: Reason) : RuntimeException(reason.name)
    private fun reject(reason: Reason = Reason.UNSUPPORTED): Nothing = throw Rejected(reason)
    data class Checked(val images: List<ByteArray>)
    private class Node(val references: MutableList<String> = mutableListOf(),
        val children: MutableList<Int> = mutableListOf(), val style: StringBuilder = StringBuilder())
    private val url = Regex("url\\s*\\(\\s*['\"]?([^)'\"]+)['\"]?\\s*\\)", RegexOption.IGNORE_CASE)

    fun check(bytes: ByteArray, current: () -> Unit = {}): Checked {
        if (bytes.isEmpty()) reject(Reason.INVALID)
        if (bytes.size > MAX_BYTES) reject(Reason.TOO_LARGE)
        val nodes = mutableListOf<Node>()
        val stack = mutableListOf<Pair<Int, Boolean>>()
        val ids = mutableMapOf<String, Int>()
        val images = mutableListOf<ByteArray>()
        fun reference(value: String, node: Node) {
            val text = value.trim()
            if (!text.startsWith('#') || text.length < 2) reject()
            node.references += text.drop(1)
        }
        fun css(text: String, node: Node) {
            if (text.contains("@import", true) || text.contains("@font-face", true)) reject()
            url.findAll(text).forEach { reference(it.groupValues[1], node) }
        }
        val handler = object : DefaultHandler2() {
            override fun startDTD(name: String?, publicId: String?, systemId: String?) { reject() }
            override fun resolveEntity(publicId: String?, systemId: String?): InputSource = reject()
            override fun resolveEntity(name: String?, publicId: String?, baseURI: String?, systemId: String?): InputSource = reject()
            override fun skippedEntity(name: String?) { reject() }
            override fun fatalError(error: SAXParseException?) { reject(Reason.INVALID) }
            override fun processingInstruction(target: String?, data: String?) {
                if (target.equals("xml-stylesheet", true)) reject()
            }
            override fun startElement(uri: String, local: String, qName: String, attributes: Attributes) {
                current()
                if (nodes.size >= 5000 || stack.size >= 64 || attributes.length > 128) reject(Reason.TOO_LARGE)
                val svg = uri.isEmpty() || uri == SVG_NS
                if (nodes.isEmpty() && (!svg || local != "svg")) reject(Reason.INVALID)
                if (svg && local in setOf("script", "foreignObject", "filter", "animate", "animateTransform", "animateMotion", "set")) reject()
                val index = nodes.size
                val node = Node(); nodes += node
                stack.lastOrNull()?.let { nodes[it.first].children += index }
                stack += index to (svg && local == "style")
                if (!svg) return
                for (i in 0 until attributes.length) {
                    val name = attributes.getLocalName(i)
                    val value = attributes.getValue(i)
                    if (name == "id" && ids.put(value, index) != null) reject(Reason.INVALID)
                    if (name.startsWith("on", true)) reject()
                    if (name == "filter" && value.trim() != "none") reject()
                    if (name == "style" || value.contains("url", true)) css(value, node)
                    if (name != "href" || local == "a") continue
                    if (local == "image") {
                        // Only bounded embedded raster data; never resolve a URL.
                        val comma = value.indexOf(',')
                        if (comma < 0 || value.substring(0, comma).lowercase() !in setOf(
                                "data:image/png;base64", "data:image/jpeg;base64", "data:image/webp;base64")) reject()
                        val encoded = value.substring(comma + 1).filterNot { it.isWhitespace() }
                        val data = try { Base64.getDecoder().decode(encoded) } catch (_: IllegalArgumentException) { reject(Reason.INVALID) }
                        images += data
                    } else reference(value, node)
                }
            }
            override fun characters(ch: CharArray, start: Int, length: Int) {
                current()
                stack.lastOrNull()?.takeIf { it.second }?.let { nodes[it.first].style.append(ch, start, length) }
            }
            override fun endElement(uri: String, local: String, qName: String) {
                val entry = stack.removeAt(stack.lastIndex)
                if (entry.second) css(nodes[entry.first].style.toString(), nodes[entry.first])
            }
        }
        val factory = SAXParserFactory.newInstance().apply {
            isNamespaceAware = true
            setFeature("http://xml.org/sax/features/external-general-entities", false)
            setFeature("http://xml.org/sax/features/external-parameter-entities", false)
        }
        val reader = factory.newSAXParser().xmlReader
        reader.contentHandler = handler
        reader.errorHandler = handler
        reader.entityResolver = handler
        reader.setProperty("http://xml.org/sax/properties/lexical-handler", handler)
        reader.parse(InputSource(ByteArrayInputStream(bytes)))
        if (nodes.isEmpty()) reject(Reason.INVALID)
        // Reusable symbols/gradients are allowed, with bounded expansion and
        // no reference cycles (including indirect use/clip/gradient cycles).
        val marks = IntArray(nodes.size)
        val costs = LongArray(nodes.size)
        fun visit(index: Int, depth: Int): Long {
            current()
            if (depth > 64 || marks[index] == 1) reject()
            if (marks[index] == 2) return costs[index]
            marks[index] = 1
            val node = nodes[index]
            var cost = 1L
            for (next in node.children + node.references.map { ids[it] ?: reject(Reason.INVALID) }) {
                cost += visit(next, depth + 1)
                if (cost > 100_000) reject(Reason.TOO_LARGE)
            }
            marks[index] = 2; costs[index] = cost
            return cost
        }
        visit(0, 0)
        return Checked(images)
    }

    fun dimensions(aspect: Double): Pair<Int, Int> {
        if (!aspect.isFinite() || aspect <= 0 || aspect > 100_000 || aspect < 0.00001) reject(Reason.INVALID)
        return if (aspect >= 1) MAX_EDGE to (MAX_EDGE / aspect).roundToInt().coerceAtLeast(1)
            else (MAX_EDGE * aspect).roundToInt().coerceAtLeast(1) to MAX_EDGE
    }
}

internal object WorkspaceSvgPreview {
    fun render(file: File, current: () -> Unit): Bitmap {
        if (file.length() > WorkspaceSvgPolicy.MAX_BYTES) throw WorkspaceSvgPolicy.Rejected(WorkspaceSvgPolicy.Reason.TOO_LARGE)
        val bytes = file.readBytes()
        val checked = WorkspaceSvgPolicy.check(bytes, current)
        var imagePixels = 0L
        for (data in checked.images) {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw WorkspaceSvgPolicy.Rejected(WorkspaceSvgPolicy.Reason.INVALID)
            imagePixels += bounds.outWidth.toLong() * bounds.outHeight
            if (imagePixels > WorkspaceSvgPolicy.MAX_PIXELS) throw WorkspaceSvgPolicy.Rejected(WorkspaceSvgPolicy.Reason.TOO_LARGE)
        }
        current()
        SVG.setInternalEntitiesEnabled(false)
        SVG.deregisterExternalFileResolver()
        val svg = SVG.getFromInputStream(ByteArrayInputStream(bytes))
        val aspect = svg.documentAspectRatio.toDouble().takeIf { it.isFinite() && it > 0 } ?: 2.0
        val (width, height) = WorkspaceSvgPolicy.dimensions(aspect)
        current()
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            svg.setDocumentWidth("100%"); svg.setDocumentHeight("100%")
            svg.renderToCanvas(Canvas(bitmap))
            current()
            return bitmap
        } catch (error: Throwable) {
            bitmap.recycle()
            throw error
        }
    }
}
