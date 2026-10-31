// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.pcap

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets

internal class BytePcapSource(
    private val bytes: ByteArray,
    override val label: String? = "capture.pcap",
) : PcapSource {
    override val sizeBytes: Long get() = bytes.size.toLong()
    override fun openStream() = ByteArrayInputStream(bytes)
}

internal object PcapFixtures {
    const val T0_SECONDS = 1_700_000_000L
    const val T0_MICROS = T0_SECONDS * 1_000_000L

    fun ethernetIpv4Tcp(
        tsSeconds: Long = T0_SECONDS,
        tsFraction: Long = 500_000,
        src: String = "10.0.0.1",
        dst: String = "10.0.0.2",
        srcPort: Int = 12_345,
        dstPort: Int = 80,
        payload: ByteArray = "GET /index.html HTTP/1.1\r\nHost: example.test\r\n\r\n"
            .toByteArray(StandardCharsets.US_ASCII),
        vlan: Boolean = false,
        linkType: Int = 1,
    ): ByteArray {
        val tcp = tcp(srcPort, dstPort, payload)
        val ip = ipv4(6, src, dst, tcp)
        val frame = ethernet(if (vlan) 0x8100 else 0x0800, if (vlan) vlan(0x0800, ip) else ip)
        return pcap(linkType, listOf(PacketRecord(tsSeconds, tsFraction, frame)))
    }

    fun ethernetIpv6DnsQuery(): ByteArray {
        val dns = dnsQuery("www.example.test")
        val udp = udp(40_000, 53, dns)
        val ip = ipv6(17, "2001:db8::1", "2001:db8::2", udp)
        return pcap(1, listOf(PacketRecord(T0_SECONDS, 250_000, ethernet(0x86DD, ip))))
    }

    fun ethernetIcmpVlan(): ByteArray {
        val icmp = byteArrayOf(8, 0, 0, 0, 0, 1, 0, 1)
        val ip = ipv4(1, "192.168.1.2", "192.168.1.1", icmp)
        return pcap(1, listOf(PacketRecord(T0_SECONDS, 1_000, ethernet(0x8100, vlan(0x0800, ip)))))
    }

    fun sllIpv4Udp(): ByteArray {
        val udp = udp(53, 50_000, dnsQuery("sll.example.test"))
        val ip = ipv4(17, "10.1.0.1", "10.1.0.2", udp)
        val sll = ByteArray(16)
        put16be(sll, 14, 0x0800)
        return pcap(113, listOf(PacketRecord(T0_SECONDS, 2_000, sll + ip)))
    }

    fun sll2Ipv4Udp(): ByteArray {
        val udp = udp(53, 50_001, dnsQuery("sll2.example.test"))
        val ip = ipv4(17, "10.2.0.1", "10.2.0.2", udp)
        val sll2 = ByteArray(20)
        put16be(sll2, 0, 0x0800)
        return pcap(276, listOf(PacketRecord(T0_SECONDS, 3_000, sll2 + ip)))
    }

    fun rawIpv4(): ByteArray {
        val ip = ipv4(17, "10.3.0.1", "10.3.0.2", udp(1000, 2000, ByteArray(4)))
        return pcap(101, listOf(PacketRecord(T0_SECONDS, 4_000, ip)))
    }

    fun unknownLink(): ByteArray =
        pcap(147, listOf(PacketRecord(T0_SECONDS, 5_000, ByteArray(20) { 0x11 })))

    fun bigEndianNano(): ByteArray =
        pcap(
            linkType = 1,
            records = listOf(PacketRecord(T0_SECONDS, 123_456_789,
                ethernet(0x0800, ipv4(17, "10.4.0.1", "10.4.0.2", udp(1000, 2000, ByteArray(2)))))),
            little = false,
            nano = true,
        )

