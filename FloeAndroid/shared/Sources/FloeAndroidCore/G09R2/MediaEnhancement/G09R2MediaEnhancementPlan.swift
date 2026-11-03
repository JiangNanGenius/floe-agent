// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 media enhancement — guest execution plan and output parsing.
//
// Pure, side-effect-free builders: given validated contract inputs they emit
// the exact shell script run inside the task Linux guest through the original
// `exec.shell` durable-job path, plus the parsers that turn the guest's real
// machine-readable output (`ffprobe` JSON, ffmpeg `-progress` files) into
// measured facts. Nothing here invents progress or success.
import Foundation

// MARK: - Guest layout

/// Canonical layout of one enhancement job inside the task workspace. The
/// guest sees the task workspace at `/workspace`; the same directory is the
/// app-side workspace root, so the service can read the progress file and the
/// staged output directly while the job runs.
public struct G09R2EnhancementGuestLayout: Sendable, Equatable {
    /// Workspace-relative staging directory for this job.
    public var stagingRelativeDir: String
    public var inputRelativePath: String
    public var outputRelativePath: String
    public var progressRelativePath: String
    public var ffmpegLogRelativePath: String

    public init(jobID: String, inputRelativePath: String, outputFileName: String) {
        let safeJob = jobID.lowercased()
        let safeInput = (inputRelativePath as NSString).lastPathComponent
        let safeOutput = (outputFileName as NSString).lastPathComponent
        self.stagingRelativeDir = ".floe-enhance/\(safeJob)"
        self.inputRelativePath = "\(self.stagingRelativeDir)/input-\(safeInput)"
        self.outputRelativePath = "\(self.stagingRelativeDir)/\(safeOutput).part"
        self.progressRelativePath = "\(self.stagingRelativeDir)/progress.txt"
        self.ffmpegLogRelativePath = "\(self.stagingRelativeDir)/ffmpeg.log"
    }
}

// MARK: - Shell escaping

public enum G09R2EnhancementShellQuote {
    /// Single-quote `value` for POSIX sh, so user-influenced file names can
    /// never break out of the command. Bounded by the caller.
    public static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - ffmpeg plan

/// Builds the exact guest shell script for motion interpolation.
///
/// Script contract (machine-readable, deterministic):
///   1. `command -v ffmpeg/ffprobe` — tool discovery; missing tools print
///      `ENH_ERROR=toolsMissing` and exit 126.
///   2. `ENH_PROBE_IN:` + ffprobe JSON of the staged input.
///   3. ffmpeg minterpolate to the staged output (explicit `-f mp4` muxer:
///      the staged name ends in `.part` so ffmpeg cannot infer the container
///      from any extension), machine progress to the progress file, human
///      stats to the log.
///   4. On ffmpeg failure: `ENH_ERROR=ffmpegExit:<code>` and exit 1.
///   5. `ENH_PROBE_OUT:` + ffprobe JSON of the staged output; exit 0.
public enum G09R2EnhancementFFmpegPlan {
    public static let probeEntryPrefix = "ENH_PROBE_IN:"
    public static let probeOutPrefix = "ENH_PROBE_OUT:"
    public static let errorPrefix = "ENH_ERROR="

    public struct Plan: Sendable, Equatable {
        public var script: String
        public var expectedDurationBoundSeconds: Double
    }

