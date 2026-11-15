// SPDX-License-Identifier: MPL-2.0
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import FloeGameCore
import FloeGameRunKit

/// Resolves the selected game root through descriptor-relative directory
/// opens. The selection is a saved-revision-scoped relative path; it is never
/// a host path and it can never escape the materialized project root.
enum RGSSGuestRootResolver {
    static func resolve(root: URL, relativeRoot: String,
                        limits: RGSSGuestTreeLimits) throws -> URL {
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        guard relativeRoot == "." else {
            let components = relativeRoot.split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)
            guard !components.isEmpty, components.count <= limits.maximumDepth,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !components.contains(where: { RGSSGuestSafeTree.isAdministrative($0) }) else {
                throw RGSSGuestRunError.invalidRequest("selected game root")
            }
            let rootFD = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else {
                throw RGSSGuestRunError.sourceRootUnavailable(canonical.lastPathComponent)
            }
            defer { close(rootFD) }
            var current = rootFD
            for component in components {
                let next = openat(current, component,
                                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if current != rootFD { close(current) }
                guard next >= 0 else {
                    throw RGSSGuestRunError.invalidRequest(
                        "selected game root is missing, not a directory, or a symbolic link")
                }
                current = next
            }
            if current != rootFD { close(current) }
            let url = canonical.appendingPathComponent(relativeRoot, isDirectory: true)
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path == canonical.path || resolved.path.hasPrefix(canonical.path + "/") else {
                throw RGSSGuestRunError.invalidRequest("selected game root escapes the project")
            }
            return resolved
        }
        return canonical
    }

    static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childComponents = child.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parentComponents = parent.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return childComponents.count > parentComponents.count
            && Array(childComponents.prefix(parentComponents.count)) == parentComponents
    }

    static func requireOutside(_ candidate: URL, source: URL, kind: String) throws {
        let value = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let sourceURL = source.standardizedFileURL.resolvingSymlinksInPath()
        guard value.path != sourceURL.path,
              !isDescendant(value, of: sourceURL),
              !isDescendant(sourceURL, of: value) else {
            throw RGSSGuestRunError.runLayerViolation("\(kind) must be outside the immutable source root")
        }
    }
}

/// Stable directory identities for one project/owner/engine/root. The run
/// layer is keyed by revision and source digest so a changed source never
/// reuses stale files; the save layer is stable across revisions.
public struct RGSSGuestRunLayout: Sendable, Equatable {
    public let baseDirectory: URL

    public init(baseDirectory: URL) throws {
        guard baseDirectory.isFileURL, !baseDirectory.lastPathComponent.isEmpty,
              baseDirectory.path != "/" else {
            throw RGSSGuestRunError.invalidRequest("run layout base directory")
        }
        self.baseDirectory = baseDirectory.standardizedFileURL
    }

    public func runRoot(for request: RGSSGuestRunRequest, sourceDigest: String) -> URL {
        baseDirectory
            .appendingPathComponent("Runs", isDirectory: true)
            .appendingPathComponent(request.context.projectID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(Self.ownerDigest(request.context.owner), isDirectory: true)
            .appendingPathComponent(request.engine.rawValue, isDirectory: true)
            .appendingPathComponent(Self.pathDigest(request.rootRelative), isDirectory: true)
            .appendingPathComponent(Self.pathDigest(request.context.savedRevision), isDirectory: true)
            .appendingPathComponent(String(sourceDigest.prefix(12)), isDirectory: true)
    }

    public func saveRoot(for request: RGSSGuestRunRequest) -> URL {
        baseDirectory
            .appendingPathComponent("Saves", isDirectory: true)
            .appendingPathComponent(request.context.projectID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(Self.ownerDigest(request.context.owner), isDirectory: true)
            .appendingPathComponent(request.engine.rawValue, isDirectory: true)
            .appendingPathComponent(Self.pathDigest(request.rootRelative), isDirectory: true)
    }

    public func homeRoot(for request: RGSSGuestRunRequest) -> URL {
        baseDirectory
            .appendingPathComponent("Home", isDirectory: true)
            .appendingPathComponent(request.context.projectID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(Self.ownerDigest(request.context.owner), isDirectory: true)
            .appendingPathComponent(request.engine.rawValue, isDirectory: true)
    }

    public func logFile(for request: RGSSGuestRunRequest) -> URL {
        baseDirectory
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(request.context.projectID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(Self.ownerDigest(request.context.owner), isDirectory: true)
            .appendingPathComponent(request.id.uuidString.lowercased() + ".log")
    }

    static func ownerDigest(_ owner: GameProjectOwner) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(owner)) ?? Data(String(describing: owner).utf8)
        return String(GameDigest.sha256(data).prefix(24))
    }

    static func pathDigest(_ value: String) -> String {
        String(GameDigest.sha256(Data(value.utf8)).prefix(24))
    }
}
