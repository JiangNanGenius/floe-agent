// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXEngine
import FloeLaTeXCore
import FloeLaTeXParsing
#if canImport(FloeTeXNative)
import FloeTeXNative
#endif

/// Calls a signed, statically linked document engine. Resources contain no native plugins.
public struct LaTeXNativeExperiment: LaTeXEngineRunning {
    public init() {}
    public func capabilities() async -> [LaTeXEngineCapability] {
        #if canImport(FloeTeXNative)
        [.init(engine: .xeLaTeX, version: "tectonic-0.17.0", bibliography: ["BibTeX"], isLocal: true)]
        #else
        []
        #endif
    }
    public func run(_ request: LaTeXEngineRequest, progress: @escaping @Sendable (String) -> Void) async throws -> LaTeXEngineOutput {
        guard request.snapshot.manifest.engine == .xeLaTeX else { throw LaTeXError.unavailable("This document requires \(request.snapshot.manifest.engine.rawValue). Select an environment with that engine.") }
        #if canImport(FloeTeXNative)
        let job = NativeJob(progress: progress)
        let pin=request.snapshot.manifest.resources.first { $0.identifier == "tectonic-default" }?.sha256
        let payload = Request(sourceRoot: request.snapshot.sourceRoot.path,outputRoot:request.outputRoot.path,
                              mainFile:request.snapshot.manifest.mainFile,bundlePath:request.configuration.bundlePath?.path,
                              cacheRoot:request.cacheRoot.path,expectedBundleDigest:pin,
                              timeoutSeconds:request.configuration.timeoutSeconds,offline:request.configuration.offline)
        let data=try LaTeXDigest.encode(payload)
        let response: Response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                NativeJob.queue.async {
                    do {
                        let response=try job.compile(String(decoding:data,as:UTF8.self))
                        continuation.resume(returning:response)
                    } catch { continuation.resume(throwing:error) }
                }
            }
        } onCancel: { job.cancel() }
        guard response.success, let path=response.pdfPath else {
            throw LaTeXEngineFailure(response.error ?? "Typesetting failed",messages:response.messages ?? [],cancelled:response.cancelled ?? false)
        }
        return .init(pdf:URL(fileURLWithPath:path),version:response.version ?? "tectonic-0.17.0",bundleDigest:response.bundleDigest,messages:response.messages ?? [])
        #else
        throw LaTeXError.unavailable("The native typesetting engine is not included in this build.")
        #endif
    }
    private struct Request: Encodable {
        var sourceRoot:String; var outputRoot:String; var mainFile:String;var bundlePath:String?
        var cacheRoot:String;var expectedBundleDigest:String?;var timeoutSeconds:Int;var offline:Bool
    }
    private struct Response: Decodable {
        var success:Bool;var cancelled:Bool?;var pdfPath:String?;var version:String?;var bundleDigest:String?;var error:String?;var messages:[String]?
    }
    #if canImport(FloeTeXNative)
    private final class NativeJob: @unchecked Sendable {
        static let queue=DispatchQueue(label:"org.floeagent.latex.engine",qos:.userInitiated)
        let pointer: OpaquePointer
        let sink: ProgressSink
        init(progress: @escaping @Sendable (String)->Void) {
            pointer=floe_tex_job_create()!;sink=ProgressSink(progress)
            floe_tex_job_progress(pointer,{ message,context in
                guard let message,let context else { return }
                Unmanaged<ProgressSink>.fromOpaque(context).takeUnretainedValue().receive(String(cString:message))
            },Unmanaged.passUnretained(sink).toOpaque())
        }
        deinit { floe_tex_job_free(pointer) }
        func cancel() { floe_tex_job_cancel(pointer) }
        func compile(_ input:String) throws -> Response {
            guard let output=input.withCString({ floe_tex_compile($0,pointer) }) else { throw LaTeXEngineFailure("The engine returned no result") }
            defer { floe_tex_free(output) }
            return try JSONDecoder().decode(Response.self,from:Data(String(cString:output).utf8))
        }
    }
    private final class ProgressSink: Sendable {
        let receive: @Sendable (String)->Void
        init(_ receive:@escaping @Sendable (String)->Void) { self.receive=receive }
    }
    #endif
}
