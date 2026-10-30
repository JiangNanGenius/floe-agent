// SPDX-License-Identifier: MPL-2.0
//
// FloeAndroidShellTools — bounded READ-ONLY live guest file snapshot transport
// (G07.3A). This is the typed seam between the native Core domain and the
// runtime UID that owns the guest `/workspace` directory. It deliberately
// rides the EXISTING Linux shell mailbox/runtime IPC: no second socket, no
// second permission store, no host fallback and no export path.
//
// The runtime re-proves (session live, exact project, exact environment,
// exact runtime generation) and applies its own no-follow/containment/bounds
// rules. This transport only validates the wire shape and the closed state
// vocabulary, so a malformed or short reply can never be read as a complete
// snapshot.

import Foundation
import FloeCore

public enum LinuxLiveFilesError: Error, Sendable, Equatable, CustomStringConvertible {
    case notBound
    case awaitBudgetExpired
    case replyMalformed
    case refused(String)
    case retry(String)
    case transport(String)

    public var description: String {
        switch self {
        case .notBound: return "the runtime engine transport is not bound"
        case .awaitBudgetExpired: return "the bounded live-file wait expired; nothing was assumed"
        case .replyMalformed: return "the live-file reply was malformed; nothing was assumed"
        case .refused(let code): return "live-file request refused: \(code)"
        case .retry(let code): return "live-file read raced a change: \(code)"
        case .transport(let detail): return "live-file transport failed: \(detail)"
        }
    }

    /// Stable typed token for the host's opened details (never prose).
    public var code: String {
        switch self {
        case .notBound: return "engineUnbound"
        case .awaitBudgetExpired: return "waitBudgetExpired"
        case .replyMalformed: return "replyMalformed"
        case .refused(let code): return "refused:\(code)"
        case .retry(let code): return "retry:\(code)"
        case .transport: return "transport"
        }
    }
}

public struct LinuxLiveFilesRequest: Sendable, Equatable {
    public var sessionID: String
    public var workspaceKey: String
    public var environmentID: String
    public var generation: String
    public var relativePath: String
    public var maxEntries: Int
    public var maxDepth: Int
    public var offset: Int64
    public var maxBytes: Int

    public init(sessionID: String, workspaceKey: String, environmentID: String,
                generation: String, relativePath: String, maxEntries: Int = 200,
                maxDepth: Int = 3, offset: Int64 = 0, maxBytes: Int = 16 * 1024) {
        self.sessionID = sessionID
        self.workspaceKey = workspaceKey
        self.environmentID = environmentID
        self.generation = generation
        self.relativePath = relativePath
        self.maxEntries = maxEntries
        self.maxDepth = maxDepth
        self.offset = offset
        self.maxBytes = maxBytes
    }

    public static let maximumTreeEntries = 512
    public static let maximumDepth = 8
    public static let maximumReadBytes = 24 * 1024
}

public struct LinuxLiveFileEntry: Sendable, Equatable {
    public var path: String
    /// file | directory | symlink | other
    public var kind: String
    public var size: Int64
    public var mtimeMillis: Int64

    public init(path: String, kind: String, size: Int64, mtimeMillis: Int64) {
        self.path = path
        self.kind = kind
        self.size = size
        self.mtimeMillis = mtimeMillis
    }
}

public struct LinuxLiveTreeSnapshot: Sendable, Equatable {
    public var entries: [LinuxLiveFileEntry]
    public var truncated: Bool
    public var generation: String
    /// SHA-256 over generation + the exact ordered entry tuple. It fences the
    /// LISTING (not a whole-workspace snapshot); `truncated` means it is an
    /// incomplete bounded listing and must be shown as such.
    public var listingToken: String

    public init(entries: [LinuxLiveFileEntry], truncated: Bool, generation: String,
                listingToken: String) {
        self.entries = entries
        self.truncated = truncated
        self.generation = generation
        self.listingToken = listingToken
    }
}

public struct LinuxLiveFilePage: Sendable, Equatable {
    public var path: String
    public var offset: Int64
    public var bytes: Int
    public var size: Int64
    public var mtimeMillis: Int64
    public var digest: String
    public var content: Data
    public var truncated: Bool
    public var generation: String
    /// SHA-256 over the page identity tuple (generation,path,offset,bytes,
    /// size,mtime,digest). A consumer validates `digest` over the decoded
    /// bytes + strict UTF-8; the token only fences the exact page version.
    public var consistencyToken: String

    public init(path: String, offset: Int64, bytes: Int, size: Int64, mtimeMillis: Int64,
                digest: String, content: Data, truncated: Bool, generation: String,
                consistencyToken: String) {
        self.path = path
        self.offset = offset
        self.bytes = bytes
        self.size = size
        self.mtimeMillis = mtimeMillis
        self.digest = digest
        self.content = content
        self.truncated = truncated
        self.generation = generation
        self.consistencyToken = consistencyToken
    }
}

public protocol LinuxLiveFilesTransport: Sendable {
    func filesTree(_ request: LinuxLiveFilesRequest, timeoutMillis: Int) async throws -> LinuxLiveTreeSnapshot
    func filesRead(_ request: LinuxLiveFilesRequest, timeoutMillis: Int) async throws -> LinuxLiveFilePage
}