    private fun pcap(
        linkType: Int,
        records: List<PacketRecord>,
        little: Boolean = true,
        nano: Boolean = false,
    ): ByteArray {
        val output = ByteArrayOutputStream()
        when {
            little && nano -> output.write(byteArrayOf(0x4D, 0x3C, 0xB2.toByte(), 0xA1.toByte()))
            little -> output.write(byteArrayOf(0xD4.toByte(), 0xC3.toByte(), 0xB2.toByte(), 0xA1.toByte()))
            nano -> output.write(byteArrayOf(0xA1.toByte(), 0xB2.toByte(), 0x3C, 0x4D))
            else -> output.write(byteArrayOf(0xA1.toByte(), 0xB2.toByte(), 0xC3.toByte(), 0xD4.toByte()))
        }
        write16(output, 2, little)
        write16(output, 4, little)
        write32(output, 0, little)
        write32(output, 0, little)
        write32(output, 65_535, little)
        write32(output, linkType.toLong(), little)
        records.forEach { record ->
            write32(output, record.seconds, little)
            write32(output, record.fraction, little)
            write32(output, record.data.size.toLong(), little)
            write32(output, record.data.size.toLong(), little)
            output.write(record.data)
        }
        return output.toByteArray()
    }

    fun pcapNgMulti(): ByteArray {
        val output = ByteArrayOutputStream()
        output.write(shb(little = true))
        output.write(idb(little = true, linkType = 1))
        val tcp = tcp(12_345, 80,
            "GET /ng HTTP/1.1\r\nHost: ng.example.test\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
        output.write(epb(little = true, interfaceID = 0, timestampMicros = T0_MICROS + 100_000,
            packet = ethernet(0x0800, ipv4(6, "10.5.0.1", "10.5.0.2", tcp))))
        output.write(idb(little = true, linkType = 101))
        output.write(epb(little = true, interfaceID = 1, timestampMicros = T0_MICROS + 200_000,
            packet = ipv4(17, "10.5.0.3", "10.5.0.4", udp(1000, 2000, ByteArray(4)))))
        // A second section resets the interface table (big-endian on purpose).
        output.write(shb(little = false))
        output.write(idb(little = false, linkType = 1))
        output.write(epb(little = false, interfaceID = 0, timestampMicros = T0_MICROS + 300_000,
            packet = ethernet(0x0800, ipv4(17, "10.6.0.1", "10.6.0.2", udp(1000, 2000, ByteArray(4))))))
        return output.toByteArray()
    }

    fun truncatedPcap(): ByteArray {
        val complete = ethernetIpv4Tcp()
        return complete.copyOf(complete.size - 10)
    }

    private fun shb(little: Boolean): ByteArray {
        val body = ByteArrayOutputStream()
        write32(body, 0x1A2B3C4D, little)
        write16(body, 1, little)
        write16(body, 0, little)
        write64(body, -1L, little)
        return block(0x0A0D0D0AL, body.toByteArray(), little)
    }

    private fun idb(little: Boolean, linkType: Int): ByteArray {
        val body = ByteArrayOutputStream()
        write16(body, linkType, little)
        write16(body, 0, little)
        write32(body, 65_535, little)
        return block(0x00000001L, body.toByteArray(), little)
    }

    private fun epb(
        little: Boolean,
        interfaceID: Int,
        timestampMicros: Long,
        packet: ByteArray,
    ): ByteArray {
        val body = ByteArrayOutputStream()
        write32(body, interfaceID.toLong(), little)
        write32(body, timestampMicros ushr 32, little)
        write32(body, timestampMicros and 0xFFFFFFFFL, little)
        write32(body, packet.size.toLong(), little)
        write32(body, packet.size.toLong(), little)
        body.write(packet)
        while (body.size() % 4 != 0) body.write(0)
        return block(0x00000006L, body.toByteArray(), little)
    }

    private fun block(type: Long, body: ByteArray, little: Boolean): ByteArray {
        val total = 12L + body.size
        val output = ByteArrayOutputStream()
        write32(output, type, little)
        write32(output, total, little)
        output.write(body)
        write32(output, total, little)
        return output.toByteArray()
    }

    private fun ethernet(etherType: Int, payload: ByteArray): ByteArray {
        val header = ByteArray(14)
        for (index in 0 until 6) header[index] = (0x02).toByte()
        for (index in 6 until 12) header[index] = (0x04).toByte()
        put16be(header, 12, etherType)
        return header + payload
    }

    private fun vlan(innerType: Int, payload: ByteArray): ByteArray {
        val tag = ByteArray(4)
        put16be(tag, 0, 100)
        put16be(tag, 2, innerType)
        return tag + payload
    }

    private fun ipv4(protocol: Int, src: String, dst: String, payload: ByteArray): ByteArray {
        val header = ByteArray(20)
        header[0] = 0x45
        put16be(header, 2, 20 + payload.size)
        put16be(header, 4, 0)
        put16be(header, 6, 0x4000)
        header[8] = 64
        header[9] = protocol.toByte()
        address(src).copyInto(header, 12)
        address(dst).copyInto(header, 16)
        return header + payload
    }

    private fun ipv6(nextHeader: Int, src: String, dst: String, payload: ByteArray): ByteArray {
        val header = ByteArray(40)
        header[0] = 0x60
        put16be(header, 4, payload.size)
        header[6] = nextHeader.toByte()
        header[7] = 64
        address(src).copyInto(header, 8)
        address(dst).copyInto(header, 24)
        return header + payload
    }

    private fun tcp(srcPort: Int, dstPort: Int, payload: ByteArray): ByteArray {
        val header = ByteArray(20)
        put16be(header, 0, srcPort)
        put16be(header, 2, dstPort)
        header[12] = 0x50
        header[13] = 0x18
        put16be(header, 14, 65_535)
        return header + payload
    }

    private fun udp(srcPort: Int, dstPort: Int, payload: ByteArray): ByteArray {
        val header = ByteArray(8)
        put16be(header, 0, srcPort)
        put16be(header, 2, dstPort)
        put16be(header, 4, 8 + payload.size)
        return header + payload
    }

    private fun dnsQuery(name: String): ByteArray {
        val output = ByteArrayOutputStream()
        write16be(output, 0x1234)
        write16be(output, 0x0100)
        write16be(output, 1)
        write16be(output, 0)
        write16be(output, 0)
        write16be(output, 0)
        name.split('.').forEach { label ->
            output.write(label.length)
            output.write(label.toByteArray(StandardCharsets.US_ASCII))
        }
        output.write(0)
        write16be(output, 1)
        write16be(output, 1)
        return output.toByteArray()
    }

    private fun address(value: String): ByteArray =
        java.net.InetAddress.getByName(value).address

    private fun put16be(buffer: ByteArray, offset: Int, value: Int) {
        buffer[offset] = (value ushr 8).toByte()
        buffer[offset + 1] = value.toByte()
    }

    private fun write16(output: ByteArrayOutputStream, value: Int, little: Boolean) {
        if (little) {
            output.write(value and 0xFF)
            output.write((value ushr 8) and 0xFF)
        } else {
            output.write((value ushr 8) and 0xFF)
            output.write(value and 0xFF)
        }
    }

    private fun write16be(output: ByteArrayOutputStream, value: Int) {
        output.write((value ushr 8) and 0xFF)
        output.write(value and 0xFF)
    }

    private fun write32(output: ByteArrayOutputStream, value: Long, little: Boolean) {
        if (little) {
            for (index in 0 until 4) output.write(((value ushr (index * 8)) and 0xFF).toInt())
        } else {
            for (index in 3 downTo 0) output.write(((value ushr (index * 8)) and 0xFF).toInt())
        }
    }

    private fun write64(output: ByteArrayOutputStream, value: Long, little: Boolean) {
        if (little) {
            for (index in 0 until 8) output.write(((value ushr (index * 8)) and 0xFF).toInt())
        } else {
            for (index in 7 downTo 0) output.write(((value ushr (index * 8)) and 0xFF).toInt())
        }
    }

    private data class PacketRecord(val seconds: Long, val fraction: Long, val data: ByteArray)
}
