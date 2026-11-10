import Foundation

/// Validates authenticated wire-1 payloads. A malformed reply is not a
/// protocol-version failure and never establishes a mutation's outcome.
public enum BridgeResponseValidation {
    public struct FileListPage: Sendable {
        public let files: [[String: BridgeValue]]
        public let next: Int64?
    }

    public struct PollPage: Sendable {
        public let data: Data
        public let offset: Int64
        public let totalBytes: Int64
        public let inputBytes: Int64
        public let alive: Bool
        public let exitCode: Int32?
        public let outcomeUnknown: Bool
    }

    public static let maximumListedFiles = 100_000

    public static func workspaceRoot(_ payload: [String: BridgeValue]) throws -> String {
        guard let path = payload["root"]?.string, path.hasPrefix("/"), !path.contains("\0") else {
            throw BridgeFailure.invalidResponse
        }
        return path
    }

    public static func transferID(_ payload: [String: BridgeValue]) throws -> String {
        guard let id = payload["transferID"]?.string, BridgeWire.validID(id) else {
            throw BridgeFailure.invalidResponse
        }
        return id
    }

    public static func fileListPage(_ payload: [String: BridgeValue], offset: Int64,
                                    seenPaths: Set<String>) throws -> FileListPage {
        guard offset >= 0, let values = payload["files"]?.array,
              values.count <= maximumListedFiles - seenPaths.count else {
            throw BridgeFailure.invalidResponse
        }
        var paths = seenPaths
        var files: [[String: BridgeValue]] = []
        for value in values {
            guard let row = value.object, let path = row["path"]?.string,
                  validRelativePath(path), let size = row["size"]?.integer, size >= 0,
                  let hash = row["sha256"]?.string, validDigest(hash),
                  paths.insert(path).inserted else { throw BridgeFailure.invalidResponse }
            files.append(row)
        }
        let next: Int64?
        switch payload["next"] {
        case .null?: next = nil
        case .integer(let value)?:
            let (end, overflow) = offset.addingReportingOverflow(Int64(files.count))
            guard !overflow, !files.isEmpty, value == end, value > offset else {
                throw BridgeFailure.invalidResponse
            }
            next = value
        default: throw BridgeFailure.invalidResponse
        }
        return FileListPage(files: files, next: next)
    }

    public static func fileChunk(_ payload: [String: BridgeValue], offset: Int64,
                                 totalBytes: Int64) throws -> Data {
        let data = try decodedData(payload, limit: BridgeWire.pageBytes)
        let (end, overflow) = offset.addingReportingOverflow(Int64(data.count))
        guard offset >= 0, totalBytes >= offset, !overflow, end <= totalBytes,
              payload["offset"]?.integer == end,
              !data.isEmpty || offset == totalBytes else { throw BridgeFailure.invalidResponse }
        return data
    }

    public static func poll(_ payload: [String: BridgeValue], offset: Int64,
                            limit: Int = BridgeWire.pageBytes) throws -> PollPage {
        let data = try decodedData(payload, limit: limit)
        let (end, overflow) = offset.addingReportingOverflow(Int64(data.count))
        guard offset >= 0, !overflow, payload["offset"]?.integer == end,
              let total = payload["totalBytes"]?.integer, total >= 0,
              let alive = payload["alive"]?.bool else { throw BridgeFailure.invalidResponse }
        let unknown: Bool
        switch payload["outcomeUnknown"] {
        case nil: unknown = false // The live wire-1 job response omits this field.
        case .bool(let value)?: unknown = value
        default: throw BridgeFailure.invalidResponse
        }
        let input: Int64
        switch payload["inputBytes"] {
        case nil: input = 0 // Saved jobs on the companion omit this field.
        case .integer(let value)? where value >= 0: input = value
        default: throw BridgeFailure.invalidResponse
        }
        let code: Int32?
        switch payload["exitCode"] {
        case .null? where alive || unknown: code = nil
        case .integer(let value)? where !alive && !unknown:
            guard let exact = Int32(exactly: value) else { throw BridgeFailure.invalidResponse }
            code = exact
        default: throw BridgeFailure.invalidResponse
        }
        guard !unknown || !alive, alive || end <= total,
              !data.isEmpty || offset >= total else { throw BridgeFailure.invalidResponse }
        // A live wire-1 job can append between status() and read(). Its bytes
        // are real, but the earlier total may lag this page's authenticated end.
        return PollPage(data: data, offset: end, totalBytes: max(total, end), inputBytes: input,
                        alive: alive, exitCode: code, outcomeUnknown: unknown)
    }

    private static func decodedData(_ payload: [String: BridgeValue], limit: Int) throws -> Data {
        guard limit > 0, limit <= BridgeWire.pageBytes, let text = payload["data"]?.string,
              text.utf8.count <= ((limit + 2) / 3) * 4,
              let data = Data(base64Encoded: text), data.count <= limit else {
            throw BridgeFailure.invalidResponse
        }
        return data
    }

    private static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func validDigest(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
