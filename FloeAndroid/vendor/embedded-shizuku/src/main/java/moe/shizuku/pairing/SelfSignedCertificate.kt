// SPDX-License-Identifier: Apache-2.0
// Floe-authored, replacing the BouncyCastle certificate builder used by
// RikkaApps/Shizuku manager AdbKey.kt. Only the minimal self-signed X.509 v3
// certificate needed by the ADB pairing TLS client is produced; adbd does not
// validate this certificate chain, it authenticates the paired key afterwards.
package moe.shizuku.pairing

import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.security.KeyPair
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

object SelfSignedCertificate {

    private const val SHA256_WITH_RSA = "1.2.840.113549.1.1.11"
    private const val COMMON_NAME = "2.5.4.3"

    fun create(keyPair: KeyPair, commonName: String = "00"): X509Certificate {
        require(keyPair.private.algorithm == "RSA") { "ADB identity requires an RSA key" }
        require(commonName.isNotEmpty() && commonName.length <= 64) { "invalid common name" }

        val algorithm = Der.sequence(Der.oid(SHA256_WITH_RSA), Der.nullValue())
        val name = Der.sequence(
            Der.set(Der.sequence(Der.oid(COMMON_NAME), Der.utf8(commonName))),
        )
        val validity = Der.sequence(
            Der.utcTime(Date(0L)),
            Der.utcTime(Date(2_461_449_600_000L)),
        )
        val tbs = Der.sequence(
            Der.explicit(0, Der.integer(BigInteger.valueOf(2))),
            Der.integer(BigInteger.ONE),
            algorithm,
            name,
            validity,
            name,
            keyPair.public.encoded,
        )
        val signer = Signature.getInstance("SHA256withRSA")
        signer.initSign(keyPair.private)
        signer.update(tbs)
        val signature = signer.sign()
        val certificate = Der.sequence(tbs, algorithm, Der.bitString(signature))
        return CertificateFactory.getInstance("X.509")
            .generateCertificate(certificate.inputStream()) as X509Certificate
    }

    private object Der {

        fun sequence(vararg parts: ByteArray): ByteArray = tlv(0x30, concat(parts))

        fun set(part: ByteArray): ByteArray = tlv(0x31, part)

        fun explicit(tag: Int, content: ByteArray): ByteArray = tlv(0xA0 or tag, content)

        fun integer(value: BigInteger): ByteArray = tlv(0x02, value.toByteArray())

        fun nullValue(): ByteArray = byteArrayOf(0x05, 0x00)

        fun utf8(value: String): ByteArray = tlv(0x0C, value.toByteArray(Charsets.UTF_8))

        fun bitString(value: ByteArray): ByteArray = tlv(0x03, byteArrayOf(0) + value)

        fun utcTime(value: Date): ByteArray {
            val format = SimpleDateFormat("yyMMddHHmmss'Z'", Locale.ROOT).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
            return tlv(0x17, format.format(value).toByteArray(Charsets.US_ASCII))
        }

        fun oid(value: String): ByteArray {
            val arcs = value.split('.').map { it.toInt() }
            require(arcs.size >= 2) { "invalid oid" }
            val out = ByteArrayOutputStream()
            out.write(arcs[0] * 40 + arcs[1])
            for (arc in arcs.drop(2)) {
                var current = arc
                val stack = IntArray(5)
                var count = 0
                do {
                    stack[count++] = current and 0x7F
                    current = current ushr 7
                } while (current != 0)
                while (count > 0) {
                    val byte = stack[--count]
                    out.write(if (count == 0) byte else byte or 0x80)
                }
            }
            return tlv(0x06, out.toByteArray())
        }

        fun tlv(tag: Int, content: ByteArray): ByteArray {
            val length = when {
                content.size < 0x80 -> byteArrayOf(content.size.toByte())
                content.size < 0x100 -> byteArrayOf(0x81.toByte(), content.size.toByte())
                content.size < 0x10000 -> byteArrayOf(
                    0x82.toByte(),
                    (content.size ushr 8).toByte(),
                    content.size.toByte(),
                )
                else -> error("DER content too large")
            }
            return byteArrayOf(tag.toByte()) + length + content
        }

        private fun concat(parts: Array<out ByteArray>): ByteArray {
            val out = ByteArrayOutputStream()
            parts.forEach { out.write(it) }
            return out.toByteArray()
        }
    }
}