    public static func interpolationScript(
        layout: G09R2EnhancementGuestLayout,
        targetFPS: Double,
        sourceHasAudio: Bool,
        limits: G09R2EnhancementLimits = .standard
    ) -> Plan {
        let fps = Int(targetFPS.rounded())
        // minterpolate with motion-compensated bidirectional interpolation;
        // x264 veryfast keeps the guest job inside the background budget for
        // the bounded source sizes the guards admit.
        let audioArgs = sourceHasAudio ? "-c:a copy" : ""
        let script = """
        set -u
        if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
          echo '\(errorPrefix)toolsMissing'
          exit 126
        fi
        INPUT=\(G09R2EnhancementShellQuote.quoted(layout.inputRelativePath))
        OUTPUT=\(G09R2EnhancementShellQuote.quoted(layout.outputRelativePath))
        PROGRESS=\(G09R2EnhancementShellQuote.quoted(layout.progressRelativePath))
        FFLOG=\(G09R2EnhancementShellQuote.quoted(layout.ffmpegLogRelativePath))
        echo '\(probeEntryPrefix)'
        ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,avg_frame_rate,nb_frames,duration,color_transfer,color_primaries -show_entries format=duration -of json "$INPUT" || true
        ffmpeg -hide_banner -nostdin -y -i "$INPUT" \
          -vf minterpolate=fps=\(fps):mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1 \
          -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p \(audioArgs) \
          -f mp4 -progress "$PROGRESS" -nostats "$OUTPUT" 2>"$FFLOG"
        CODE=$?
        if [ "$CODE" -ne 0 ]; then
          echo "\(errorPrefix)ffmpegExit:$CODE"
          exit 1
        fi
        echo '\(probeOutPrefix)'
        ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,avg_frame_rate,nb_frames,duration,color_transfer,color_primaries -show_entries format=duration -of json "$OUTPUT" || true
        exit 0
        """
        return Plan(
            script: script,
            expectedDurationBoundSeconds: limits.maximumDurationSeconds)
    }

    /// Standalone probe script used by the preflight step (before validation
    /// and before any enhancement invocation).
    public static func probeScript(inputRelativePath: String) -> String {
        let input = G09R2EnhancementShellQuote.quoted(inputRelativePath)
        return """
        set -u
        if ! command -v ffprobe >/dev/null 2>&1; then
          echo '\(errorPrefix)toolsMissing'
          exit 126
        fi
        echo '\(probeEntryPrefix)'
        ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,avg_frame_rate,nb_frames,duration,color_transfer,color_primaries -show_entries format=duration -of json \(input) || true
        exit 0
        """
    }
}

// MARK: - Output parsing

public enum G09R2EnhancementParsingError: Error, Sendable, Equatable {
    case malformedProbe(String)
    case missingProbe
}

/// Parses the guest ffprobe JSON into measured facts. Field extraction is
/// defensive: anything unusable is nil and surfaces as `sourceUnreadable`
/// downstream instead of a guessed value.
public enum G09R2EnhancementProbeParser {
    /// ffprobe reports `nb_frames` as a JSON STRING for ordinary MP4 (real
    /// host evidence: `"nb_frames": "48"`); some containers emit a bare
    /// number and "N/A" marks unknown. Accept every numeric spelling and
    /// treat "N/A"/malformed values as unknown (nil) — never fail the whole
    /// probe on the field type, never trap.
    private struct FlexibleFrameCount: Decodable {
        var value: Int?
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intValue = try? container.decode(Int.self) {
                value = intValue
            } else if let stringValue = try? container.decode(String.self) {
                let trimmed = stringValue.trimmingCharacters(in: .whitespaces)
                guard trimmed != "N/A", !trimmed.isEmpty else {
                    value = nil
                    return
                }
                value = Int(trimmed)
            } else {
                value = nil
            }
        }
    }

    private struct ProbeStream: Decodable {
        var codec_type: String?
        var codec_name: String?
        var width: Int?
        var height: Int?
        var avg_frame_rate: String?
        var nb_frames: FlexibleFrameCount?
        var duration: String?
        var color_transfer: String?
        var color_primaries: String?
    }

    private struct ProbeFormat: Decodable {
        var duration: String?
    }

    private struct Probe: Decodable {
        var streams: [ProbeStream]?
        var format: ProbeFormat?
    }

    /// Hard sanity bound for derived frame arithmetic. Anything above this
    /// is refused before any `Int` conversion (a hostile/overflowing
    /// duration such as "1e300" must refuse, never trap); legitimate
    /// bounded refusals stay with the typed downstream guards.
    private static let maximumDerivedFrames = Double(Int32.max)

