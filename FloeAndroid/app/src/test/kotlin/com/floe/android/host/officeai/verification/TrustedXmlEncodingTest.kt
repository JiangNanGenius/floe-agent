// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai.verification

import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Regression source against the ACTUAL production TrustedXml encoding
 * normalization: UTF-16/UTF-32 documents (with and without BOM) that hide a
 * DOCTYPE / internal entity NUL-interleaved from an ASCII byte scan must be
 * honestly refused with a typed code BEFORE any parser runs — never parsed,
 * never "found" — while valid UTF-8/ASCII documents keep parsing so no valid
 * file is falsely rejected.
 */
class TrustedXmlEncodingTest {

    private val wordDoctype =
        "<?xml version=\"1.0\" encoding=\"UTF-16\"?>" +
            "<!DOCTYPE w:document [<!ENTITY x SYSTEM \"file:///etc/passwd\">]>" +
            "<w:document xmlns:w=\"" + OoxmlTestFixtures.W_NS + "\"><w:body>" +
            "<w:p><w:r><w:t>&x;</w:t></w:r></w:p>" +
            "</w:body></w:document>"

    private val wordInternalEntity =
        "<?xml version=\"1.0\" encoding=\"UTF-16\"?>" +
            "<!DOCTYPE w:document [<!ENTITY y \"INJECTED\">]>" +
            "<w:document xmlns:w=\"" + OoxmlTestFixtures.W_NS + "\"><w:body>" +
            "<w:p><w:r><w:t>&y;</w:t></w:r></w:p>" +
            "</w:body></w:document>"

    private val validPlainBody =
        "<w:document xmlns:w=\"" + OoxmlTestFixtures.W_NS + "\"><w:body>" +
            "<w:p><w:r><w:t xml:space=\"preserve\">hello world</w:t></w:r></w:p>" +
            "</w:body></w:document>"

    @Test
    fun utf16LeBomDoctypeIsRefusedBeforeParsing() {
        val le = wordDoctype.toByteArray(StandardCharsets.UTF_16LE)
        val bytes = byteArrayOf(0xFF.toByte(), 0xFE.toByte()) + le
        assertRefused(bytes, VerificationCodes.XML_ENCODING_UNSUPPORTED)
    }

    @Test
    fun utf16LeNoBomDoctypeIsRefused() {
        // 3C 00 signature: '<' NUL-interleaved, invisible to an ASCII scan.
        val bytes = wordDoctype.toByteArray(StandardCharsets.UTF_16LE)
        assertRefused(bytes, VerificationCodes.XML_ENCODING_UNSUPPORTED)
    }

    @Test
    fun utf16BeNoBomInternalEntityIsRefused() {
        val bytes = wordInternalEntity.toByteArray(StandardCharsets.UTF_16BE)
        assertRefused(bytes, VerificationCodes.XML_ENCODING_UNSUPPORTED)
    }

    @Test
    fun utf16BeBomDoctypeIsRefused() {
        val be = wordDoctype.toByteArray(StandardCharsets.UTF_16BE)
        val bytes = byteArrayOf(0xFE.toByte(), 0xFF.toByte()) + be
        assertRefused(bytes, VerificationCodes.XML_ENCODING_UNSUPPORTED)
    }

    @Test
    fun utf32BigEndianBomDoctypeIsRefused() {
        val raw = encodeUtf32(wordDoctype, bigEndian = true)
        val bytes = byteArrayOf(0, 0, 0xFE.toByte(), 0xFF.toByte()) + raw
        assertRefused(bytes, VerificationCodes.XML_ENCODING_UNSUPPORTED)
    }

    @Test
    fun utf32BigEndianNoBomDoctypeIsRefused() {
        assertRefused(
            encodeUtf32(wordDoctype, bigEndian = true),
            VerificationCodes.XML_ENCODING_UNSUPPORTED,
        )
    }

    @Test
    fun utf32LittleEndianNoBomInternalEntityIsRefused() {
        assertRefused(
            encodeUtf32(wordInternalEntity, bigEndian = false),
            VerificationCodes.XML_ENCODING_UNSUPPORTED,
        )
    }

    @Test
    fun utf16WithoutDoctypeIsStillHonestlyUnsupported() {
        // Real P-A exports are UTF-8; UTF-16 parts are refused, not parsed,
        // so no second encoding interpretation is ever possible.
        val bytes = validPlainBody.toByteArray(StandardCharsets.UTF_16LE)
        assertRefused(bytes, VerificationCodes.XML_ENCODING_UNSUPPORTED)
    }

