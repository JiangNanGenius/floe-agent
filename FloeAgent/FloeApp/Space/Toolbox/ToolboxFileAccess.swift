// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import FloeToolboxUtilities
import FloeToolboxWorkbenches

@MainActor final class ToolboxFileAccess: ObservableObject {
    @Published var presenting = false
    @Published private(set) var types: [UTType] = [.content]
    private var pending: CheckedContinuation<URL?, Error>?
    func choose(_ types: [UTType] = [.content]) async throws -> URL? {
        guard pending == nil else { throw CocoaError(.userCancelled) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { pending = $0; self.types = types; presenting = true }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.success(nil)) } }
    }
    func finish(_ result: Result<URL?, Error>) {
        let continuation = pending; pending = nil; presenting = false
        continuation?.resume(with: result)
    }
    func checksumFile() async throws -> ToolboxSelectedChecksumFile? {
        // A checksum accepts every regular file, including formats without
        // public.content conformance such as G-code and DXF.
        guard let url = try await choose([.data]) else { return nil }
        let reader = try ToolboxSelectedFileReader(url: url)
        return ToolboxSelectedChecksumFile(title: url.lastPathComponent, byteCount: reader.byteCount,
            read: { offset, maximum in try await reader.read(offset: offset, maximum: maximum) })
    }
    func image() async throws -> Data? {
        guard let url = try await choose([.image]) else { return nil }
        let reader = try ToolboxSelectedFileReader(url: url)
        guard reader.byteCount <= 16 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
        var bytes = Data()
        while true {
            let chunk = try await reader.read(offset: UInt64(bytes.count), maximum: 65_536)
            if chunk.isEmpty { return bytes }
            guard bytes.count + chunk.count <= 16 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
            bytes.append(chunk)
        }
    }
}

private actor ToolboxSelectedFileReader {
    nonisolated let byteCount: UInt64
    private let url: URL
    private let scoped: Bool
    private let handle: FileHandle
    init(url: URL) throws {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let count = values.fileSize, count >= 0 else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            byteCount = UInt64(count)
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
    func read(offset: UInt64, maximum: Int) throws -> Data {
        try Task.checkCancellation()
        guard (1...1_024 * 1_024).contains(maximum), offset <= byteCount else { throw CocoaError(.fileReadTooLarge) }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: maximum) ?? Data()
    }
    deinit {
        try? handle.close()
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}
#endif
