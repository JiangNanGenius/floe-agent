import Foundation

struct MediaBox {
    let type: String
    let start: Int
    let size: Int

    var payloadStart: Int { start + 8 }
    var payloadEnd: Int { start + size }
}

struct MediaInitInfo {
    let width: Int
    let height: Int
    let codec: String
    let profile: UInt8
    let compatibility: UInt8
    let level: UInt8
    let sps: Data
    let pps: Data
    let initLength: Int
    let initData: Data
}

struct MediaFragmentInfo {
    let sequence: UInt32
    let baseDecodeTime: UInt64
    let duration: UInt32
    let sampleSize: UInt32
    let dataOffset: UInt32
    let keyframe: Bool
    let moofSize: Int
    let mdatSize: Int
    let fragmentSize: Int
    let raw: Data
}

enum MediaInspector {
    static func readU16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    static func readU24(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 3 <= data.count else { return nil }
        return UInt32(data[offset]) << 16
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2])
    }

    static func readU32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    static func readU64(_ data: Data, _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        return UInt64(data[offset]) << 56
            | UInt64(data[offset + 1]) << 48
            | UInt64(data[offset + 2]) << 40
            | UInt64(data[offset + 3]) << 32
            | UInt64(data[offset + 4]) << 24
            | UInt64(data[offset + 5]) << 16
            | UInt64(data[offset + 6]) << 8
            | UInt64(data[offset + 7])
    }

    static func boxes(_ data: Data, from: Int, to: Int) -> [MediaBox] {
        var result: [MediaBox] = []
        var offset = from
        while offset + 8 <= to {
            guard let size = readU32(data, offset), size >= 8,
                  size <= UInt32(to - offset) else { break }
            let type = String(bytes: data[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? "????"
            result.append(MediaBox(type: type, start: offset, size: Int(size)))
            offset += Int(size)
        }
        return result
    }

    static func topLevelBoxes(_ data: Data) -> [MediaBox] {
        boxes(data, from: 0, to: data.count)
    }

    private static let containers: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "stsd", "moof", "traf", "mvex", "dinf", "edts",
    ]

    private static func childStart(_ box: MediaBox) -> Int {
        switch box.type {
        case "stsd", "dref":
            return box.payloadStart + 8          // fullbox + entry_count
        case "avc1":
            return box.payloadStart + 78         // VisualSampleEntry fixed fields
        default:
            return box.payloadStart
        }
    }

    static func firstBox(type: String, in box: MediaBox, data: Data) -> MediaBox? {
        for child in boxes(data, from: childStart(box), to: box.payloadEnd) {
            if child.type == type { return child }
            if containers.contains(child.type),
               let nested = firstBox(type: type, in: child, data: data) {
                return nested
            }
        }
        return nil
    }

    static func parseInit(_ data: Data) throws -> MediaInitInfo {
        let top = topLevelBoxes(data)
        guard top.contains(where: { $0.type == "ftyp" }) else {
            throw MediaTestFailure("missing ftyp")
        }
        guard let moov = top.first(where: { $0.type == "moov" }) else {
            throw MediaTestFailure("missing moov")
        }
        guard let avc1 = firstBox(type: "avc1", in: moov, data: data) else {
            throw MediaTestFailure("missing avc1")
        }
        guard let avcC = firstBox(type: "avcC", in: avc1, data: data) else {
            throw MediaTestFailure("missing avcC")
        }
        guard let width = readU16(data, avc1.payloadStart + 24),
              let height = readU16(data, avc1.payloadStart + 26) else {
            throw MediaTestFailure("avc1 dimensions unreadable")
        }
        let payload = avcC.payloadStart
        guard data.count >= payload + 7 else {
            throw MediaTestFailure("avcC truncated")
        }
        let profile = data[payload + 1]
        let compatibility = data[payload + 2]
        let level = data[payload + 3]
        guard let spsCountByte = readU16(data, payload + 6) else {
            throw MediaTestFailure("avcC SPS length unreadable")
        }
        var cursor = payload + 8
        guard cursor + Int(spsCountByte) <= data.count else {
            throw MediaTestFailure("avcC SPS truncated")
        }
        let sps = data[cursor..<(cursor + Int(spsCountByte))]
        cursor += Int(spsCountByte)
        guard cursor + 3 <= data.count else {
            throw MediaTestFailure("avcC PPS missing")
        }
        let ppsCount = Int(data[cursor])
        cursor += 1
        guard ppsCount >= 1,
              let ppsLength = readU16(data, cursor),
              cursor + 2 + Int(ppsLength) <= data.count else {
            throw MediaTestFailure("avcC PPS truncated")
        }
        cursor += 2
        let pps = data[cursor..<(cursor + Int(ppsLength))]
        let initLength = (moov.start + moov.size)
        guard initLength <= data.count else { throw MediaTestFailure("init length exceeds data") }
        return MediaInitInfo(width: Int(width),
                             height: Int(height),
                             codec: String(format: "avc1.%02X%02X%02X", profile, compatibility, level),
                             profile: profile,
                             compatibility: compatibility,
                             level: level,
                             sps: Data(sps),
                             pps: Data(pps),
                             initLength: initLength,
                             initData: data.prefix(initLength))
    }

    static func parseFragments(_ data: Data, initLength: Int) throws -> [MediaFragmentInfo] {
        var result: [MediaFragmentInfo] = []
        var offset = initLength
        while offset + 8 <= data.count {
            let top = boxes(data, from: offset, to: data.count)
            guard let moof = top.first(where: { $0.type == "moof" }) else { break }
            guard let moofIndex = top.firstIndex(where: { $0.start == moof.start }),
                  moofIndex + 1 < top.count else { break }
            let mdat = top[moofIndex + 1]
            guard mdat.type == "mdat" else {
                throw MediaTestFailure("moof not followed by mdat at \(moof.start)")
            }
            guard let mfhd = firstBox(type: "mfhd", in: moof, data: data),
                  let sequence = readU32(data, mfhd.payloadStart + 4) else {
                throw MediaTestFailure("mfhd sequence unreadable")
            }
            guard let traf = firstBox(type: "traf", in: moof, data: data),
                  let tfdt = firstBox(type: "tfdt", in: traf, data: data),
                  let trun = firstBox(type: "trun", in: traf, data: data) else {
                throw MediaTestFailure("traf/tfdt/trun missing")
            }
            let tfdtVersion = data[tfdt.payloadStart]
            let baseDecodeTime: UInt64
            if tfdtVersion == 1 {
                guard let value = readU64(data, tfdt.payloadStart + 4) else {
                    throw MediaTestFailure("tfdt v1 unreadable")
                }
                baseDecodeTime = value
            } else {
                guard let value = readU32(data, tfdt.payloadStart + 4) else {
                    throw MediaTestFailure("tfdt v0 unreadable")
                }
                baseDecodeTime = UInt64(value)
            }
            guard let sampleCount = readU32(data, trun.payloadStart + 4),
                  sampleCount == 1,
                  let dataOffset = readU32(data, trun.payloadStart + 8),
                  let firstFlags = readU32(data, trun.payloadStart + 12),
                  let duration = readU32(data, trun.payloadStart + 16),
                  let sampleSize = readU32(data, trun.payloadStart + 20) else {
                throw MediaTestFailure("trun fields unreadable")
            }
            guard dataOffset == UInt32(moof.size + 8) else {
                throw MediaTestFailure("trun data_offset \(dataOffset) != moofSize+8 \(moof.size + 8)")
            }
            let dependsOn = (firstFlags >> 24) & 0x3
            let nonSync = (firstFlags >> 16) & 0x1
            let keyframe = dependsOn == 2 && nonSync == 0
            let fragmentEnd = mdat.start + mdat.size
            guard fragmentEnd <= data.count else {
                throw MediaTestFailure("mdat exceeds data")
            }
            result.append(MediaFragmentInfo(sequence: sequence,
                                            baseDecodeTime: baseDecodeTime,
                                            duration: duration,
                                            sampleSize: sampleSize,
                                            dataOffset: dataOffset,
                                            keyframe: keyframe,
                                            moofSize: moof.size,
                                            mdatSize: mdat.size,
                                            fragmentSize: moof.size + mdat.size,
                                            raw: data[moof.start..<fragmentEnd]))
            offset = fragmentEnd
        }
        return result
    }
}
