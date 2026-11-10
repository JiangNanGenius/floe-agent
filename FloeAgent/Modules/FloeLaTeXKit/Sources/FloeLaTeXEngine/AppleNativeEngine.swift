// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore
#if canImport(FloeTeXNativeXDV)
import FloeTeXNativeXDV
#endif

/// The App supplies its existing PDF gate; the package never creates another
/// PDF queue or reaches into application permission or presentation state.
public struct LaTeXNativePDFRenderRequest: Sendable {
    public let displayListData: Data
    public let allowedRoots: [URL]
    public let outputURL: URL
    public let cancellation: LaTeXNativeCancellation
}

public final class LaTeXNativeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private let renderingBudget: TimeInterval
    private var renderingDeadline: TimeInterval?
    fileprivate init(timeout: Int) { renderingBudget = Double(min(600,max(1,timeout))) }
    fileprivate func beginRendering() {
        lock.withLock { renderingDeadline = ProcessInfo.processInfo.systemUptime + renderingBudget }
    }
    fileprivate func cancel() { lock.withLock { requested = true } }
    public var isCancellationRequested: Bool { lock.withLock { requested } }
    public var deadlineExceeded: Bool {
        lock.withLock { renderingDeadline.map {ProcessInfo.processInfo.systemUptime >= $0} ?? false }
    }
    public var shouldStop: Bool { isCancellationRequested || deadlineExceeded }
}

public struct LaTeXNativePreparationOutput: Codable, Sendable {
    public let version: String
    public let bundleDigest: String
    public let messages: [String]
    public let workerStopped: Bool
}