    @Test
    fun utf8BomValidDocumentStillParses() {
        val bytes = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) +
            validPlainBody.toByteArray(StandardCharsets.UTF_8)
        val result = TrustedXml.parse(bytes)
        assertTrue("expected Parsed, got $result", result is XmlParseResult.Parsed)
    }

    @Test
    fun utf8DeclarationVariantsAreHandled() {
        val doc = "<w:document xmlns:w=\"" + OoxmlTestFixtures.W_NS + "\"><w:body/></w:document>"
        val lower = ("<?xml version=\"1.0\" encoding=\"utf-8\"?>" + doc)
            .toByteArray(StandardCharsets.UTF_8)
        assertTrue(TrustedXml.parse(lower) is XmlParseResult.Parsed)
        val ascii = ("<?xml version='1.0' encoding='US-ASCII'?>" + doc)
            .toByteArray(StandardCharsets.US_ASCII)
        assertTrue(TrustedXml.parse(ascii) is XmlParseResult.Parsed)
        val conflict = ("<?xml version=\"1.0\" encoding=\"UTF-16\"?>" + doc)
            .toByteArray(StandardCharsets.UTF_8)
        assertRefused(conflict, VerificationCodes.XML_ENCODING_UNSUPPORTED)
        val latin = ("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>" + doc)
            .toByteArray(StandardCharsets.UTF_8)
        assertRefused(latin, VerificationCodes.XML_ENCODING_UNSUPPORTED)
    }

    @Test
    fun malformedUtf8AndEmbeddedNulAreTypedRefusals() {
        // valid ASCII head, invalid 2-byte UTF-8 sequence, tail.
        val head = ("<w:document xmlns:w=\"" + OoxmlTestFixtures.W_NS + "\">")
            .toByteArray(StandardCharsets.US_ASCII)
        val tail = "</w:document>".toByteArray(StandardCharsets.US_ASCII)
        assertRefused(
            head + byteArrayOf(0xC3.toByte(), 0x28) + tail,
            VerificationCodes.XML_ENCODING_INVALID,
        )
        assertRefused(
            head + byteArrayOf(0x00) + tail,
            VerificationCodes.XML_ENCODING_UNSUPPORTED,
        )
    }

    @Test
    fun plainUtf8DoctypeAndInternalEntityAreRefusedAfterNormalization() {
        assertRefused(
            wordDoctype.toByteArray(StandardCharsets.UTF_8),
            VerificationCodes.XML_UNTRUSTED,
        )
        assertRefused(
            wordInternalEntity.toByteArray(StandardCharsets.UTF_8),
            VerificationCodes.XML_UNTRUSTED,
        )
    }

    @Test
    fun lowercaseDoctypeIsNotSilentlySuccess() {
        // "<!doctype" is not valid XML markup: it must end as a typed refusal
        // (malformed), never a Parsed document that could carry entity text.
        val xml = "<?xml version=\"1.0\"?><!doctype w:document [<!entity x SYSTEM \"file:///x\">]>" +
            "<w:document xmlns:w=\"" + OoxmlTestFixtures.W_NS + "\"><w:body/></w:document>"
        val result = TrustedXml.parse(xml.toByteArray(StandardCharsets.UTF_8))
        assertTrue(
            "expected typed refusal, got $result",
            result is XmlParseResult.Refused,
        )
    }

    private fun assertRefused(bytes: ByteArray, expectedCode: String) {
        val result = TrustedXml.parse(bytes)
        when (result) {
            is XmlParseResult.Refused -> assertEquals(expectedCode, result.code)
            is XmlParseResult.Parsed -> failWith(result, expectedCode)
        }
    }

    private fun failWith(result: XmlParseResult, expectedCode: String) {
        throw AssertionError("expected Refused($expectedCode), got $result")
    }

    private fun encodeUtf32(text: String, bigEndian: Boolean): ByteArray {
        val out = ByteArrayOutputStream()
        var index = 0
        while (index < text.length) {
            val code = text.codePointAt(index)
            val bytes = byteArrayOf(
                ((code ushr 24) and 0xFF).toByte(),
                ((code ushr 16) and 0xFF).toByte(),
                ((code ushr 8) and 0xFF).toByte(),
                (code and 0xFF).toByte(),
            )
            out.write(if (bigEndian) bytes else bytes.reversedArray())
            index += Character.charCount(code)
        }
        return out.toByteArray()
    }
}
