import Foundation

/// Stable families for the built-in generated instruments. These are synth
/// patches, not recordings or claims of sampled acoustic instruments.
public enum MusicPresetCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case keyboard, bass, strings, pad, lead, pluck, bell, percussion, organ

    public func displayName(isChinese: Bool) -> String {
        switch self {
        case .keyboard: isChinese ? "键盘" : "Keys"
        case .bass: isChinese ? "贝斯" : "Bass"
        case .strings: isChinese ? "弦乐" : "Strings"
        case .pad: isChinese ? "氛围" : "Pads"
        case .lead: isChinese ? "主音" : "Leads"
        case .pluck: isChinese ? "拨弦" : "Plucks"
        case .bell: isChinese ? "钟音" : "Bells"
        case .percussion: isChinese ? "打击乐" : "Percussion"
        case .organ: isChinese ? "风琴" : "Organs"
        }
    }
}

/// `index` is persisted in MusicPluginState.presetIndex. Never reorder or
/// reuse an index for a different sound; extend the catalog with new indices.
public struct MusicInstrumentPreset: Identifiable, Hashable, Codable, Sendable {
    public var id: Int { index }
    public let index: Int
    public let category: MusicPresetCategory
    public let nameEN: String
    public let nameZH: String
    /// Complete patch defaults. A plugin state's parameters override these
    /// values; an empty dictionary selects the unmodified preset.
    public let parameters: [String: Double]

    public func displayName(isChinese: Bool) -> String { isChinese ? nameZH : nameEN }
}

public enum MusicPresetCatalog {
    public static let electronicDrumKitIndex = 40

