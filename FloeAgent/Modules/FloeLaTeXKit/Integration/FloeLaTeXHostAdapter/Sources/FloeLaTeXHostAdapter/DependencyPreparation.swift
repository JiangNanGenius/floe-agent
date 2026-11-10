// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore
import FloeLaTeXParsing
import FloeLaTeXEngine

public struct LaTeXPreparationProgress: Sendable, Equatable {
    public enum Stage: String, Sendable { case checking, downloading, ready, compiling }
    public var stage: Stage
    public var downloadBytes: Int64?
    public var sequence: UInt64
    public init(stage: Stage, downloadBytes: Int64? = nil, sequence: UInt64 = 0) { self.stage = stage; self.downloadBytes = downloadBytes; self.sequence = sequence }
}

struct LaTeXPreparationReceipt: Codable, Sendable {
    var schemaVersion = 1
    var projectID: UUID
    var revision: Int64
    var inputDigest: String
    var environmentID: String
    var preparedAt = Date()
    var resolved: [String: String]
    var installedPackages: [String: String]
    var downloadBytes: Int64?
    var changedResources: Bool
    var preparationLogs: [LaTeXPreparationLog] = []
}
struct LaTeXPreparationLog: Codable, Sendable {
    var path: String; var byteCount: Int?; var truncated: Bool?; var exitStatus: Int
}

