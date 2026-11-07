// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore
import FloeLaTeXParsing

/// Hosts may supply a fully resolved Linux environment using the existing exec.shell/jobs transport.
/// Capability discovery comes from that environment; no host interpreter fallback is used.
public struct LaTeXEngineRouter: LaTeXEngineRunning {
    public let native: any LaTeXEngineRunning
    public let environment: (any LaTeXEngineRunning)?
    public init(native: any LaTeXEngineRunning = LaTeXUnconfiguredEngine(),environment: (any LaTeXEngineRunning)? = nil) {self.native=native;self.environment=environment}
    public func capabilities() async -> [LaTeXEngineCapability] {
        let local=await native.capabilities()
        let extra=await environment?.capabilities() ?? []
        return local+extra
    }
    public func run(_ request:LaTeXEngineRequest,progress:@escaping @Sendable (String)->Void) async throws -> LaTeXEngineOutput {
        var needsBiber=false
        for file in request.snapshot.manifest.files where file.kind == .source || file.kind == .style {
            guard let source=try? String(contentsOf:LaTeXPath.child(file.path,root:request.snapshot.sourceRoot),encoding:.utf8) else {continue}
            let index=LaTeXParser.parse(source)
            if index.packages.contains("biblatex"),!index.commands.contains(where:{$0.name=="usepackage" && $0.arguments.contains(where:{$0.optional && $0.value.replacingOccurrences(of:" ",with:"").contains("backend=bibtex")})}) {needsBiber=true;break}
        }
        if !needsBiber,await native.capabilities().contains(where: { $0.engine == request.snapshot.manifest.engine }) { return try await native.run(request,progress:progress) }
        guard let environment,await environment.capabilities().contains(where: { $0.engine == request.snapshot.manifest.engine }) else {
            throw LaTeXError.unavailable(needsBiber ? "This document requires Biber. Prepare Biber in the task's resolved Linux environment, then typeset again.":"The selected engine is unavailable in the current environment.")
        }
        if needsBiber,!(await environment.capabilities()).contains(where:{$0.engine==request.snapshot.manifest.engine && $0.bibliography.contains(where:{$0.lowercased()=="biber"})}) {throw LaTeXError.unavailable("Biber is unavailable in the selected environment.")}
        return try await environment.run(request,progress:progress)
    }
}

/// Production defaults advertise only configured capabilities. The GPL-bearing
/// Tectonic native experiment lives in a separate, explicit qualification package.
public struct LaTeXUnconfiguredEngine:LaTeXEngineRunning {
    public init() {}
    public func capabilities() async -> [LaTeXEngineCapability] {[]}
    public func run(_ request:LaTeXEngineRequest,progress:@escaping @Sendable (String)->Void) async throws -> LaTeXEngineOutput {
        throw LaTeXError.unavailable("Prepare the LaTeX toolchain in this task's resolved local Linux environment before typesetting.")
    }
}
