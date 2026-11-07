// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeFontCompiler
import FloeHeavyEditorSupport
import ZIPFoundation

public actor FontCompilerService {
    private let scratchRoot: URL
    public init(scratchRoot: URL) throws {
        guard scratchRoot.isFileURL else { throw HeavyEditorError.invalidDocument }
        self.scratchRoot = scratchRoot.standardizedFileURL.resolvingSymlinksInPath()
    }
    public nonisolated var nativeExtension: HeavyEditorNativeExtension {
        HeavyEditorNativeExtension(operations:["font.compile"]) { [self] name, arguments in
            guard name == "font.compile" else { throw HeavyEditorError.invalidCommand }
            return try await compile(arguments)
        }
    }
    public func compile(_ arguments: EditorJSON) async throws -> EditorJSON {
        guard let base64 = arguments["archive"].string, let data = Data(base64Encoded:base64) else { throw HeavyEditorError.invalidDocument }
        let archive = try Archive(data:data,accessMode:.read)
        let directory = scratchRoot.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        var total: UInt64 = 0
        for entry in archive {
            let path = entry.path
            let pieces = path.split(separator:"/",omittingEmptySubsequences:false)
            guard entry.type != .symlink, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
                  !pieces.contains(".."), !pieces.contains("."), !path.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
                  path.count < 1024 else { throw HeavyEditorError.invalidDocument }
            total += UInt64(entry.uncompressedSize)
            guard total <= 256 * 1024 * 1024 else { throw HeavyEditorError.invalidDocument }
            if entry.type == .directory { continue }
            let target = directory.appendingPathComponent(path).standardizedFileURL
            guard target.path.hasPrefix(directory.path + "/") else { throw HeavyEditorError.invalidDocument }
            var bytes = Data()
            _ = try archive.extract(entry,consumer:{ bytes.append($0) })
            if target.pathExtension.lowercased() == "fea" {
                // The editor writes a self-contained feature program. Includes
                // cannot give an imported font access to host filesystem paths.
                let source = String(decoding:bytes,as:UTF8.self)
                let cleaned = source.split(separator:"\n",omittingEmptySubsequences:false).map { line in
                    String(line.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false)[0])
                }.joined(separator:"\n")
                guard cleaned.range(of:#"\binclude\s*\("#,options:.regularExpression) == nil else {
                    throw HeavyEditorError.engine(EditorText.t("请先将引用的特性文件内容合并到当前特性中。","Merge included feature-file content into the current feature program first."))
                }
            }
            if target.pathExtension.lowercased() == "designspace" {
                let source = String(decoding:bytes,as:UTF8.self)
                // Only the editor's fixed, sibling master names are accepted.
                let regex = try NSRegularExpression(pattern:#"filename\s*=\s*["']([^"']+)["']"#)
                let range = NSRange(source.startIndex...,in:source)
                for match in regex.matches(in:source,range:range) {
                    guard let value = Range(match.range(at:1),in:source),
                          source[value].range(of:#"^master[0-9]+\.ufo$"#,options:.regularExpression) != nil else { throw HeavyEditorError.invalidDocument }
                }
            }
            try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            try bytes.write(to:target,options:.atomic)
        }
        // Static fonts compile directly from their fixed UFO root. This avoids
        // inventing a dummy variation axis to satisfy an empty-location parser.
        let source = directory.appendingPathComponent(arguments["static"] == .bool(true) ? "master0.ufo" : "font.designspace")
        guard FileManager.default.fileExists(atPath:source.path) else { throw HeavyEditorError.invalidDocument }
        // Compilation is a native library call, and remains owned until it
        // finishes. Cancelling a UI request fences its result, not this C stack.
        let bytes: Data = try await Task.detached(priority:.userInitiated) {
            let result = source.path.withCString { floe_font_compile($0) }
            defer { floe_font_result_free(result) }
            if let error = result.error { throw HeavyEditorError.engine(String(cString:error)) }
            guard let pointer = result.bytes, result.length > 0 else { throw HeavyEditorError.invalidDocument }
            return Data(bytes:pointer,count:result.length)
        }.value
        try Task.checkCancellation()
        return .object(["base64":.string(bytes.base64EncodedString()),"bytes":.number(Double(bytes.count))])
    }
}
