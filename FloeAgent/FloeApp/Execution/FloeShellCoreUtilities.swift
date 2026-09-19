// FloeApp — small POSIX utilities implemented on the app-side shell registry.
//
// The bundled shell engine (commandDictionary.plist) does not ship `id`,
// `cut`, `locale`, `basename`, `dirname`, `true` or `false`; the device
// report confirmed all of them missing. These are small enough to implement
// honestly on the app-side registry through the same handler contract as
// `sha256sum`/`sleep`: they run on device, need no artifact, and never claim
// a capability the code below does not actually provide. The reviewed tool
// route catalog (capability-hub/tool-catalog.json) lists them as `direct`
// and `capability-hub/build.py --check-tools` verifies the registration
// literals against this file, so the catalog cannot drift from the binary.

import Foundation
import Darwin

enum FloeShellCoreUtilities {
    // MARK: - id

    /// Real uid/gid report. Names come from getpwuid/getgrgid and are omitted
    /// (never fabricated) when the sandbox refuses a directory lookup.
    static func idReport(arguments: [String]) -> (text: String, code: Int32) {
        let flags = Set(arguments.dropFirst().filter { $0.hasPrefix("-") }.flatMap { $0.dropFirst() })
        let unknown = flags.subtracting(["u", "g", "G", "n"])
        guard unknown.isEmpty else {
            return ("id: unknown option -\(unknown.sorted().first!)", 2)
        }
        let numericNames = !flags.contains("n")
        func account(_ id: UInt32, _ numeric: String, _ lookup: (UInt32) -> String?) -> String {
            guard !numericNames, let name = lookup(id) else { return numeric }
            return "\(numeric)(\(name))"
        }
        func userName(_ id: UInt32) -> String? {
            guard let entry = getpwuid(id) else { return nil }
            return String(cString: entry.pointee.pw_name)
        }
        func groupName(_ id: UInt32) -> String? {
            guard let entry = getgrgid(id) else { return nil }
            return String(cString: entry.pointee.gr_name)
        }
        let uid = getuid(), gid = getgid()
        var supplementary = [gid_t](repeating: 0, count: 64)
        let supplementaryCount = getgroups(64, &supplementary)
        if supplementaryCount > 0 {
            supplementary = Array(supplementary.prefix(Int(supplementaryCount)))
        } else {
            supplementary = []
        }
        var values: [String] = []
        if flags.isDisjoint(with: ["u", "g", "G"]) {
            var groups = [account(gid, "\(gid)", groupName)]
            groups += supplementary.map { account($0, "\($0)", groupName) }
            return ("uid=\(account(uid, "\(uid)", userName)) gid=\(groups[0]) groups=\(groups.joined(separator: " "))", 0)
        }
        if flags.contains("u") { values.append(account(uid, "\(uid)", userName)) }
        if flags.contains("g") { values.append(account(gid, "\(gid)", groupName)) }
        if flags.contains("G") {
            values += supplementary.map { numericNames ? "\($0)" : account($0, "\($0)", groupName) }
        }
        return (values.joined(separator: " "), 0)
    }

    // MARK: - cut

    struct CutSpec: Equatable {
        enum Mode: Equatable { case characters, fields }
        var mode: Mode
        /// Normalized, 1-based, inclusive, de-duplicated ascending ranges.
        var ranges: [ClosedRange<Int>]
        var delimiter: Character = "\t"
        var suppressNonDelimited = false
        var files: [String]
    }

    /// Error wrapper so parsing stays `Result`-based without promising more
    /// than a message.
    struct CutParseFailure: Error, Equatable {
        var message: String
    }

