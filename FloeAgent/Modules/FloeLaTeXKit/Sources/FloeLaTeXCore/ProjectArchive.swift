// SPDX-License-Identifier: MPL-2.0
import Foundation
import ZIPFoundation

public enum LaTeXProjectArchive {
    public static func inspect(_ url: URL, limits: LaTeXProjectLimits = .init()) throws -> [String:Data] {
        let archive=try Archive(url:url,accessMode:.read)
        var entries=[Entry](), total:UInt64=0
        for entry in archive {
            if entry.path.hasPrefix("__MACOSX/") || entry.path.hasSuffix("/.DS_Store") || entry.path == ".DS_Store" { continue }
            guard entry.type != .symlink else { throw LaTeXError.invalidPath(entry.path) }
            if entry.type == .directory { _ = try LaTeXPath.validate(String(entry.path.drop(while:{$0=="/"})).trimmingCharacters(in:CharacterSet(charactersIn:"/"))); continue }
            _ = try LaTeXPath.validate(entry.path)
            total += entry.uncompressedSize
            guard entries.count < limits.maximumFiles, entry.uncompressedSize <= limits.maximumFileBytes, total <= limits.maximumProjectBytes else { throw LaTeXError.limitExceeded("archive size") }
            entries.append(entry)
        }
        let prefix: String
        if let first=entries.first?.path.split(separator:"/").first,
           entries.allSatisfy({ $0.path.hasPrefix(String(first)+"/") }) { prefix=String(first)+"/" } else { prefix="" }
        var files=[String:Data](), keys=Set<String>()
        for entry in entries {
            let path=String(entry.path.dropFirst(prefix.count)); _ = try LaTeXPath.validate(path)
            guard keys.insert(LaTeXPath.collisionKey(path)).inserted else { throw LaTeXError.duplicatePath(path) }
            var data=Data()
            let checksum=try archive.extract(entry,bufferSize:65536) { chunk in
                try Task.checkCancellation()
                guard chunk.count <= limits.maximumFileBytes-data.count else { throw LaTeXError.limitExceeded(path) }
                data.append(chunk)
            }
            guard checksum==entry.checksum, data.count==entry.uncompressedSize else { throw LaTeXError.checksumMismatch(path) }
            files[path]=data
        }
        return files
    }
    public static func recommendedMainFile(_ files: [String:Data]) throws -> String {
        for candidate in ["main.tex","paper.tex","document.tex"] where files[candidate] != nil { return candidate }
        let candidates=files.keys.filter { ($0 as NSString).pathExtension.lowercased()=="tex" }.sorted()
        for path in candidates {
            if let data=files[path], let source=String(data:data,encoding:.utf8),
               source.range(of:#"(?m)^\s*\\documentclass(?:\s*\[[^\]]*\])?\s*\{"#,options:.regularExpression) != nil { return path }
        }
        guard let first=candidates.first else { throw LaTeXError.invalidOperation("This archive contains no LaTeX source file.") }; return first
    }
    public static func export(_ snapshot: LaTeXProjectSnapshot, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath:destination.path) else { throw LaTeXError.duplicatePath(destination.lastPathComponent) }
        let staging=destination.deletingLastPathComponent().appendingPathComponent("."+UUID().uuidString+".zip")
        defer { try? FileManager.default.removeItem(at:staging) }
        let archive=try Archive(url:staging,accessMode:.create)
        for entry in snapshot.manifest.files {
            try Task.checkCancellation()
            let path=try LaTeXPath.child(entry.path,root:snapshot.sourceRoot)
            let data=try Data(contentsOf:path)
            guard LaTeXDigest.hash(data)==entry.sha256 else { throw LaTeXError.changedFile(entry.path) }
            try archive.addEntry(with:entry.path,relativeTo:snapshot.sourceRoot,compressionMethod:.deflate)
        }
        try FileManager.default.moveItem(at:staging,to:destination)
    }
}