    public static func parseVideoFacts(
        _ jsonText: String,
        byteCount: Int64,
        sha256: String
    ) throws -> G09R2MediaProbeFacts {
        guard let data = jsonText.data(using: .utf8) else {
            throw G09R2EnhancementParsingError.malformedProbe("notUTF8")
        }
        let probe: Probe
        do {
            probe = try JSONDecoder().decode(Probe.self, from: data)
        } catch {
            throw G09R2EnhancementParsingError.malformedProbe("invalidJSON")
        }
        guard let streams = probe.streams, !streams.isEmpty else {
            throw G09R2EnhancementParsingError.missingProbe
        }
        // Explicit video-stream selection: prefer the declared video
        // codec_type; fixtures/outputs without codec_type fall back to the
        // first geometry-bearing stream. An audio-first container therefore
        // never misidentifies its audio stream as the video track.
        let videoStream = streams.first(where: {
            $0.codec_type?.lowercased() == "video"
        }) ?? streams.first(where: { $0.width != nil && $0.height != nil })
        guard let stream = videoStream else {
            throw G09R2EnhancementParsingError.missingProbe
        }
        // Audio presence is MEASURED from the full all-streams probe (the
        // probe commands no longer select v:0 only); probes without
        // codec_type report no audio, matching the historical contract.
        let hasAudio = streams.contains { $0.codec_type?.lowercased() == "audio" }
        let rate = stream.avg_frame_rate.flatMap(rationalFPS)
        let streamDuration = stream.duration.flatMap(Double.init)
        let formatDuration = probe.format?.duration.flatMap(Double.init)
        let duration = [streamDuration, formatDuration].compactMap { $0 }.max() ?? 0
        let frames: Int
        if let explicitFrames = stream.nb_frames?.value {
            frames = explicitFrames
        } else if let rate, duration > 0 {
            // Finite/bounded arithmetic BEFORE the Int conversion: a
            // non-finite or overflowing product (e.g. duration "1e300")
            // refuses typed instead of trapping.
            let estimate = (duration * rate).rounded()
            guard estimate.isFinite, estimate <= Self.maximumDerivedFrames else {
                throw G09R2EnhancementParsingError.malformedProbe(
                    "unboundedDerivedFrames")
            }
            frames = Int(estimate)
        } else {
            frames = 0
        }
        guard let width = stream.width, let height = stream.height,
              width > 0, height > 0, duration > 0 else {
            throw G09R2EnhancementParsingError.malformedProbe("missingGeometry")
        }
        // HDR detection: PQ or HLG transfer characteristics (explicit SDR
        // tags smpte170m/bt709 stay SDR).
        let transfer = stream.color_transfer?.lowercased() ?? ""
        let isHDR = transfer.contains("smpte2084")
            || transfer.contains("arib-std-b67")
            || transfer.contains("hlg")
        return G09R2MediaProbeFacts(
            isImage: false,
            width: width,
            height: height,
            durationSeconds: duration,
            frameRate: rate ?? 0,
            frameCount: frames,
            hasAudio: hasAudio,
            codec: stream.codec_name,
            isHDR: isHDR,
            byteCount: byteCount,
            sha256: sha256)
    }

    /// Parses an ffmpeg `-progress` file (key=value lines) into the latest
    /// completed frame count. Returns nil when no frame line exists yet.
    public static func latestFrame(fromProgressText text: String) -> Int? {
        var latest: Int?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == "frame" else { continue }
            latest = Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return latest
    }

    /// Extracts the machine-readable blocks from the merged job output.
    /// Returns (inputJSON, outputJSON, errorToken).
    public static func blocks(
        fromJobOutput text: String
    ) -> (input: String?, output: String?, error: String?) {
        var inputJSON: String?
        var outputJSON: String?
        var errorToken: String?
        var collecting: String?
        var buffer = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if line.hasPrefix(G09R2EnhancementFFmpegPlan.probeEntryPrefix) {
                collecting = "input"
                buffer = ""
                continue
            }
            if line.hasPrefix(G09R2EnhancementFFmpegPlan.probeOutPrefix) {
                if collecting == "input" { inputJSON = buffer }
                collecting = "output"
                buffer = ""
                continue
            }
            if line.hasPrefix(G09R2EnhancementFFmpegPlan.errorPrefix) {
                errorToken = String(line.dropFirst(G09R2EnhancementFFmpegPlan.errorPrefix.count))
                collecting = nil
                continue
            }
            if let mode = collecting {
                buffer += line + "\n"
                if mode == "input" { /* keep appending */ }
            }
        }
        if collecting == "output" { outputJSON = buffer }
        return (inputJSON, outputJSON, errorToken)
    }

    static func rationalFPS(_ text: String) -> Double? {
        let parts = text.split(separator: "/")
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              denominator > 0 else { return nil }
        let value = numerator / denominator
        return value.isFinite && value > 0 ? value : nil
    }
}
