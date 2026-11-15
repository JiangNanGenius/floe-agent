// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Container formats the component can accept. ZIP is decoded internally with
/// the reviewed vendor; every other format is decoded by an EXISTING host
/// archive service behind the typed port below (the App already ships
/// ArchiveEngine for tar variants and a signed native RAR decoder). This
/// package deliberately bundles no additional decoder.
public enum GameArchiveContainerFormat: String, Sendable, CaseIterable {
    case zip
    case tar
    case tarGzip = "tar.gz"
    case tarBzip2 = "tar.bz2"
    case tarXz = "tar.xz"
    case sevenZip = "7z"
    case rar
}

public enum GameArchiveFormatDetector {
    /// Magic-byte detection first, then conservative extension fallback.
    /// Never executes or parses the archive content beyond these few bytes.
    public static func detect(at url: URL) throws -> GameArchiveContainerFormat {
        guard url.isFileURL else { throw GameArchiveError.invalidTarget }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch {
            throw GameArchiveError.unreadableArchive
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 512)) ?? Data()
        guard !head.isEmpty else { throw GameArchiveError.unreadableArchive }
        let bytes = [UInt8](head)
        if bytes.count >= 4, bytes[0] == 0x50, bytes[1] == 0x4B,
           [0x03, 0x05, 0x07].contains(bytes[2]), [0x04, 0x06, 0x08].contains(bytes[3]) {
            return .zip
        }
        if bytes.count >= 2, bytes[0] == 0x1F, bytes[1] == 0x8B { return .tarGzip }
        if bytes.count >= 3, bytes[0] == 0x42, bytes[1] == 0x5A, bytes[2] == 0x68 { return .tarBzip2 }
        if bytes.count >= 6, bytes[0] == 0xFD, bytes[1] == 0x37, bytes[2] == 0x7A,
           bytes[3] == 0x58, bytes[4] == 0x5A, bytes[5] == 0x00 { return .tarXz }
        if bytes.count >= 6, bytes[0] == 0x37, bytes[1] == 0x7A, bytes[2] == 0xBC,
           bytes[3] == 0xAF, bytes[4] == 0x27, bytes[5] == 0x1C { return .sevenZip }
        if bytes.count >= 6, bytes[0] == 0x52, bytes[1] == 0x61, bytes[2] == 0x72,
           bytes[3] == 0x21, bytes[4] == 0x1A, bytes[5] == 0x07 { return .rar }
        if bytes.count > 262, String(decoding: bytes[257..<262], as: UTF8.self) == "ustar" { return .tar }
        switch url.pathExtension.lowercased() {
        case "zip": return .zip
        case "tar": return .tar
        case "tgz", "gz": return .tarGzip
        case "tbz", "tbz2", "bz2": return .tarBzip2
        case "txz", "xz": return .tarXz
        case "7z": return .sevenZip
        case "rar": return .rar
        default: throw GameArchiveError.unreadableArchive
        }
    }
}

public struct GameExternalArchiveRequest: Sendable {
    public let archiveURL: URL
    public let format: GameArchiveContainerFormat
    /// Must not exist; the host extracts the ENTIRE archive tree here.
    public let destination: URL
    public let maximumBytes: Int
    public let maximumEntries: Int
    /// Optional archive password; hosts must never log it.
    public let password: String?

    public init(archiveURL: URL, format: GameArchiveContainerFormat, destination: URL,
                maximumBytes: Int, maximumEntries: Int, password: String? = nil) {
        self.archiveURL = archiveURL
        self.format = format
        self.destination = destination
        self.maximumBytes = maximumBytes
        self.maximumEntries = maximumEntries
        self.password = password
    }
}

public enum GameExternalArchiveError: Error, Equatable, Sendable {
    case formatUnavailable(GameArchiveContainerFormat, available: [GameArchiveContainerFormat])
    case hostFailed(String)
    /// The host tree contains links, devices or entries outside the root.
    case insecureTree(String)
    case limitExceeded(String)
    case destinationExists
}

/// Narrow typed port over the EXISTING host archive services. The host owns
/// format decoding, passwords and platform specifics; this package re-walks
/// and validates the produced tree before any project write, so a hostile or
/// buggy extraction cannot introduce links, traversal or unbounded content.
public protocol GameExternalArchiveHostPort: Sendable {
    func capabilities() async -> Set<GameArchiveContainerFormat>
    /// Extract the whole archive into `request.destination` (which does not
    /// exist). Must fail closed on links/traversal and honor the bounds.
    func extract(_ request: GameExternalArchiveRequest) async throws
}
