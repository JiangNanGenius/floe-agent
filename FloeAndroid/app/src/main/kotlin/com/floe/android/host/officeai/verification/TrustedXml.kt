// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai.verification

import java.io.ByteArrayInputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Document
import org.w3c.dom.Element
import org.w3c.dom.Node

internal sealed class XmlParseResult {
    data class Parsed(val document: Document) : XmlParseResult()
    data class Refused(val code: String) : XmlParseResult()
}

/** Parses UNTRUSTED OOXML part bytes with the platform javax.xml.parsers DOM.
 *
 * XML content here is trusted for NOTHING, so the primary protection is
 * encoding normalization BEFORE any parser sees the bytes, not a feature
 * flag (Android API 28..37 feature support is genuinely best-effort):
 *  1. Only ASCII-compatible UTF-8 documents are accepted. A byte-level
 *     signature/BOM check plus a full 0x00 scan refuses UTF-16/UTF-32 and
 *     NUL-containing inputs honestly (xmlEncodingUnsupported): any XML
 *     document's first character '<' contains a zero byte in every
 *     UTF-16/UTF-32 form, and valid UTF-8 XML may never contain a raw NUL,
 *     so this provably removes the platform parser's ability to
 *     re-detect the same bytes as UTF-16/32 under a second interpretation.
 *  2. The remaining bytes must decode as STRICT UTF-8 (REPORT on malformed
 *     and unmappable input); violations are xmlEncodingInvalid.
 *  3. Only THEN is the case-sensitive "<!DOCTYPE"/"<!ENTITY" scan run on the
 *     normalized String, so markers can never hide NUL-interleaved: the
 *     bytes already passed the full encoding closure, so this decoded String
 *     is the definitive content and entity-attack markup found in it is
 *     refused as xmlUntrusted no matter what encoding the declaration claims.
 *     External entity / network / file references are impossible without a
 *     DOCTYPE or ENTITY declaration.
 *  4. The normalized text's XML declaration, when present, must be absent or
 *     declare utf-8/us-ascii; any other declared encoding is refused
 *     (xmlEncodingUnsupported) rather than re-decoded a second way by the
 *     platform parser.
 *  5. Hardening features are then set best-effort (each individually, so
 *     unsupported flags on some platform build cannot reject every valid
 *     document), the EntityResolver is pinned to an empty no-fetch source,
 *     and StAX-only JDK classes are deliberately not used (absent on
 *     Android).
 */
internal object TrustedXml {

    private val ENCODING_VALUE = Regex("^\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')")
    private const val ASCII_MARKER = "<!DOCTYPE"
    private const val ASCII_ENTITY = "<!ENTITY"
    private const val UTF8_BOM_CHAR = '\uFEFF'

    fun parse(bytes: ByteArray): XmlParseResult {
        val normalized = normalizeEncoding(bytes)
        return when (normalized) {
            is Normalize.Failed -> XmlParseResult.Refused(normalized.code)
            is Normalize.Ok -> {
                val text = normalized.text
                if (text.contains(ASCII_MARKER) || text.contains(ASCII_ENTITY)) {
                    return XmlParseResult.Refused(VerificationCodes.XML_UNTRUSTED)
                }
                checkDeclaration(text)?.let { code ->
                    return XmlParseResult.Refused(code)
                }
                parseUtf8Bytes(bytes)
            }
        }
    }

    private sealed class Normalize {
        data class Ok(val text: String) : Normalize()
        data class Failed(val code: String) : Normalize()
    }

    /** Encoding closure only: signature/NUL refusal + strict UTF-8 decode +
     *  BOM strip. After this the returned String IS the definitive content.
     */
    private fun normalizeEncoding(bytes: ByteArray): Normalize {
        if (bytes.isEmpty()) return Normalize.Failed(VerificationCodes.XML_ENCODING_INVALID)
        if (hasUtf16Or32Signature(bytes)) return Normalize.Failed(VerificationCodes.XML_ENCODING_UNSUPPORTED)
        var nulCount = 0
        for (b in bytes) {
            if (b.toInt() == 0) nulCount += 1
        }
        // XML 1.0 forbids raw NUL in UTF-8 text; any NUL means these bytes
        // are not an ASCII-compatible XML encoding we may hand to the parser.
        if (nulCount > 0) return Normalize.Failed(VerificationCodes.XML_ENCODING_UNSUPPORTED)
        val decoded = try {
            val decoder = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            decoder.decode(ByteBuffer.wrap(bytes)).toString()
        } catch (error: CharacterCodingException) {
            return Normalize.Failed(VerificationCodes.XML_ENCODING_INVALID)
        }
        val stripped = if (decoded.startsWith(UTF8_BOM_CHAR)) {
            decoded.substring(1)
        } else {
            decoded
        }
        return Normalize.Ok(stripped)
    }