    static func parseCut(arguments: [String]) -> Result<CutSpec, CutParseFailure> {
        var mode: CutSpec.Mode?
        var list: String?
        var delimiter: Character = "\t"
        var suppress = false
        var files: [String] = []
        var index = 0
        var optionsEnded = false
        let args = Array(arguments.dropFirst())
        func fail(_ message: String) -> Result<CutSpec, CutParseFailure> {
            .failure(CutParseFailure(message: message))
        }
        func consumeValue(_ attached: String?) -> String? {
            if let attached, !attached.isEmpty { return attached }
            guard index + 1 < args.count else { return nil }
            index += 1
            return args[index]
        }
        while index < args.count {
            let argument = args[index]
            if !optionsEnded && argument == "--" { optionsEnded = true; index += 1; continue }
            if !optionsEnded && argument.hasPrefix("-") && argument != "-" {
                let body = argument.dropFirst()
                let flag = body.first!
                let attached = body.count > 1 ? String(body.dropFirst()) : nil
                switch flag {
                case "c":
                    guard mode == nil, let value = consumeValue(attached) else { return fail("cut: please specify a single mode with -c or -f") }
                    mode = .characters; list = value
                case "f":
                    guard mode == nil, let value = consumeValue(attached) else { return fail("cut: please specify a single mode with -c or -f") }
                    mode = .fields; list = value
                case "d":
                    guard let value = consumeValue(attached) else { return fail("cut: option requires an argument -- 'd'") }
                    let decoded = value == "\\t" ? "\t" : value
                    guard decoded.count == 1, let character = decoded.first else { return fail("cut: the delimiter must be a single character") }
                    delimiter = character
                case "s": suppress = true
                default: return fail("cut: invalid option -- '\(flag)'")
                }
                index += 1
                continue
            }
            files.append(argument)
            index += 1
        }
        guard let mode, let list else {
            return fail("usage: cut -c LIST [-d CHAR] [-s] [FILE]...\n       cut -f LIST [-d CHAR] [-s] [FILE]...")
        }
        switch parseList(list) {
        case .failure(let failure): return .failure(failure)
        case .success(let ranges):
            return .success(CutSpec(mode: mode, ranges: ranges, delimiter: delimiter, suppressNonDelimited: suppress, files: files))
        }
    }

    static func parseList(_ raw: String) -> Result<[ClosedRange<Int>], CutParseFailure> {
        func fail(_ message: String) -> Result<[ClosedRange<Int>], CutParseFailure> {
            .failure(CutParseFailure(message: message))
        }
        var parsed: [ClosedRange<Int>] = []
        for item in raw.split(separator: ",", omittingEmptySubsequences: false) {
            if item.isEmpty { return fail("cut: invalid range with no endpoint: '\(raw)'") }
            let bounds = item.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count <= 2 else { return fail("cut: invalid byte/character or field list") }
            func integer(_ slice: Substring) -> Int? {
                guard !slice.isEmpty, slice.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
                return Int(slice)
            }
            let lower: Int
            let upper: Int
            if bounds.count == 1 {
                guard let value = integer(bounds[0]), value >= 1 else { return fail("cut: byte/character positions are numbered from 1") }
                lower = value; upper = value
            } else {
                if bounds[0].isEmpty {
                    lower = 1
                } else {
                    guard let value = integer(bounds[0]), value >= 1 else { return fail("cut: invalid range '\(item)'") }
                    lower = value
                }
                if bounds[1].isEmpty {
                    upper = Int.max
                } else {
                    guard let value = integer(bounds[1]), value >= 1 else { return fail("cut: invalid range '\(item)'") }
                    upper = value
                }
                guard lower <= upper else { return fail("cut: invalid decreasing range '\(item)'") }
            }
            parsed.append(lower...upper)
        }
        guard !parsed.isEmpty else { return fail("cut: empty selection list") }
        // Union semantics: each position appears exactly once, ascending.
        let sorted = parsed.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return .success(merged)
    }

