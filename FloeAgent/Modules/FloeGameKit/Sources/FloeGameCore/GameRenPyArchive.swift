// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Identifies standard desktop game archives without reading their Python
/// indexes. The official SDK still opens the archive in the build environment.
public enum GameRenPyArchive {
    public static func first(in reader: GameProjectReader,
                             paths: [GameRelativePath]) throws -> GameRelativePath? {
        for path in paths {
            let parts = path.value.split(separator: "/")
            guard parts.count == 2, parts[0] == "game", parts[1].hasSuffix(".rpa") else {
                continue
            }
            try Task.checkCancellation()
            let headerLength = 40
            guard let size = try reader.fileSize(path), size > 24,
                  let header = try reader.readPrefix(path, maximumBytes: headerLength),
                  header.count >= 24 else { continue }
            let minimumOffset: Int
            if header.starts(with: "RPA-3.0 ".utf8) {
                guard header.count >= 34, header[24] == 32,
                      UInt32(String(decoding: header[25..<33], as: UTF8.self), radix: 16) != nil
                else { continue }
                minimumOffset = 34
            } else if header.starts(with: "RPA-2.0 ".utf8) {
                minimumOffset = 24
            } else {
                continue
            }
            guard let offset = Int(String(decoding: header[8..<24], as: UTF8.self), radix: 16),
                  offset >= minimumOffset, offset < size else { continue }
            return path
        }
        return nil
    }
}
