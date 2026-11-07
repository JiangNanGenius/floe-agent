// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import FloeLaTeXCore

public struct LaTeXResourceFile: Codable, Hashable, Sendable {
    public var path: String
    public var sha256: String
    public var byteCount: Int
    public var downloadURL: URL
    public init(path: String, sha256: String, byteCount: Int, downloadURL: URL) { self.path=path; self.sha256=sha256; self.byteCount=byteCount; self.downloadURL=downloadURL }
}
public struct LaTeXResourcePackage: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var version: String
    public var license: String
    public var dependencies: [String]
    public var files: [LaTeXResourceFile]
    public init(id: String, version: String, license: String, dependencies: [String] = [], files: [LaTeXResourceFile]) {
        self.id=id; self.version=version; self.license=license; self.dependencies=dependencies; self.files=files
    }
}
public struct LaTeXResourceStatus: Sendable {
    public var package: LaTeXResourcePackage
    public var installed: Bool
    public var bytesToDownload: Int
}

/// Stores reviewed document resources, never executable plug-ins or installers.
public actor LaTeXResourceStore {
    public nonisolated let root: URL
    private let catalog: [String:LaTeXResourcePackage]
    public init(root: URL, packages: [LaTeXResourcePackage]) throws {
        self.root=root.standardizedFileURL.resolvingSymlinksInPath()
        guard Set(packages.map(\.id)).count == packages.count else { throw LaTeXError.invalidProject }
        catalog=Dictionary(uniqueKeysWithValues:packages.map{($0.id,$0)})
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for package in packages {
            _ = try LaTeXPath.validate(package.id)
            guard !package.license.isEmpty else { throw LaTeXError.invalidOperation("A resource package needs a license record.") }
            for file in package.files {
                _ = try LaTeXPath.validate(file.path)
                guard file.sha256.count == 64, file.sha256.allSatisfy(\.isHexDigit), file.byteCount >= 0, file.byteCount <= 256*1024*1024,
                      file.downloadURL.scheme == "https", file.downloadURL.user == nil, file.downloadURL.password == nil,
                      !["dylib","so","dll","exe","wasm","a","o","pyc","luc","fmt"].contains((file.path as NSString).pathExtension.lowercased()) else { throw LaTeXError.invalidOperation("This file is outside the reviewed document resource profile.") }
            }
        }
    }
    public func packages() -> [LaTeXResourcePackage] { catalog.values.sorted{$0.id < $1.id} }
    public func dependencyOrder(_ identifiers: [String]) throws -> [LaTeXResourcePackage] {
        var visiting=Set<String>(), done=Set<String>(), output=[LaTeXResourcePackage]()
        func visit(_ id:String) throws {
            if done.contains(id) { return }
            guard !visiting.contains(id), let item=catalog[id] else { throw LaTeXError.unavailable("Missing or circular resource dependency: \(id)") }
            visiting.insert(id); for dep in item.dependencies { try visit(dep) }; visiting.remove(id); done.insert(id); output.append(item)
        }
        for id in identifiers { try visit(id) }; return output
    }
    public func status(_ id: String) throws -> LaTeXResourceStatus {
        guard let package=catalog[id] else { throw LaTeXError.unavailable("Unknown resource package: \(id)") }
        var missing=0,installed=true
        for file in package.files {
            let path=try LaTeXPath.child(file.path,root:directory(package,create:false))
            if !valid(path,file:file) { missing += file.byteCount;installed=false }
        }
        return .init(package:package,installed:installed,bytesToDownload:missing)
    }
    public func ensure(_ identifiers: [String], session: URLSession = .shared) async throws -> [LaTeXResourcePin] {
        let plan=try dependencyOrder(identifiers)
        for package in plan {
            for file in package.files {
                try Task.checkCancellation()
                let target=try LaTeXPath.child(file.path,root:directory(package),createParents:true)
                if valid(target,file:file) { continue }
                let (temporary,response)=try await session.download(from:file.downloadURL)
                defer { try? FileManager.default.removeItem(at:temporary) }
                guard let http=response as? HTTPURLResponse, http.statusCode == 200, response.url?.scheme == "https" else { throw LaTeXError.unavailable("The resource download did not finish.") }
                let size=try temporary.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? -1
                guard size==file.byteCount, valid(temporary,file:file) else { throw LaTeXError.checksumMismatch(file.path) }
                try Task.checkCancellation()
                // Re-resolve after suspension before committing verified bytes.
                let destination=try LaTeXPath.child(file.path,root:directory(package),createParents:true)
                try Data(contentsOf:temporary,options:.mappedIfSafe).write(to:destination,options:.atomic)
            }
        }
        return try plan.map { .init(identifier:$0.id,version:$0.version,sha256:LaTeXDigest.hash(try LaTeXDigest.encode($0))) }
    }
    public func resolve(_ path: String, pins: [LaTeXResourcePin]) throws -> URL? {
        _ = try LaTeXPath.validate(path)
        for pin in pins {
            guard let package=catalog[pin.identifier], package.version==pin.version,
                  LaTeXDigest.hash(try LaTeXDigest.encode(package))==pin.sha256 else { throw LaTeXError.unavailable("The project's resource snapshot is unavailable.") }
            if let file=package.files.first(where:{$0.path==path}) {
                let target=try LaTeXPath.child(path,root:directory(package,create:false))
                if valid(target,file:file) { return target }
            }
        }; return nil
    }
    private func directory(_ package: LaTeXResourcePackage,create:Bool=true) throws -> URL {
        let version=LaTeXDigest.hash(Data(package.version.utf8))
        let target=try LaTeXPath.child(package.id+"/"+version,root:root,createParents:create)
        if create {try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)}
        return target
    }
    private func valid(_ path: URL, file: LaTeXResourceFile) -> Bool {
        guard let values=try? path.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey]), values.isSymbolicLink != true, values.fileSize==file.byteCount,
              let handle=try? FileHandle(forReadingFrom:path) else { return false }
        defer { try? handle.close() }
        var digest=SHA256()
        do { while let part=try handle.read(upToCount:1024*1024), !part.isEmpty { digest.update(data:part) } } catch { return false }
        return digest.finalize().map{String(format:"%02x",$0)}.joined()==file.sha256
    }
}