/// Production path: reviewed XeTeX/BibTeX -> XDV -> Apple PDF renderer. Merely
/// producing XDV is never a successful PDF build. The old experiment is not
/// imported and cannot satisfy this binary/module identity.
public struct LaTeXAppleNativeEngine: LaTeXEngineRunning {
    public typealias Renderer = @Sendable (LaTeXNativePDFRenderRequest) throws -> LaTeXApplePDFReceipt
    public typealias PDFBody = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    public typealias PDFGate = @convention(c) (PDFBody?, UnsafeMutableRawPointer?) -> Int32
    public static let engineVersion = "floe-xetex-xdv-0.17.0-cg2"
    private let render: Renderer?
    private let expectedBundleDigest: String?
    public init(render: Renderer? = nil, expectedBundleDigest: String? = nil) {
        self.render = render; self.expectedBundleDigest = expectedBundleDigest
    }
    public func pinned(to digest: String) -> Self { .init(render: render, expectedBundleDigest: digest) }
    public static func installPDFMetadataGate(_ gate: PDFGate) throws {
        #if canImport(FloeTeXNativeXDV)
        guard floe_tex_apple_set_pdf_gate(gate) == 0 else {
            throw LaTeXError.unavailable("The document PDF access gate could not be registered.")
        }
        #else
        throw LaTeXError.unavailable("The native typesetting engine is not included in this build.")
        #endif
    }
    public static let legacyGlyphOutline:LaTeXLegacyGlyphOutlineProvider = {fontBytes,faceIndex,glyphName,character in
        #if canImport(FloeTeXNativeXDV)
        guard !fontBytes.isEmpty,fontBytes.count<=64*1024*1024,faceIndex<1024,
              glyphName.map({$0.utf8.count<=256 && !$0.contains("\0")}) != false else {
            throw LaTeXError.invalidOperation("The native font outline input is invalid.")
        }
        let sink=LegacyOutlineSink()
        var unitsPerEm=0.0
        func invoke(_ name:UnsafePointer<CChar>?)->Int32 {
            fontBytes.withUnsafeBytes { bytes in
                floe_tex_legacy_outline(bytes.bindMemory(to:UInt8.self).baseAddress,bytes.count,faceIndex,name,character,&unitsPerEm,
                    {context,kind,x1,y1,x2,y2,x3,y3 in
                        guard let context else {return 1}
                        return Unmanaged<LegacyOutlineSink>.fromOpaque(context).takeUnretainedValue()
                            .append(kind:kind,x1:x1,y1:y1,x2:x2,y2:y2,x3:x3,y3:y3)
                    },Unmanaged.passUnretained(sink).toOpaque())
            }
        }
        let result:Int32
        if let glyphName {result=glyphName.withCString {invoke($0)}}else {result=invoke(nil)}
        guard result==0,unitsPerEm.isFinite,unitsPerEm>0,unitsPerEm<=1_000_000 else {
            throw LaTeXError.invalidOperation("The native font outline could not be decoded (\(result)).")
        }
        return .init(unitsPerEm:unitsPerEm,segments:sink.segments)
        #else
        throw LaTeXError.unavailable("The native font outline engine is not included in this build.")
        #endif
    }
    #if canImport(FloeTeXNativeXDV)
    private final class LegacyOutlineSink {
        var segments=[LaTeXLegacyOutlineSegment]()
        func append(kind:Int32,x1:Double,y1:Double,x2:Double,y2:Double,x3:Double,y3:Double)->Int32 {
            guard (0...4).contains(kind),segments.count<65_536,
                  [x1,y1,x2,y2,x3,y3].allSatisfy({$0.isFinite && abs($0)<=1e12}) else {return 1}
            segments.append(.init(kind:kind,x1:x1,y1:y1,x2:x2,y2:y2,x3:x3,y3:y3));return 0
        }
    }
    #endif
    public func capabilities() async -> [LaTeXEngineCapability] {
        #if canImport(FloeTeXNativeXDV)
        guard render != nil else { return [] }
        return [.init(engine: .xeLaTeX, version: Self.engineVersion, bibliography: ["BibTeX"], isLocal: true)]
        #else
        return []
        #endif
    }
    public func prepare(_ request: LaTeXEngineRequest,
                        progress: @escaping @Sendable (String) -> Void) async throws -> LaTeXNativePreparationOutput {
        let result = try await execute(request, mode: "prepare", progress: progress)
        guard result.response.prepared == true else { throw LaTeXEngineFailure("Native resource preparation did not finish.") }
        guard let digest=result.response.bundleDigest,!digest.isEmpty else {throw LaTeXEngineFailure("Native resource preparation has no bundle receipt.")}
        return .init(version: Self.engineVersion, bundleDigest: digest,
                     messages: result.response.messages ?? [], workerStopped: true)
    }
    public func run(_ request: LaTeXEngineRequest,
                    progress: @escaping @Sendable (String) -> Void) async throws -> LaTeXEngineOutput {
        let result = try await execute(request, mode: "compile", progress: progress)
        guard let pdf = result.pdf else { throw LaTeXEngineFailure("The native renderer produced no PDF.") }
        return .init(pdf: pdf, version: Self.engineVersion, bundleDigest: result.response.bundleDigest,
                     messages: result.response.messages ?? [])
    }
    private struct Request: Encodable, Sendable {
        let sourceRoot: String, outputRoot: String, mainFile: String
        let bundlePath: String?, cacheRoot: String, expectedBundleDigest: String?
        let timeoutSeconds: Int, offline: Bool, mode: String
        let resourceTimeoutSeconds: Int, resourceTotalTimeoutSeconds: Int
    }
    private struct Response: Codable, Sendable {
        let success: Bool
        let cancelled: Bool?
        let prepared: Bool?
        let xdvPath: String?
        let displayListPath: String?
        let version: String?
        let bundleDigest: String?
        let resourceTimeoutSeconds: Int?
        let resourceTotalTimeoutSeconds: Int?
        let resourceRequestCount: Int?
        let resourceReceivedBytes: Int64?
        let resourceElapsedMilliseconds: Int64?
        let error: String?
        let messages: [String]?
    }
    private struct Result: Sendable { let response: Response; let pdf: URL? }
    private func execute(_ request: LaTeXEngineRequest, mode: String,
                         progress: @escaping @Sendable (String) -> Void) async throws -> Result {
        #if canImport(FloeTeXNativeXDV)
        guard let render else { throw LaTeXError.unavailable("The protected native PDF renderer is unavailable.") }
        let job = try NativeJob(progress: progress, timeout: request.configuration.timeoutSeconds)
        let payload = Request(sourceRoot: request.snapshot.sourceRoot.path, outputRoot: request.outputRoot.path,
            mainFile: request.snapshot.manifest.mainFile, bundlePath: request.configuration.bundlePath?.path,
            cacheRoot: request.cacheRoot.path,
            expectedBundleDigest: expectedBundleDigest ?? request.snapshot.manifest.resources.first { $0.identifier == "tectonic-default" }?.sha256,
            timeoutSeconds: request.configuration.timeoutSeconds, offline: request.configuration.offline, mode: mode,
            resourceTimeoutSeconds:60,resourceTotalTimeoutSeconds:600)
        let data = try LaTeXDigest.encode(payload)
        // A cancelled waiter keeps waiting for the real C call and renderer to
        // return. Only then may the build service release its source snapshot.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                NativeJob.queue.async {
                    do {
                        try LaTeXNativeDocumentSupport.validate(request.snapshot,cancelled:{job.cancellation.shouldStop})
                        try job.checkStop()
                        try FileManager.default.createDirectory(at: request.outputRoot, withIntermediateDirectories: true)
                        let response = try job.compile(String(decoding: data, as: UTF8.self))
                        try LaTeXDigest.encode(response).write(to: request.outputRoot.appendingPathComponent("NativeResponse.json"), options: .atomic)
                        guard response.success, response.version == Self.engineVersion,
                              let digest = response.bundleDigest, !digest.isEmpty,
                              let xdvPath = response.xdvPath, let displayListPath = response.displayListPath else {
                            throw LaTeXEngineFailure(response.error ?? "Native typesetting did not produce its XDV receipt.",
                                messages: response.messages ?? [], cancelled: response.cancelled == true || job.cancellation.isCancellationRequested,
                                workerStopped: true)
                        }
                        if !request.configuration.offline {
                            guard let perRequest=response.resourceTimeoutSeconds,(1...60).contains(perRequest),
                                  let total=response.resourceTotalTimeoutSeconds,total>=perRequest,total<=600 else {
                                throw LaTeXEngineFailure("The native resource request returned no bounded network-budget receipt.",messages:response.messages ?? [],workerStopped:true)
                            }
                        }
                        _ = try Self.checkedOutput(xdvPath, under: request.outputRoot, limit: 128 * 1024 * 1024)
                        let displayList = try Self.checkedOutput(displayListPath, under: request.outputRoot, limit: 64 * 1024 * 1024)
                        try job.checkStop()
                        if mode == "prepare" {
                            continuation.resume(returning: Result(response: response, pdf: nil)); return
                        }
                        let relative = (try LaTeXPath.validate(request.snapshot.manifest.mainFile) as NSString).deletingPathExtension + ".pdf"
                        let pdf = try LaTeXPath.child(relative, root: request.outputRoot, createParents: true)
                        var roots = [request.snapshot.sourceRoot, request.cacheRoot, request.outputRoot]
                        if let bundle = request.configuration.bundlePath { roots.append(bundle) }
                        // Native scanner timeouts exclude legitimate resource
                        // I/O. Only this PDF phase starts the Swift deadline;
                        // manual cancellation remains live through every phase.
                        job.cancellation.beginRendering()
                        progress("FLOE_TEX_RENDERING_PDF")
                        let receipt = try render(.init(displayListData: Data(contentsOf: displayList, options: .mappedIfSafe),
                            allowedRoots: roots, outputURL: pdf, cancellation: job.cancellation))
                        try job.checkStop()
                        guard receipt.pageCount > 0, receipt.bytes > 5, receipt.sha256.count == 64 else {
                            throw LaTeXEngineFailure("The native PDF renderer returned an invalid receipt.")
                        }
                        try LaTeXDigest.encode(receipt).write(to: request.outputRoot.appendingPathComponent("NativePDFReceipt.json"), options: .atomic)
                        continuation.resume(returning: Result(response: response, pdf: pdf))
                    } catch {
                        let cancelled = job.cancellation.isCancellationRequested
                        if job.cancellation.deadlineExceeded && !cancelled {
                            continuation.resume(throwing: LaTeXEngineFailure("PDF rendering reached its time limit.", messages: [error.localizedDescription], workerStopped: true))
                        } else if cancelled {
                            continuation.resume(throwing: LaTeXEngineFailure("Typesetting stopped.", messages: [error.localizedDescription], cancelled: true, workerStopped: true))
                        } else if let failure=error as? LaTeXEngineFailure {continuation.resume(throwing:failure)}
                        else {continuation.resume(throwing:LaTeXEngineFailure(error.localizedDescription,workerStopped:true))}
                    }
                }
            }
        } onCancel: { job.cancel() }
        #else
        throw LaTeXError.unavailable("The native typesetting engine is not included in this build.")
        #endif
    }
    private static func checkedOutput(_ path: String, under root: URL, limit: Int) throws -> URL {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let parent = root.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path.hasPrefix(parent.path + "/"), values.isRegularFile == true,
              values.isSymbolicLink != true, let bytes = values.fileSize, bytes > 0, bytes <= limit else {
            throw LaTeXError.invalidPath(path)
        }
        return canonical
    }
    #if canImport(FloeTeXNativeXDV)
    private final class NativeJob: @unchecked Sendable {
        static let queue = DispatchQueue(label: "org.floeagent.latex.native-xdv", qos: .userInitiated)
        let pointer: OpaquePointer
        let sink: ProgressSink
        let cancellation: LaTeXNativeCancellation
        init(progress: @escaping @Sendable (String) -> Void, timeout: Int) throws {
            guard let pointer = floe_tex_job_create() else { throw LaTeXError.unavailable("The native document engine could not start.") }
            self.pointer = pointer; sink = ProgressSink(progress); cancellation = .init(timeout: timeout)
            floe_tex_job_progress(pointer, { message, context in
                guard let message, let context else { return }
                Unmanaged<ProgressSink>.fromOpaque(context).takeUnretainedValue().receive(String(cString: message))
            }, Unmanaged.passUnretained(sink).toOpaque())
        }
        deinit { floe_tex_job_free(pointer) }
        func cancel() { cancellation.cancel(); floe_tex_job_cancel(pointer) }
        func checkStop() throws {
            if cancellation.isCancellationRequested { throw CancellationError() }
            if cancellation.deadlineExceeded { throw LaTeXEngineFailure("PDF rendering reached its time limit.") }
        }
        func compile(_ input: String) throws -> Response {
            guard let output = input.withCString({ floe_tex_compile($0, pointer) }) else {
                throw LaTeXEngineFailure("The native engine returned no receipt.", workerStopped: true)
            }
            defer { floe_tex_free(output) }
            return try JSONDecoder().decode(Response.self, from: Data(String(cString: output).utf8))
        }
    }
    private final class ProgressSink: Sendable {
        let receive: @Sendable (String) -> Void
        init(_ receive: @escaping @Sendable (String) -> Void) { self.receive = receive }
    }
    #endif
}
