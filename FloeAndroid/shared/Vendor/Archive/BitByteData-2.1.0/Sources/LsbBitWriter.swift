// Copyright (c) 2026 Timofey Solomko
// Licensed under MIT License
//
// See LICENSE for license information

import Foundation

/**
 A type that contains functions for writing `Data` bit-by-bit and byte-by-byte using "LSB 0" bit numbering scheme.
 */
public final class LsbBitWriter: BitWriter {

    /// Data which contains the writer's output (the last byte, that is currently being written, is not included).
    public var data: Data {
        return Data(self.buffer)
    }

    private var buffer: [UInt8] = []
    private var bitMask: UInt8 = 1
    private var currentByte: UInt8 = 0

    /// True, if a bit pointer is aligned to a byte boundary.
    public var isAligned: Bool {
        return self.bitMask == 1
    }

    /// Creates an instance for writing bits and bytes.
    public init() { }

    /**
     Writes a `bit`, advancing by one bit position.

     - Precondition: The `bit` must be either 0 or 1.
     */
    public func write(bit: UInt8) {
        precondition(bit <= 1, "A bit must be either 0 or 1.")

        self.currentByte |= self.bitMask * bit

        if self.bitMask == 128 {
            self.bitMask = 1
            self.buffer.append(self.currentByte)
            self.currentByte = 0
        } else {
            self.bitMask <<= 1
        }
    }

    /**
     Writes an unsigned `number`, advancing by `bitsCount` bit positions.

     This method may be useful for writing numbers, that would cause an integer overflow crash if converted to `Int`.

     - Note: The `number` will be truncated if the `bitsCount` is less than the amount of bits required to fully
     represent the value of `number`.
     - Note: Bits of the `number` are processed using the same bit-numbering scheme as of the writer (i.e. "LSB 0").
     - Precondition: Parameter `bitsCount` must be in the `0...UInt.bitWidth` range.
     */
    public func write(unsignedNumber: UInt, bitsCount: Int) {
        precondition(0...UInt.bitWidth ~= bitsCount)

        // The idea behind this implementation is to reduce as much as possible the amount of time we access the
        // properties of a BitWriter (since the writer is a class property access has a lot of overhead). To achieve
        // that we attempt to process the bits of `unsignedNumber` in bulk with some clever bit math.

        /// Amount of available bits in `currentByte`.
        let currentByteBitsLeft = self.bitMask.leadingZeroBitCount &+ 1
        // Check if `unsignedNumber` can fully fit into `currentByte`.
        if currentByteBitsLeft > bitsCount {
            // We do not consider the case of `currentByteBitsLeft == bitsCount` because it would require resetting
            // `currentByte` and `bitMask` at the end which would introduce additional branching. This case is perfectly
            // handled by the remainder of this function.
            self.currentByte |= UInt8(truncatingIfNeeded: unsignedNumber << (8 &- currentByteBitsLeft))
            self.bitMask <<= bitsCount
            return
        }

        /// Mutable copy of `unsignedNumber`.
        var input = unsignedNumber
        let lowestBitsMask: UInt = (1 << currentByteBitsLeft) &- 1
        self.buffer.append(self.currentByte | UInt8(truncatingIfNeeded: (input & lowestBitsMask) << (8 &- currentByteBitsLeft)))
        // After writing the bits that filled `currentByte` we remove them from the input.
        input >>= currentByteBitsLeft

        var bitsLeftToWrite = bitsCount &- currentByteBitsLeft
        let byteMask: UInt = 0xFF
        // Full bytes from the input can be written directly by proper masking without considering separate bits.
        while bitsLeftToWrite >= 8 {
            bitsLeftToWrite &-= 8
            self.buffer.append(UInt8(truncatingIfNeeded: input & byteMask))
            input >>= 8
        }

        // There might be some bits left that do not fill an entire byte. We put them into the new value of `currentByte`
        // and reset `bitMask` appropriately. This actually works even if `bitsLeftToWrite == 0`. In this case the
        // effective mask is 0x0 so nothing is written into `currentByte`.
        self.currentByte = UInt8(truncatingIfNeeded: input & ((1 << bitsLeftToWrite) &- 1))
        // Similarly, `bitMask` is set to its default value of 1 for `bitsLeftToWrite == 0`.
        self.bitMask = 1 << bitsLeftToWrite
    }

    /**
     Writes a `byte`, advancing by one byte position.

     - Precondition: The writer must be aligned.
     */
    public func append(byte: UInt8) {
        precondition(isAligned, "BitWriter is not aligned.")
        self.buffer.append(byte)
    }

    /**
     Aligns a bit pointer to a byte boundary, i.e. moves the bit pointer to the first bit of the next byte, filling all
     skipped bit positions with zeros. If the writer is already aligned, then does nothing.
     */
    public func align() {
        guard self.bitMask != 1
            else { return }

        self.buffer.append(self.currentByte)
        self.currentByte = 0
        self.bitMask = 1
    }

}