    /// Waveform codes: 0 sine, 1 saw, 2 triangle, 3 square, 4 pulse,
    /// 5 additive harmonics, 6 FM, 7 filtered noise, 8 GM electronic kit.
    /// Native live playback and offline rendering interpret the same values.
    public static let all: [MusicInstrumentPreset] = [
        // 0/1 retain the original waveform, envelope and gain exactly.
        patch(0, .lead, "Sine synthesizer", "纯音合成器", 0),
        patch(1, .lead, "Saw synthesizer", "锯齿合成器", 1),
        patch(2, .keyboard, "Soft synth keys", "柔和合成键盘", 6,
              attack: 0.004, decay: 1.4, sustain: 0.14, release: 0.22, gain: 0.9,
              tone: ["fmRatio": 1, "fmIndex": 0.65]),
        patch(3, .keyboard, "Bright electric keys", "明亮电键盘", 6,
              attack: 0.002, decay: 0.9, sustain: 0.12, release: 0.16, gain: 0.8,
              tone: ["fmRatio": 3, "fmIndex": 1.8]),
        patch(4, .keyboard, "Reed electric keys", "簧片电键盘", 6,
              attack: 0.006, decay: 0.7, sustain: 0.25, release: 0.18, gain: 0.85,
              tone: ["fmRatio": 2, "fmIndex": 1.25, "lowpass": 5_500]),
        patch(5, .keyboard, "Glass electric keys", "玻璃电键盘", 6,
              attack: 0.001, decay: 1.1, sustain: 0.05, release: 0.3, gain: 0.8,
              tone: ["fmRatio": 7, "fmIndex": 0.9]),
        patch(6, .keyboard, "Clav synth keys", "击弦合成键盘", 5,
              attack: 0.001, decay: 0.18, sustain: 0.12, release: 0.05, gain: 0.95,
              tone: ["harmonic2": 0.7, "harmonic3": 0.2, "harmonic4": 0.45, "harmonic6": 0.22]),
        patch(7, .keyboard, "Toy synth keys", "玩具合成键盘", 5,
              attack: 0.002, decay: 0.55, sustain: 0.04, release: 0.12, gain: 0.95,
              tone: ["harmonic3": 0.35, "harmonic4": 0.08, "harmonic7": 0.18]),
        patch(8, .bass, "Sub synth bass", "超低合成贝斯", 0,
              attack: 0.006, decay: 0.16, sustain: 0.85, release: 0.055, gain: 1,
              tone: ["transpose": -12]),
        patch(9, .bass, "Round synth bass", "圆润合成贝斯", 2,
              attack: 0.003, decay: 0.24, sustain: 0.48, release: 0.075, gain: 1,
              tone: ["lowpass": 1_800]),
        patch(10, .bass, "Saw synth bass", "锯齿合成贝斯", 1,
              attack: 0.004, decay: 0.12, sustain: 0.6, release: 0.06, gain: 0.9,
              tone: ["lowpass": 1_200]),
        patch(11, .bass, "Square synth bass", "方波合成贝斯", 3,
              attack: 0.002, decay: 0.15, sustain: 0.52, release: 0.04, gain: 0.8,
              tone: ["lowpass": 1_600]),
        patch(12, .bass, "FM synth bass", "调频合成贝斯", 6,
              attack: 0.001, decay: 0.32, sustain: 0.24, release: 0.09, gain: 0.9,
              tone: ["fmRatio": 1, "fmIndex": 2.4, "lowpass": 3_200]),
        patch(13, .bass, "Plucked synth bass", "拨弦合成贝斯", 5,
              attack: 0.002, decay: 0.45, sustain: 0.08, release: 0.07, gain: 1,
              tone: ["harmonic2": 0.45, "harmonic3": 0.24, "harmonic4": 0.12, "lowpass": 2_400]),
        patch(14, .strings, "Slow synth strings", "渐入合成弦乐", 1,
              attack: 0.32, decay: 0.4, sustain: 0.8, release: 0.65, gain: 0.75,
              tone: ["lowpass": 3_800, "detune": -3]),
        patch(15, .strings, "Chamber synth strings", "室内合成弦乐", 5,
              attack: 0.1, decay: 0.25, sustain: 0.7, release: 0.28, gain: 0.85,
              tone: ["harmonic2": 0.65, "harmonic3": 0.42, "harmonic4": 0.25, "harmonic5": 0.16, "harmonic6": 0.1]),
        patch(16, .strings, "Bowed synth", "弓弦合成音", 4,
              attack: 0.15, decay: 0.3, sustain: 0.65, release: 0.4, gain: 0.7,
              tone: ["pulseWidth": 0.4, "lowpass": 2_800, "detune": 2]),
        patch(17, .pad, "Warm synth pad", "温暖合成氛围", 2,
              attack: 0.55, decay: 0.8, sustain: 0.75, release: 1.1, gain: 0.9,
              tone: ["lowpass": 2_500]),
        patch(18, .pad, "Air synth pad", "轻盈合成氛围", 5,
              attack: 0.7, decay: 0.6, sustain: 0.7, release: 1.4, gain: 0.85,
              tone: ["harmonic2": 0.12, "harmonic5": 0.3, "harmonic8": 0.18]),
        patch(19, .pad, "Hollow synth pad", "空灵合成氛围", 5,
              attack: 0.4, decay: 0.7, sustain: 0.6, release: 0.9, gain: 0.9,
              tone: ["harmonic3": 0.65, "harmonic5": 0.32, "harmonic7": 0.2]),
        patch(20, .pad, "Shimmer synth pad", "闪耀合成氛围", 6,
              attack: 0.8, decay: 1.2, sustain: 0.55, release: 1.6, gain: 0.75,
              tone: ["fmRatio": 3.5, "fmIndex": 1.1]),
        patch(21, .lead, "Pure synth lead", "柔亮合成主音", 5,
              attack: 0.012, decay: 0.1, sustain: 0.85, release: 0.1, gain: 0.95,
              tone: ["harmonic2": 0.2, "harmonic3": 0.08]),
        patch(22, .lead, "Bright saw lead", "明亮锯齿主音", 1,
              attack: 0.003, decay: 0.18, sustain: 0.7, release: 0.12, gain: 0.75,
              tone: ["lowpass": 8_000, "detune": 4]),
        patch(23, .lead, "Square synth lead", "方波合成主音", 3,
              attack: 0.005, decay: 0.12, sustain: 0.65, release: 0.08, gain: 0.7,
              tone: ["lowpass": 7_000]),
        patch(24, .lead, "Pulse synth lead", "脉冲合成主音", 4,
              attack: 0.002, decay: 0.2, sustain: 0.72, release: 0.09, gain: 0.8,
              tone: ["pulseWidth": 0.18, "lowpass": 6_000]),
        patch(25, .lead, "Brass synth lead", "铜管合成主音", 5,
              attack: 0.055, decay: 0.22, sustain: 0.75, release: 0.13, gain: 0.85,
              tone: ["harmonic2": 0.8, "harmonic3": 0.58, "harmonic4": 0.25, "harmonic5": 0.12]),
        patch(26, .lead, "Reed synth lead", "簧管合成主音", 5,
              attack: 0.025, decay: 0.12, sustain: 0.82, release: 0.11, gain: 0.9,
              tone: ["harmonic3": 0.8, "harmonic5": 0.35, "harmonic7": 0.12]),
        patch(27, .pluck, "Soft synth pluck", "柔和合成拨弦", 5,
              attack: 0.003, decay: 0.38, sustain: 0.02, release: 0.16, gain: 1,
              tone: ["harmonic2": 0.32, "harmonic3": 0.12]),
        patch(28, .pluck, "Bright synth pluck", "明亮合成拨弦", 4,
              attack: 0.001, decay: 0.22, sustain: 0, release: 0.1, gain: 0.85,
              tone: ["pulseWidth": 0.3, "lowpass": 9_000]),
        patch(29, .pluck, "Harp synth pluck", "竖琴合成拨弦", 5,
              attack: 0.002, decay: 1.1, sustain: 0, release: 0.32, gain: 1,
              tone: ["harmonic2": 0.55, "harmonic3": 0.28, "harmonic4": 0.14, "harmonic5": 0.06]),
        patch(30, .pluck, "FM synth mallet", "调频合成槌音", 6,
              attack: 0.001, decay: 0.42, sustain: 0, release: 0.2, gain: 0.95,
              tone: ["fmRatio": 2, "fmIndex": 0.8]),
        patch(31, .bell, "Soft synth bell", "柔和合成钟音", 6,
              attack: 0.001, decay: 1.8, sustain: 0, release: 0.65, gain: 0.9,
              tone: ["fmRatio": 1.4, "fmIndex": 2]),
        patch(32, .bell, "Crystal synth bell", "水晶合成钟音", 6,
              attack: 0.002, decay: 1.3, sustain: 0, release: 0.5, gain: 0.8,
              tone: ["fmRatio": 3.5, "fmIndex": 3.2]),
        patch(33, .bell, "Tubular synth bell", "管状合成钟音", 6,
              attack: 0.001, decay: 2.3, sustain: 0, release: 0.8, gain: 0.8,
              tone: ["fmRatio": 1.414, "fmIndex": 5.5]),
        patch(34, .bell, "Synth music box", "合成八音盒", 6,
              attack: 0.001, decay: 0.8, sustain: 0, release: 0.3, gain: 0.85,
              tone: ["fmRatio": 3, "fmIndex": 1.2, "transpose": 12]),
        patch(35, .percussion, "Electronic kick", "电子底鼓", 0,
              attack: 0.001, decay: 0.1, sustain: 0, release: 0.03, gain: 1,
              tone: ["fixedNote": 36, "lowpass": 350]),
        patch(36, .percussion, "Electronic tom", "电子通鼓", 6,
              attack: 0.001, decay: 0.22, sustain: 0, release: 0.06, gain: 0.9,
              tone: ["fmRatio": 1.4, "fmIndex": 0.6, "fixedNote": 48, "lowpass": 2_500]),
        patch(37, .percussion, "Noise snare", "噪声军鼓", 7,
              attack: 0.001, decay: 0.14, sustain: 0, release: 0.045, gain: 1,
              tone: ["highpass": 900, "lowpass": 9_000]),
        patch(38, .percussion, "Closed hi-hat", "闭合踩镲", 7,
              attack: 0.001, decay: 0.045, sustain: 0, release: 0.02, gain: 0.85,
              tone: ["highpass": 7_000, "lowpass": 18_000]),
        patch(39, .organ, "Tonewheel synth organ", "音轮合成风琴", 5,
              attack: 0.005, decay: 0.06, sustain: 0.9, release: 0.06, gain: 0.9,
              tone: ["harmonic2": 0.6, "harmonic3": 0.8, "harmonic4": 0.15,
                     "harmonic5": 0.3, "harmonic6": 0.08, "harmonic7": 0.2, "harmonic8": 0.1]),
        patch(40, .percussion, "Electronic drum kit", "电子鼓组", 8,
              attack: 0.001, decay: 0.18, sustain: 0, release: 0.04)
    ]

    public static func preset(index: Int) -> MusicInstrumentPreset? {
        all.first { $0.index == index }
    }

    private static func patch(_ index: Int, _ category: MusicPresetCategory,
                              _ en: String, _ zh: String, _ waveform: Double,
                              attack: Double = 0.008, decay: Double = 0.08,
                              sustain: Double = 0.75, release: Double = 0.08,
                              gain: Double = 1, tone: [String: Double] = [:]) -> MusicInstrumentPreset {
        var parameters = ["waveform": waveform, "attack": attack, "decay": decay,
                          "sustain": sustain, "release": release, "gain": gain]
        parameters.merge(tone) { _, replacement in replacement }
        return MusicInstrumentPreset(index: index, category: category, nameEN: en, nameZH: zh, parameters: parameters)
    }
}