/// One operation's preparation uses the same resolved transport, runtime
/// authority and durable job lifecycle as its compiler. Resource candidates
/// never authorize networking or change the original's content/engine.
actor LaTeXDependencyPreparer {
    let transport: any LaTeXEnvironmentTransport
    private let authorizeInstallation: @Sendable () async throws -> Void
    private var contentsUpdated = false
    private let operationID=UUID().uuidString.lowercased()
    init(transport: any LaTeXEnvironmentTransport, authorizeInstallation: @escaping @Sendable () async throws -> Void) {
        self.transport = transport; self.authorizeInstallation = authorizeInstallation
    }

    func prepare(_ plan: LaTeXDependencyPlan, offline: Bool,
                 progress: @escaping @Sendable (LaTeXPreparationProgress) -> Void) async throws -> LaTeXPreparationReceipt {
        guard let environmentID = transport.owner.environmentID else { throw LaTeXError.unavailable("Select an execution environment first.") }
        guard plan.requirements.count <= 8192 else { throw LaTeXError.limitExceeded("dependency plan") }
        var installed = Set<String>(), totalBytes: Int64 = 0, hasEstimate = false
        var logs=[LaTeXPreparationLog]()
        var lastMissing: String?
        for _ in 0..<4 {
            try Task.checkCancellation(); progress(.init(stage: .checking))
            let probe: Probe = try await command(action: "probe", plan: plan)
            let missing = probe.missingPrograms + probe.missingFiles + probe.missingFonts
            if missing.isEmpty {
                let versions: Versions = installed.isEmpty ? .init(packages: [:]) : try await command(action: "versions", plan: plan, packages: installed.sorted())
                progress(.init(stage: .ready))
                return .init(projectID: plan.projectID, revision: plan.revision, inputDigest: plan.inputDigest,
                    environmentID: environmentID, resolved: probe.resolved, installedPackages: versions.packages,
                    downloadBytes: hasEstimate ? totalBytes : nil, changedResources: !installed.isEmpty, preparationLogs: logs)
            }
            let summary = missing.sorted().joined(separator: ", ")
            guard !offline else { throw LaTeXError.unavailable("离线时缺少排版所需内容：\(summary)。联网后重试，或先准备这些内容。 / Typesetting resources are missing offline: \(summary). Prepare them online, then retry.") }
            guard summary != lastMissing else { throw LaTeXError.unavailable("已准备的内容仍不可用：\(summary)。请查看此任务的准备记录。 / Prepared resources remain unavailable: \(summary). Open this task's preparation log.") }
            lastMissing = summary
            var packages = Set<String>()
            for program in probe.missingPrograms {
                guard let package = Self.programPackages[program] else { throw LaTeXError.unavailable("The selected environment cannot prepare the required program: " + program) }
                packages.insert(package)
            }
            // Without fontconfig we do not yet know whether a requested
            // family is installed. Prepare the probe, then inspect again.
            for family in probe.missingPrograms.contains("fc-list") ? [] : probe.missingFonts {
                guard let package = Self.fontPackage(family) else {
                    throw LaTeXError.unavailable("缺少字体“\(family)”。请导入可用字体，或在原件中选择已安装的字体。 / Font “\(family)” is missing. Import a font you can use, or choose an installed font in the original.")
                }
                packages.insert(package)
            }
            // The distribution's signed Contents index maps actual missing
            // files to their provider. Never substitute texlive-full/profile.
            if !packages.isEmpty {
                try await authorizeInstallation(); try Task.checkCancellation()
                progress(.init(stage: .downloading))
                let output: LaTeXEnvironmentCommandResult
                if probe.missingPrograms.contains("python3") {
                    let directory=evidenceDirectory(plan)
                    try await transport.authorize(relativePath:directory)
                    output = try await transport.run(script: Self.bootstrap(packages.sorted(),directory:directory), progress: { _ in })
                    try Self.check(output)
                    logs.append(.init(path:directory+"/bootstrap.log",byteCount:nil,truncated:nil,exitStatus:output.exitStatus))
                } else {
                    let result: Installation = try await job(action: "install", plan: plan, packages: packages.sorted(), update: true, progress: progress)
                    if let bytes = result.downloadBytes { totalBytes += bytes; hasEstimate = true }
                    logs+=result.preparationLogs ?? []
                }
                installed.formUnion(packages)
                // A missing lookup/engine binary can make already-installed
                // files appear absent. Re-probe before consulting Contents.
                if !probe.missingPrograms.isEmpty { continue }
            }
            if !probe.missingFiles.isEmpty {
                try await authorizeInstallation(); try Task.checkCancellation()
                let resolution: Resolution = try await job(action: "resolve", plan: plan, files: probe.missingFiles, update: !contentsUpdated, progress: progress)
                contentsUpdated = true
                logs+=resolution.preparationLogs ?? []
                guard resolution.unresolved.isEmpty else {
                    throw LaTeXError.unavailable("当前软件源未找到：\(resolution.unresolved.joined(separator: ", "))。可添加所需文件到原件，或检查软件源后重试。 / The configured repositories did not provide: \(resolution.unresolved.joined(separator: ", ")). Add the files to the project, or check the repositories and retry.")
                }
                guard !resolution.packages.isEmpty else { throw LaTeXError.unavailable("The repository returned no packages for the missing resources.") }
                try await authorizeInstallation(); try Task.checkCancellation()
                let estimate: Estimate = try await command(action: "estimate", plan: plan, packages: resolution.packages)
                progress(.init(stage: .downloading, downloadBytes: estimate.downloadBytes))
                let result: Installation = try await job(action: "install", plan: plan, packages: resolution.packages, estimatedBytes: estimate.downloadBytes, progress: progress)
                if let bytes = result.downloadBytes { totalBytes += bytes; hasEstimate = true }
                logs+=result.preparationLogs ?? []
                installed.formUnion(resolution.packages)
            }
        }
        throw LaTeXError.unavailable("Preparation did not resolve this project's dependencies. Open the saved preparation log and retry.")
    }

    private struct Input: Encodable {
        var action: String; var projectID: UUID; var revision: Int64; var inputDigest: String
        var programs: [String]; var files: [String]; var fonts: [String]; var packages: [String]; var update: Bool; var logDirectory:String
    }
    struct Probe: Codable, Sendable {
        var missingPrograms: [String]; var missingFiles: [String]; var missingFonts: [String]; var resolved: [String: String]
    }
    private struct Resolution: Decodable { var packages: [String]; var unresolved: [String]; var preparationLogs:[LaTeXPreparationLog]? }
    private struct Installation: Decodable { var packages: [String: String]; var downloadBytes: Int64?; var preparationLogs:[LaTeXPreparationLog]? }
    private struct Estimate: Decodable { var downloadBytes: Int64 }
    private struct Versions: Decodable { var packages: [String: String] }
    private struct Envelope<T: Codable>: Codable {
        var protocolName: String; var version: Int; var projectID: UUID; var revision: Int64; var inputDigest: String; var result: T
    }
    private struct ReadEnvelope<T: Decodable>: Decodable {
        var protocolName: String; var version: Int; var projectID: UUID; var revision: Int64; var inputDigest: String; var result: T
    }
    private func script(action: String, plan: LaTeXDependencyPlan, packages: [String], files: [String]?, update: Bool) throws -> String {
        let programs = Set(["python3", "bwrap", "kpsewhich", "pdfinfo"] + (plan.engine == .latex ? ["dvipdfmx"] : []) + plan.requirements.filter { $0.kind == .program }.map(\.value))
        let fonts = plan.requirements.filter { $0.kind == .fontFamily }.map(\.value)
        let input = Input(action: action, projectID: plan.projectID, revision: plan.revision, inputDigest: plan.inputDigest,
            programs: programs.sorted(), files: files ?? plan.requirements.filter { $0.kind == .texFile }.map(\.value),
            fonts: fonts, packages: packages, update: update,logDirectory:evidenceDirectory(plan))
        let data = try LaTeXDigest.encode(input)
        let source = "import base64,json\nINPUT=json.loads(base64.b64decode('" + data.base64EncodedString() + "'))\n" + LaTeXDependencyGuest.source
        // Python is an existing internal service dependency in the resolved
        // Linux guest. This is not a public code-execution alias or host fallback.
        let missing = try LaTeXDigest.encode(Envelope(protocolName: "floe.latex.dependencies", version: 1, projectID: plan.projectID,
            revision: plan.revision, inputDigest: plan.inputDigest,
            result: Probe(missingPrograms: programs.sorted(), missingFiles: [], missingFonts: [], resolved: [:]))).base64EncodedString()
        return "if ! command -v python3 >/dev/null 2>&1; then printf '%s\\n' 'FLOE_LATEX_DEPENDENCIES " + missing + "'; else\npython3 -I -B - <<'FLOE_LATEX_DEPENDENCIES_COMPILED'\n" + source + "\nFLOE_LATEX_DEPENDENCIES_COMPILED\nfi"
    }
    private func command<T: Decodable>(action: String, plan: LaTeXDependencyPlan, packages: [String] = []) async throws -> T {
        try Self.decode(await transport.execute(script: script(action: action, plan: plan, packages: packages, files: nil, update: false), maximumOutputBytes: 262144), plan: plan)
    }
    private func job<T: Decodable>(action: String, plan: LaTeXDependencyPlan, packages: [String] = [], files: [String]? = nil,
                                   update: Bool = false, estimatedBytes: Int64? = nil, progress: @escaping @Sendable (LaTeXPreparationProgress) -> Void) async throws -> T {
        progress(.init(stage: .downloading, downloadBytes: estimatedBytes))
        try await transport.authorize(relativePath:evidenceDirectory(plan))
        let result = try await transport.run(script: script(action: action, plan: plan, packages: packages, files: files, update: update)) { text in
            // Only our numeric estimate marker enters ordinary UI. URLs,
            // package internals and job identities stay in the existing log.
            for line in text.split(separator: "\n") where line.hasPrefix("FLOE_LATEX_DOWNLOAD_BYTES ") {
                if let bytes = Int64(line.dropFirst("FLOE_LATEX_DOWNLOAD_BYTES ".count)), bytes >= 0 {
                    progress(.init(stage: .downloading, downloadBytes: bytes))
                }
            }
        }
        return try Self.decode(result, plan: plan)
    }
    private static func check(_ result: LaTeXEnvironmentCommandResult) throws {
        guard result.workerStopped else { throw LaTeXEngineFailure("Preparation is still waiting for its worker to stop.", messages: [String(result.stdout.suffix(16000))], workerStopped: false) }
        try Task.checkCancellation()
        guard result.exitStatus == 0 else { throw LaTeXEngineFailure("准备排版所需内容失败，请查看任务记录后重试。 / Preparation failed. Open the task log and retry.", messages: [String(result.stdout.suffix(16000))]) }
    }
    private static func decode<T: Decodable>(_ result: LaTeXEnvironmentCommandResult, plan: LaTeXDependencyPlan) throws -> T {
        try check(result)
        let lines = result.stdout.split(separator: "\n").filter { $0.hasPrefix("FLOE_LATEX_DEPENDENCIES ") }
        guard lines.count == 1, let data = Data(base64Encoded: String(lines[0].dropFirst("FLOE_LATEX_DEPENDENCIES ".count))), data.count <= 196608 else {
            throw LaTeXEngineFailure("Preparation did not return a complete resource receipt.", messages: [String(result.stdout.suffix(16000))])
        }
        let value = try JSONDecoder().decode(ReadEnvelope<T>.self, from: data)
        guard value.protocolName == "floe.latex.dependencies", value.version == 1,
              value.projectID == plan.projectID, value.revision == plan.revision, value.inputDigest == plan.inputDigest else {
            throw LaTeXError.unavailable("The preparation receipt belongs to a different project revision.")
        }
        return value.result
    }
    private static let programPackages = ["python3":"python3", "bwrap":"bubblewrap", "pdfinfo":"poppler-utils", "kpsewhich":"texlive-binaries",
        "xelatex":"texlive-xetex", "lualatex":"texlive-luatex", "pdflatex":"texlive-latex-base", "latex":"texlive-latex-base",
        "bibtex":"texlive-binaries", "biber":"biber", "makeindex":"texlive-binaries", "xindy":"xindy", "makeglossaries":"texlive-extra-utils", "dvipdfmx":"texlive-binaries", "upmendex":"texlive-binaries", "fc-list":"fontconfig", "apt-file":"apt-file"]
    private static func fontPackage(_ family: String) -> String? {
        let name = family.lowercased()
        if name.hasPrefix("noto sans cjk ") || name.hasPrefix("noto serif cjk ") { return "fonts-noto-cjk" }
        if ["latin modern roman", "latin modern sans", "latin modern mono", "lmroman10-regular", "lmsans10-regular", "lmmono10-regular"].contains(name) { return "fonts-lmodern" }
        if ["tex gyre termes", "tex gyre heros", "tex gyre pagella", "tex gyre schola", "tex gyre bonum", "tex gyre cursor", "tex gyre adventor"].contains(name) { return "fonts-texgyre" }
        if ["dejavu sans", "dejavu serif", "dejavu sans mono"].contains(name) { return "fonts-dejavu-core" }
        if ["liberation serif", "liberation sans", "liberation mono"].contains(name) { return "fonts-liberation" }
        if ["fandolsong", "fandolsong-regular", "fandolhei", "fandolhei-regular", "fandolkai-regular", "fandolfang-regular"].contains(name) { return "texlive-lang-chinese" }
        return nil
    }
    private func evidenceDirectory(_ plan:LaTeXDependencyPlan)->String {".floe-latex/"+plan.projectID.uuidString.lowercased()+"/preparation-"+operationID}
    private static func bootstrap(_ packages: [String],directory:String) -> String {
        precondition(packages.allSatisfy { $0.range(of: #"^[a-z0-9][a-z0-9+.-]*$"#, options: .regularExpression) != nil })
        return """
        set -eu
        export TMPDIR=/tmp TMP=/tmp TEMP=/tmp LANG=C.UTF-8 LC_ALL=C.UTF-8
        mkdir -p '\(directory)'
        log='\(directory)/bootstrap.log'
        [ ! -e "$log" ] && [ ! -L "$log" ]
        command -v apt-get >/dev/null || { echo 'Prepare Python 3, TeX Live and bubblewrap using this Linux distribution package manager.' >&2; exit 64; }
        if [ "$(id -u)" = 0 ]; then privilege=''; else command -v sudo >/dev/null; privilege='sudo -n'; fi
        status=0
        ( $privilege env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update &&
          $privilege env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends \(packages.joined(separator: " ")) ) >"$log" 2>&1 || status=$?
        printf 'Preparation log: %s\\n' "$log"
        tail -c 8192 "$log"
        exit "$status"
        """
    }
}
