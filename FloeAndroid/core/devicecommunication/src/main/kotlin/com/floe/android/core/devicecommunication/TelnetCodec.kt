// SPDX-License-Identifier: MPL-2.0
//
// Incremental Telnet (RFC 854/855 subset) framing for a real TCP stream.
//
// The parser keeps its state ACROSS arbitrary socket reads: a two-byte IAC
// sequence split over two reads is not application data, and an escaped
// 0xFF is restored exactly once. Options are refused deterministically
// (WILL -> DONT, DO -> WONT, WONT/DONT -> no reply) because this is a raw
// terminal transport, not a Telnet client negotiating a custom terminal
// type. Subnegotiations are skipped with a hard byte bound. No charset
// conversion occurs here; application bytes stay byte-exact.

package com.floe.android.core.devicecommunication

class TelnetCodec {
    private enum class State {
        DATA,
        IAC,
        OPTION,
        SUBNEG,
        SUBNEG_IAC,
        SUBNEG_SKIP,
        SUBNEG_SKIP_IAC,
    }

    private var state = State.DATA
    private var pendingCommand = 0
    private var subnegotiationBytes = 0
    private var truncatedSubnegotiations = 0

    var refusedOptions: Int = 0
        private set
    var skippedSubnegotiations: Int = 0
        private set
    var escapedFrames: Int = 0
        private set

    data class Result(
        val application: ByteArray,
        val replies: ByteArray,
        val refusedOptions: Int,
        val truncatedSubnegotiation: Boolean,
    )

    fun feed(input: ByteArray): Result {
        if (input.isEmpty()) return Result(ByteArray(0), ByteArray(0), 0, false)
        val application = ArrayList<Byte>(input.size)
        val replies = ArrayList<Byte>(4)
        var refused = 0
        var truncated = false
        var index = 0
        while (index < input.size) {
            val byte = input[index].toInt() and 0xFF
            when (state) {
                State.DATA -> {
                    if (byte == IAC) {
                        state = State.IAC
                    } else {
                        application.add(byte.toByte())
                    }
                    index++
                }

                State.IAC -> {
                    when (byte) {
                        IAC -> {
                            application.add(0xFF.toByte())
                            escapedFrames++
                            state = State.DATA
                        }
                        WILL, WONT, DO, DONT -> {
                            pendingCommand = byte
                            state = State.OPTION
                        }
                        SB -> {
                            subnegotiationBytes = 0
                            state = State.SUBNEG
                        }
                        else -> {
                            // Two-byte command with no option payload (NOP,
                            // AYT, BREAK, ...). Consume it; SE outside a
                            // subnegotiation is ignored.
                            state = State.DATA
                        }
                    }
                    index++
                }

                State.OPTION -> {
                    if (byte == IAC) {
                        // Malformed option; return to DATA without emitting a
                        // speculative reply so a corrupt stream cannot make
                        // us negotiate a protocol we did not understand.
                        state = State.DATA
                    } else {
                        when (pendingCommand) {
                            WILL -> appendRefusal(replies, DONT, byte)
                            DO -> appendRefusal(replies, WONT, byte)
                            else -> Unit
                        }
                        refused++
                        state = State.DATA
                    }
                    index++
                }

                State.SUBNEG -> {
                    if (byte == IAC) {
                        state = State.SUBNEG_IAC
                    } else {
                        subnegotiationBytes++
                        if (subnegotiationBytes > DeviceLimits.MAXIMUM_TELNET_SUBNEGOTIATION_BYTES) {
                            // Drop the overlong body and resynchronise at the
                            // next IAC; never grow memory with peer input.
                            truncated = true
                            state = State.SUBNEG_SKIP
                        }
                    }
                    index++
                }

                State.SUBNEG_IAC -> {
                    when (byte) {
                        SE -> {
                            skippedSubnegotiations++
                            state = State.DATA
                        }
                        IAC -> {
                            subnegotiationBytes++
                            state = State.SUBNEG
                        }
                        else -> state = State.SUBNEG
                    }
                    index++
                }

                State.SUBNEG_SKIP -> {
                    if (byte == IAC) state = State.SUBNEG_SKIP_IAC
                    index++
                }

                State.SUBNEG_SKIP_IAC -> {
                    when (byte) {
                        SE -> {
                            skippedSubnegotiations++
                            state = State.DATA
                        }
                        IAC -> state = State.SUBNEG_SKIP
                        else -> state = State.SUBNEG_SKIP
                    }
                    index++
                }
            }
        }
        refusedOptions += refused
        if (truncated) truncatedSubnegotiations++
        return Result(
            application = application.toByteArray(),
            replies = replies.toByteArray(),
            refusedOptions = refused,
            truncatedSubnegotiation = truncated,
        )
    }

    fun reset() {
        state = State.DATA
        pendingCommand = 0
        subnegotiationBytes = 0
        truncatedSubnegotiations = 0
        refusedOptions = 0
        skippedSubnegotiations = 0
        escapedFrames = 0
    }

    val pendingSubnegotiations: Int get() = truncatedSubnegotiations

    private fun appendRefusal(target: ArrayList<Byte>, command: Int, option: Int) {
        target.add(IAC.toByte())
        target.add(command.toByte())
        target.add(option.toByte())
    }

    companion object {
        const val IAC = 255
        const val DONT = 254
        const val DO = 253
        const val WONT = 252
        const val WILL = 251
        const val SB = 250
        const val SE = 240
    }
}
