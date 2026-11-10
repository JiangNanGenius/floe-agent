// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Owns long native proxy work independently of a particular editor view.
/// Task cancellation and explicit Cancel share the native cancellation token;
/// completed bytes are only candidates until the existing root CAS admits them.
public actor MediaPreparedCompoundProxyJobs {
    public static let shared=MediaPreparedCompoundProxyJobs()
    private struct Job:Sendable { let worker:Task<MediaPreparedCompoundProxy,Error>;let cancellation:PreparedVideoCancellation }
    private var jobs:[UUID:Job]=[:]
    private let renderer=MediaPreparedCompoundProxyRenderer()
    public init() {}
    public func render(source:MediaPreparedDocument,assetURLs:[UUID:URL],rootURL:URL,minimumDurationSeconds:Double=0,cancellation:PreparedVideoCancellation,progress:@escaping @Sendable(Double)->Void={_ in}) async throws -> MediaPreparedCompoundProxy {
        let id=UUID(),renderer=self.renderer
        let worker=Task { try await renderer.render(source:source,assetURLs:assetURLs,rootURL:rootURL,minimumDurationSeconds:minimumDurationSeconds,cancellation:cancellation,progress:progress) }
        jobs[id] = .init(worker:worker,cancellation:cancellation)
        defer { jobs.removeValue(forKey:id) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel();worker.cancel() }
    }
    public var activeJobCount:Int { jobs.count }
}
