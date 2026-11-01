// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkcapture

/**
 * Hard, product-owned bounds for one live packet capture.
 *
 * They are enforced by the state machine, the PCAP writer, the bounded sink
 * and the data plane, not by UI convention or a model argument. The byte cap
 * matches [com.floe.android.core.pcap.PcapLimits.MAX_SOURCE_BYTES] so the
 * existing offline analyzer can always consume a finished capture.
 */
object CaptureLimits {
    const val MAX_DURATION_MILLIS: Long = 15L * 60L * 1000L
    const val MAX_ROOT_DURATION_MILLIS: Long = 5L * 60L * 1000L
    const val MAX_BYTES: Long = 128L * 1024L * 1024L
    const val MAX_PACKETS: Long = 2_000_000L

    /** Root tcpdump output is capped below the analyzer cap and the raw store. */
    const val MAX_ROOT_BYTES: Long = 128L * 1024L * 1024L
    const val MAX_ROOT_PACKETS: Long = 2_000_000L

    const val MAX_QUEUE_PACKETS: Int = 512
    const val MAX_QUEUE_BYTES: Long = 4L * 1024L * 1024L
    const val MAX_PACKET_BYTES: Int = 65_535
    const val SNAPLEN: Int = 65_535
    const val DEFAULT_MTU: Int = 1_500
    const val MIN_MTU: Int = 576
    const val MAX_MTU: Int = 9_000

    const val MAX_RETAINED_RAW_CAPTURES: Int = 3
    const val MAX_RETAINED_RAW_BYTES: Long = 192L * 1024L * 1024L

    const val MAX_OWNER_CHARS: Int = 128
    const val MAX_FAILURE_MESSAGE_CHARS: Int = 240
    const val MAX_LIMITATIONS: Int = 16
    const val MAX_LIMITATION_CHARS: Int = 240

    const val DEFAULT_VPN_ADDRESS: String = "10.111.222.1"
    const val VPN_ADDRESS_PREFIX: Int = 32
    const val VPN_ROUTE: String = "0.0.0.0/0"

    /** Stop/drain budget. A timeout is reported, never treated as drained. */
    const val STOP_WAIT_MILLIS: Long = 5_000L
    const val DRAIN_WAIT_MILLIS: Long = 5_000L
}