    static func applyCut(_ text: String, spec: CutSpec) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var output: [String] = []
        for line in lines {
            switch spec.mode {
            case .characters:
                let characters = Array(line)
                var selected: [Character] = []
                for range in spec.ranges {
                    let lower = max(range.lowerBound - 1, 0)
                    let upper = min(range.upperBound, characters.count)
                    guard lower < upper else { continue }
                    selected.append(contentsOf: characters[lower..<upper])
                }
                output.append(String(selected))
            case .fields:
                // A line without the delimiter passes through whole unless -s
                // suppresses it; suppressed lines emit nothing at all.
                guard line.contains(spec.delimiter) else {
                    if !spec.suppressNonDelimited { output.append(line) }
                    continue
                }
                let fields = line.split(separator: spec.delimiter, omittingEmptySubsequences: false).map(String.init)
                var chosen: [String] = []
                for range in spec.ranges {
                    let lower = max(range.lowerBound, 1)
                    let upper = min(range.upperBound, fields.count)
                    guard lower <= upper, !fields.isEmpty else { continue }
                    chosen.append(contentsOf: fields[lower - 1..<min(upper, fields.count)])
                }
                output.append(chosen.joined(separator: String(spec.delimiter)))
            }
        }
        return output.joined(separator: "\n") + (output.isEmpty ? "" : "\n")
    }

    // MARK: - locale

    static let localeCategories = [
        "LC_CTYPE", "LC_NUMERIC", "LC_TIME", "LC_COLLATE", "LC_MONETARY",
        "LC_MESSAGES", "LC_PAPER", "LC_NAME", "LC_ADDRESS", "LC_TELEPHONE",
        "LC_MEASUREMENT", "LC_IDENTIFICATION",
    ]

    static func localeReport(arguments: [String], environment: [String: String]) -> (text: String, code: Int32) {
        func resolved(_ category: String) -> String {
            if let override = environment["LC_ALL"], !override.isEmpty { return override }
            if let value = environment[category], !value.isEmpty { return value }
            return environment["LANG"] ?? ""
        }
        let args = Array(arguments.dropFirst())
        if args.contains("-a") || args.contains("--all-locales") {
            // Real Foundation enumeration; every identifier below exists on
            // this device. C/POSIX are the portable defaults scripts expect.
            var names = Set(Locale.availableIdentifiers.filter { $0.contains("_") }.map { "\($0).UTF-8" })
            names.formUnion(["C", "POSIX"])
            return (names.sorted().joined(separator: "\n") + "\n", 0)
        }
        guard !args.isEmpty else {
            var lines: [String] = []
            if let lang = environment["LANG"] { lines.append("LANG=\(lang)") }
            if let all = environment["LC_ALL"] { lines.append("LC_ALL=\(all)") }
            lines += localeCategories.map { "\($0)=\(resolved($0))" }
            return (lines.joined(separator: "\n") + "\n", 0)
        }
        var lines: [String] = []
        var status: Int32 = 0
        for name in args where !name.hasPrefix("-") {
            if name == "LANG" { lines.append("LANG=\(environment["LANG"] ?? "")") }
            else if name == "LC_ALL" { lines.append("LC_ALL=\(environment["LC_ALL"] ?? "")") }
            else if localeCategories.contains(name) { lines.append("\(name)=\(resolved(name))") }
            else { lines.append("locale: \(name): unknown category"); status = 1 }
        }
        return (lines.joined(separator: "\n") + "\n", status)
    }

    // MARK: - basename / dirname

    /// POSIX basename: strip trailing slashes, drop the directory part, then
    /// remove SUFFIX when it is not the whole result.
    static func basename(_ path: String, suffix: String?) -> String {
        guard !path.isEmpty else { return "" }
        guard !path.allSatisfy({ $0 == "/" }) else { return "/" }
        var name = String(path.reversed().drop(while: { $0 == "/" }).reversed())
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        if let suffix, !suffix.isEmpty, name != suffix, name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name
    }

    /// POSIX dirname: strip trailing slashes and the last component; the
    /// result is "." when no directory part remains, "/" for root-level.
    static func dirname(_ path: String) -> String {
        guard !path.isEmpty else { return "." }
        guard !path.allSatisfy({ $0 == "/" }) else { return "/" }
        var stem = String(path.reversed().drop(while: { $0 == "/" }).reversed())
        guard let slash = stem.lastIndex(of: "/") else { return "." }
        stem = String(stem[..<slash])
        stem = String(stem.reversed().drop(while: { $0 == "/" }).reversed())
        return stem.isEmpty ? "/" : stem
    }
}

