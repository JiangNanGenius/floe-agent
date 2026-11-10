// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore
import FloeLaTeXParsing

/// Native document engines are independent of a task's command environment.
/// Legacy callers may still supply an environment engine, but it is never an
/// implicit fallback for this native route.
public struct LaTeXEngineRouter: LaTeXEngineRunning {
    public let native: any LaTeXEngineRunning
    public init(native: any LaTeXEngineRunning = LaTeXUnconfiguredEngine()) {self.native=native}
    @available(*,deprecated,message:"Native document typesetting does not fall back to a command environment.")
    public init(native: any LaTeXEngineRunning = LaTeXUnconfiguredEngine(), environment: (any LaTeXEngineRunning)?) {self.native=native}
    public func capabilities() async -> [LaTeXEngineCapability] { await native.capabilities() }
    public func run(_ request: LaTeXEngineRequest, progress: @escaping @Sendable (String) -> Void) async throws -> LaTeXEngineOutput {
        try LaTeXNativeDocumentSupport.validate(request.snapshot)
        guard await native.capabilities().contains(where: { $0.engine == request.snapshot.manifest.engine && $0.environmentID == nil }) else {
            throw LaTeXError.unavailable("此版本未包含所选的原生排版引擎。 / The selected native typesetting engine is unavailable in this build.")
        }
        return try await native.run(request, progress: progress)
    }
}

public enum LaTeXNativeDocumentSupport {
    public static func validate(_ snapshot: LaTeXProjectSnapshot,cancelled:@Sendable ()->Bool = {Task.isCancelled}) throws {
        guard snapshot.manifest.engine == .xeLaTeX else {
            throw LaTeXError.unavailable("当前原生排版支持 XeLaTeX。请为此原件选择 XeLaTeX。 / Native typesetting currently supports XeLaTeX. Select XeLaTeX for this document.")
        }
        for file in snapshot.manifest.files where file.kind == .source || file.kind == .style {
            if cancelled() {throw CancellationError()}
            let source = try String(contentsOf: LaTeXPath.child(file.path, root: snapshot.sourceRoot), encoding: .utf8)
            let index = LaTeXParser.parse(source)
            let biblatex=index.commands.filter { command in
                ["usepackage","RequirePackage","RequirePackageWithOptions"].contains(command.name)
                && command.arguments.contains { argument in
                    !argument.optional && argument.value.split(separator:",").contains {
                        $0.trimmingCharacters(in:.whitespacesAndNewlines)=="biblatex"
                    }
                }
            }
            if biblatex.contains(where:{ command in
                let backends=command.arguments.filter(\.optional).flatMap {
                    $0.value.split(separator:",").map {$0.filter{!$0.isWhitespace}.lowercased()}
                }.filter {$0.hasPrefix("backend=")}
                return backends != ["backend=bibtex"]
            }) {
                throw LaTeXError.unavailable("当前原生文献处理仅支持 BibTeX，尚不支持 Biber 等其他后端。请为此原件选择 BibTeX。 / Native bibliography processing currently supports BibTeX only. Biber and other backends are unavailable; select BibTeX for this document.")
            }
        }
    }
}

public struct LaTeXUnconfiguredEngine: LaTeXEngineRunning {
    public init() {}
    public func capabilities() async -> [LaTeXEngineCapability] { [] }
    public func run(_ request: LaTeXEngineRequest, progress: @escaping @Sendable (String) -> Void) async throws -> LaTeXEngineOutput {
        throw LaTeXError.unavailable("此版本未包含可用的原生排版引擎。 / This build does not include an available native typesetting engine.")
    }
}
