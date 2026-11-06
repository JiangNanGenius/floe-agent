// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCanvasCore
import CryptoKit

// MARK: - Qualification CLI
//
// `floe-canvas-examples qualify --output <ABS_DIR>` runs the executable
// qualification harness (synthetic archive, interop round trip, scale
// benchmark, offline flow harness) and writes machine-readable PASS/FAIL/
// unverified results under an explicit output root that MUST live inside the
// repository's Local/Private or Local/Artifacts tree. Running with no
// arguments preserves the original P0.1 compatibility baseline unchanged.

enum QualifyCLI {
    struct Options {
        var outputRoot: URL
        var fixtures: URL?
        var sizes: [Int]
        var skipSynthetic = false
        var skipInterop = false
        var skipBenchmark = false
        var skipFlow = false
    }

    enum ParseError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self {
            case .message(let text): return text
            }
        }
    }

    static let usage = """
        usage:
          floe-canvas-examples                                  (P0.1 baseline, unchanged)
          floe-canvas-examples qualify --output <ABS_DIR> [--fixtures <ABS_DIR>] \
        [--sizes 500,3000,10000] [--skip-synthetic] [--skip-interop] \
        [--skip-benchmark] [--skip-flow]

        --output must be an absolute path inside the repository's \
        Local/Private or Local/Artifacts directory. Existing runs are preserved: \
        a non-empty destination gets a fresh "-N" sibling directory.
        --fixtures defaults to $FLOE_CANVAS_INTEROP_FIXTURES, then to a \
        Local/Private/infinite-canvas-qualification-20261103/interop-fixtures \
        search upward from the sources.
        """

    static func parse(_ arguments: [String]) throws -> Options {
        var output: String?
        var fixtures: String?
        var sizes = [500, 3000, 10_000]
        var skipSynthetic = false
        var skipInterop = false
        var skipBenchmark = false
        var skipFlow = false

        var index = 0
        func requireValue(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw ParseError.message("\(flag) requires a value\n\(usage)")
            }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--output": output = try requireValue(argument)
            case "--fixtures": fixtures = try requireValue(argument)
            case "--sizes":
                let raw = try requireValue(argument)
                sizes = try raw.split(separator: ",").map { piece in
                    guard let value = Int(piece), value > 0 else {
                        throw ParseError.message("invalid --sizes entry '\(piece)'")
                    }
                    return value
                }
                guard !sizes.isEmpty else {
                    throw ParseError.message("--sizes must not be empty")
                }
            case "--skip-synthetic": skipSynthetic = true
            case "--skip-interop": skipInterop = true
            case "--skip-benchmark": skipBenchmark = true
            case "--skip-flow": skipFlow = true
            default:
                throw ParseError.message("unknown argument '\(argument)'\n\(usage)")
            }
            index += 1
        }
        guard let output, !output.isEmpty else {
            throw ParseError.message("qualify requires --output <ABS_DIR>\n\(usage)")
        }
        let outputURL = URL(fileURLWithPath: output, isDirectory: true)
        guard output.hasPrefix("/") else {
            throw ParseError.message("--output must be an absolute path")
        }
        let root = try guardedOutputRoot(outputURL)
        let fixturesURL = try resolveFixtures(explicit: fixtures)
        return Options(
            outputRoot: root,
            fixtures: fixturesURL,
            sizes: sizes,
            skipSynthetic: skipSynthetic,
            skipInterop: skipInterop || fixturesURL == nil,
            skipBenchmark: skipBenchmark,
            skipFlow: skipFlow)
    }

    /// The output root must stay inside the repo-local private/artifact tree
    /// so qualification artifacts never land in production-adjacent paths.
    private static func guardedOutputRoot(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        var ancestor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var repository: URL?
        while ancestor.path != "/" {
            if FileManager.default.fileExists(atPath: ancestor
                .appendingPathComponent("FloeAgent/Modules/FloeCanvasKit/Package.swift").path) {
                repository = ancestor.resolvingSymlinksInPath()
                break
            }
            ancestor.deleteLastPathComponent()
        }
        guard let repository else {
            throw ParseError.message("Cannot resolve this qualification source repository")
        }
        let allowed = ["Private", "Artifacts"].map {
            repository.appendingPathComponent("Local/\($0)").standardizedFileURL.path + "/"
        }
        guard allowed.contains(where: { standardized.path.hasPrefix($0) }) else {
            throw ParseError.message(
                "--output must live under this repository's Local/Private or "
                + "Local/Artifacts tree; got \(standardized.path)")
        }
        return standardized
    }

    static let fixturesEnvironmentKey = "FLOE_CANVAS_INTEROP_FIXTURES"

    private static func resolveFixtures(explicit: String?) throws -> URL? {
        if let explicit, !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit, isDirectory: true)
            guard url.path.hasPrefix("/") else {
                throw ParseError.message("--fixtures must be an absolute path")
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ParseError.message("fixtures directory not found: \(url.path)")
            }
            return url.standardizedFileURL
        }
        if let env = ProcessInfo.processInfo.environment[fixturesEnvironmentKey],
           !env.isEmpty {
            let url = URL(fileURLWithPath: env, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                return url.standardizedFileURL
            }
        }
        // Upward search from this source file (12 levels covers the package
        // nesting inside the repository).
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<12 {
            url.deleteLastPathComponent()
            let candidate = url
                .appendingPathComponent("Local", isDirectory: true)
                .appendingPathComponent("Private", isDirectory: true)
                .appendingPathComponent("infinite-canvas-qualification-20261103", isDirectory: true)
                .appendingPathComponent("interop-fixtures", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Creates the run directory, keeping any previous run intact.
    static func makeRunDirectory(under root: URL) throws -> URL {
        let stamp = QualifyIO.timestampSlug()
        var candidate = root.appendingPathComponent("run-\(stamp)", isDirectory: true)
        var suffix = 1
        let manager = FileManager.default
        while manager.fileExists(atPath: candidate.path),
              try !manager.contentsOfDirectory(atPath: candidate.path).isEmpty {
            suffix += 1
            candidate = root.appendingPathComponent("run-\(stamp)-\(suffix)", isDirectory: true)
        }
        try manager.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }
}

// MARK: - Check reporting

enum CheckStatus: String, Codable, Sendable {
    case pass
    case fail
    case unverified
}

struct Check: Codable, Sendable {
    var id: String
    var scenario: String
    var status: CheckStatus
    var detail: String
    var evidence: [String]
}

struct ScenarioReport: Codable, Sendable {
    var scenario: String
    var checks: [Check]
    var artifacts: [String]
    var notes: [String]
}

struct QualifySummary: Codable, Sendable {
    var command: String
    var base: BaseInfo
    var scenarios: [ScenarioReport]
    var totals: Totals
}

struct BaseInfo: Codable, Sendable {
    var platform: String
    var osVersion: String
    var buildConfiguration: String
    var hostDescription: String
    var machine: String
    var source: String
}

struct Totals: Codable, Sendable {
    var pass: Int
    var fail: Int
    var unverified: Int
}

/// Scenario results are owned by this actor: no mutable global state, so the
/// strict Swift 6 concurrency diagnostics stay clean without escapes.
actor QualifyReporter {
    private var scenarios: [ScenarioReport] = []

    func emit(_ report: ScenarioReport) {
        scenarios.append(report)
    }

    func summary(command: String) -> QualifySummary {
        let all = scenarios.flatMap(\.checks)
        return QualifySummary(
            command: command,
            base: BaseInfo.current(),
            scenarios: scenarios,
            totals: Totals(
                pass: all.filter { $0.status == .pass }.count,
                fail: all.filter { $0.status == .fail }.count,
                unverified: all.filter { $0.status == .unverified }.count))
    }
}

extension BaseInfo {
    static func current() -> BaseInfo {
        let process = ProcessInfo.processInfo
        #if targetEnvironment(simulator)
        let platform = "iOS Simulator"
        #elseif os(iOS)
        let platform = "iOS device"
        #elseif os(macOS)
        let platform = "macOS"
        #else
        let platform = "unknown"
        #endif
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        var machine = "unknown"
        #if canImport(Darwin)
        var mib = [CTL_HW, HW_MACHINE]
        var size = 0
        sysctl(&mib, 2, nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctl(&mib, 2, &buffer, &size, nil, 0)
        machine = String(cString: buffer)
        #endif
        return BaseInfo(
            platform: platform,
            osVersion: process.operatingSystemVersionString,
            buildConfiguration: configuration,
            hostDescription: process.hostName,
            machine: machine,
            source: "FloeCanvasKit/Sources/FloeCanvasExamples (P4a qualification harness)")
    }
}

// MARK: - Filesystem / encoding helpers

enum QualifyIO {
    /// Writes `data` to `directory/name` with staged atomic replace; refuses
    /// to overwrite an existing file so reruns never corrupt prior evidence.
    static func write(_ data: Data, to directory: URL, name: String) throws -> String {
        let safe = sanitize(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(safe)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw CanvasKitError.io("refusing to overwrite existing artifact \(safe)")
        }
        try CanvasAtomicFileWrite.write(data, to: destination)
        return safe
    }

    /// Safe artifact filename: keeps CJK/alphanumerics/dots/dashes, maps the
    /// rest to '-', never lets a component escape the directory.
    static func sanitize(_ name: String) -> String {
        var mapped = name.map { character -> Character in
            if character.isLetter || character.isNumber
                || character == "." || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        // Collapse runs of separators.
        var collapsed: [Character] = []
        for character in mapped {
            if character == "-", collapsed.last == "-" { continue }
            collapsed.append(character)
        }
        mapped = collapsed
        var result = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if result.isEmpty { result = "artifact" }
        if result.hasPrefix(".") { result = "artifact" + result }
        return result
    }

    static func encodeJSON<T: Encodable>(_ value: T, pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return try encoder.encode(value)
    }

    static func timestampSlug() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}

/// Staged atomic write identical in discipline to the kit's
/// `CanvasAtomicFile` (the exchange module owns that symbol; the harness
/// keeps its own copy so the Examples target stays dependency-light).
enum CanvasAtomicFileWrite {
    static func write(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(staging.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw CanvasKitError.io("stage output: \(errno)")
        }
        var descriptorOpen = true
        defer {
            if descriptorOpen { _ = close(fd) }
            _ = unlink(staging.path)
        }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                #if canImport(Darwin)
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                #else
                let count = Glibc.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                #endif
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CanvasKitError.io("write staged output: \(errno)")
                }
                guard count > 0 else { throw CanvasKitError.io("short write") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else {
            throw CanvasKitError.io("flush staged output: \(errno)")
        }
        _ = close(fd)
        descriptorOpen = false
        guard rename(staging.path, destination.path) == 0 else {
            throw CanvasKitError.io("replace output: \(errno)")
        }
    }
}

// MARK: - Deterministic RNG (SplitMix64)

struct DeterministicRNG: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func double() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func int(through limit: Int) -> Int {
        Int(next() % UInt64(limit + 1))
    }
}

// MARK: - Process memory sampling (actual measurement or explicit nil)

enum MemorySampler {
    struct Sample: Codable, Sendable {
        /// Resident size in bytes from `task_vm_info`, or nil when the
        /// platform cannot provide it. This is a point-in-time resident
        /// figure, not a peak.
        var residentBytes: Int64?
        var label: String
    }

    static func take() -> Sample {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return Sample(
                residentBytes: nil,
                label: "task_vm_info unavailable (kern_return_t \(result)); memory unverified")
        }
        return Sample(
            residentBytes: Int64(info.resident_size),
            label: "task_vm_info resident_size point-in-time (not peak)")
        #else
        return Sample(
            residentBytes: nil,
            label: "process memory sampling unavailable on this platform")
        #endif
    }
}

// MARK: - Timing

struct MeasureClock: Sendable {
    var label: String

    func measure<R>(_ body: () throws -> R) rethrows -> (result: R, seconds: Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try body()
        let end = DispatchTime.now().uptimeNanoseconds
        return (result, Double(end - start) / 1e9)
    }

    func measureAsync<R>(_ body: () async throws -> R) async rethrows -> (result: R, seconds: Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try await body()
        let end = DispatchTime.now().uptimeNanoseconds
        return (result, Double(end - start) / 1e9)
    }
}

extension Double {
    /// Milliseconds rounded to 3 decimals for stable, honest reporting.
    var milliseconds: Double {
        (self * 1000 * 1000).rounded() / 1000
    }
}