extension FloeShellCoreUtilities {
    /// Registers the small utilities above on the shared app-side registry.
    static func register(in registry: FloeShellCommandRegistry) {
        registry.register("id") { arguments, stdout, stderr in
            let report = idReport(arguments: arguments)
            FloeShellWrite(report.code == 0 ? stdout : stderr, report.text.hasSuffix("\n") ? report.text : report.text + "\n")
            return report.code
        }
        registry.register("true") { _, _, _ in 0 }
        registry.register("false") { _, _, _ in 1 }
        registry.register("basename") { arguments, stdout, stderr in
            var args = Array(arguments.dropFirst())
            if args.first == "--" { args.removeFirst() }
            guard !args.isEmpty else {
                FloeShellWrite(stderr, "usage: basename NAME [SUFFIX]\n")
                return 2
            }
            let suffix = args.count > 1 ? args[1] : nil
            FloeShellWrite(stdout, basename(args[0], suffix: suffix) + "\n")
            return 0
        }
        registry.register("dirname") { arguments, stdout, stderr in
            var args = Array(arguments.dropFirst())
            if args.first == "--" { args.removeFirst() }
            guard let path = args.first else {
                FloeShellWrite(stderr, "usage: dirname PATH\n")
                return 2
            }
            FloeShellWrite(stdout, dirname(path) + "\n")
            return 0
        }
        registry.register("locale") { arguments, stdout, stderr in
            let variables = registry.context.map {
                ($0.environment?.variables ?? [:]).merging($0.shellVariables) { _, value in value }
            } ?? [:]
            let report = localeReport(arguments: arguments, environment: variables)
            FloeShellWrite(report.code == 0 ? stdout : stderr, report.text.hasSuffix("\n") ? report.text : report.text + "\n")
            return report.code
        }
        registry.register("cut") { arguments, stdout, stderr in
            switch parseCut(arguments: arguments) {
            case .failure(let failure):
                FloeShellWrite(stderr, failure.message + "\n")
                return 2
            case .success(let spec):
                var status: Int32 = 0
                var sources: [(label: String, text: String)] = []
                if spec.files.isEmpty || spec.files.contains("-") {
                    guard let input = FloeShellCommandRegistry.input, !input.isTerminal,
                          let text = await input.readAsync(cancellation: registry.context?.cancellation) else {
                        FloeShellWrite(stderr, "cut: reading interactive input is unavailable; pipe data or pass files\n")
                        return 2
                    }
                    sources.append(("-", text))
                }
                if let context = registry.context {
                    for file in spec.files where file != "-" {
                        guard !file.hasPrefix("/"), !file.hasPrefix("~"), !file.split(separator: "/").contains("..") else {
                            FloeShellWrite(stderr, "cut: \(file): path escapes the workspace\n")
                            status = 1
                            continue
                        }
                        let url = context.workingDirectory.appendingPathComponent(file).resolvingSymlinksInPath()
                        guard url.path.hasPrefix(context.rootURL.resolvingSymlinksInPath().path + "/") else {
                            FloeShellWrite(stderr, "cut: \(file): path escapes the workspace\n")
                            status = 1
                            continue
                        }
                        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                            FloeShellWrite(stderr, "cut: \(file): no such file or not valid UTF-8 text\n")
                            status = 1
                            continue
                        }
                        sources.append((file, text))
                    }
                } else if spec.files.contains(where: { $0 != "-" }) {
                    FloeShellWrite(stderr, "cut: no workspace is attached\n")
                    return 2
                }
                for source in sources {
                    FloeShellWrite(stdout, applyCut(source.text, spec: spec))
                }
                return status
            }
        }
    }
}