    /** Declaration guard for what may reach the platform parser; entity-attack
     *  markup was already refused on the normalized text before this runs.
     */
    private fun checkDeclaration(text: String): String? {
        if (!text.startsWith("<?xml")) return null
        val end = text.indexOf("?>")
        if (end < 0) return VerificationCodes.XML_ENCODING_INVALID
        val head = text.substring(0, end)
        val encodingAt = head.indexOf("encoding")
        if (encodingAt < 0) return null
        val tail = head.substring(encodingAt + "encoding".length)
        val value = ENCODING_VALUE.find(tail)
            ?: return VerificationCodes.XML_ENCODING_INVALID
        val declared = (value.groupValues[1].ifEmpty { value.groupValues[2] })
            .trim().lowercase()
        return if (declared != "utf-8" && declared != "utf8" &&
            declared != "us-ascii" && declared != "ascii"
        ) {
            VerificationCodes.XML_ENCODING_UNSUPPORTED
        } else {
            null
        }
    }

    private fun hasUtf16Or32Signature(bytes: ByteArray): Boolean {
        fun b(at: Int): Int = if (at < bytes.size) bytes[at].toInt() and 0xFF else -1
        // UTF-32LE BOM before the overlapping UTF-16LE BOM.
        if (b(0) == 0xFF && b(1) == 0xFE && b(2) == 0x00 && b(3) == 0x00) return true
        if (b(0) == 0x00 && b(1) == 0x00 && b(2) == 0xFE && b(3) == 0xFF) return true
        if (b(0) == 0xFF && b(1) == 0xFE) return true
        if (b(0) == 0xFE && b(1) == 0xFF) return true
        // BOM-less heuristics: '<' (0x3C) at its encoding-specific position.
        if (b(0) == 0x3C && b(1) == 0x00) return true // UTF-16LE
        if (b(0) == 0x00 && b(1) == 0x3C) return true // UTF-16BE
        if (b(0) == 0x00 && b(1) == 0x00 && b(2) == 0x00 && b(3) == 0x3C) return true // UTF-32BE
        if (b(0) == 0x3C && b(1) == 0x00 && b(2) == 0x00 && b(3) == 0x00) return true // UTF-32LE
        return false
    }

    private fun parseUtf8Bytes(bytes: ByteArray): XmlParseResult {
        val factory = try {
            DocumentBuilderFactory.newInstance()
        } catch (error: RuntimeException) {
            return XmlParseResult.Refused(VerificationCodes.PARSER_UNAVAILABLE)
        }
        factory.isNamespaceAware = true
        factory.isValidating = false
        hardenBestEffort(factory)
        val builder = try {
            factory.newDocumentBuilder()
        } catch (error: Exception) {
            return XmlParseResult.Refused(VerificationCodes.PARSER_UNAVAILABLE)
        }
        builder.setEntityResolver { _, _ ->
            // Nothing may be fetched; DOCTYPE/ENTITY was already refused on
            // the normalized text, so even a local entity definition cannot
            // exist; this belt makes any attempted resolution fetch-free.
            org.xml.sax.InputSource(ByteArrayInputStream(ByteArray(0)))
        }
        val document = try {
            builder.parse(ByteArrayInputStream(bytes))
        } catch (error: Exception) {
            return XmlParseResult.Refused(VerificationCodes.XML_MALFORMED)
        }
        return XmlParseResult.Parsed(document)
    }

    private fun hardenBestEffort(factory: DocumentBuilderFactory) {
        val features = listOf(
            "http://apache.org/xml/features/disallow-doctype-decl" to true,
            "http://xml.org/sax/features/external-general-entities" to false,
            "http://xml.org/sax/features/external-parameter-entities" to false,
            "http://apache.org/xml/features/nonvalidating/load-external-dtd" to false,
        )
        for ((name, value) in features) {
            try {
                factory.setFeature(name, value)
            } catch (error: Exception) {
                // Feature variance on some platform builds is tolerated here
                // because the pre-parse normalization + strict UTF-8 +
                // declaration + textual DOCTYPE/ENTITY refusal above already
                // removed the attack surface; failing closed per-document
                // would reject every valid file on such a build.
            }
        }
    }
}

internal object DomUtil {
    fun elements(document: Document, namespaceUri: String, localName: String): List<Element> =
        toElements(document.getElementsByTagNameNS(namespaceUri, localName))

    fun elementsWithin(
        element: Element,
        namespaceUri: String,
        localName: String,
    ): List<Element> = toElements(element.getElementsByTagNameNS(namespaceUri, localName))

    private fun toElements(nodes: org.w3c.dom.NodeList): List<Element> {
        val out = ArrayList<Element>(nodes.length)
        for (index in 0 until nodes.length) {
            val node: Node = nodes.item(index)
            if (node is Element) out.add(node)
        }
        return out
    }

    /** Direct child elements only (document order), namespace + local name. */
    fun childElements(element: Element, namespaceUri: String, localName: String): List<Element> {
        val out = ArrayList<Element>()
        val kids = element.childNodes
        for (index in 0 until kids.length) {
            val node = kids.item(index)
            if (node is Element && node.localName == localName &&
                node.namespaceURI == namespaceUri
            ) {
                out.add(node)
            }
        }
        return out
    }

    fun firstElement(element: Element, namespaceUri: String, localName: String): Element? =
        elementsWithin(element, namespaceUri, localName).firstOrNull()
}
