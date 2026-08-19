// FloeCore — Safe file reading that maps Cocoa errors to readable messages.
//
// Foundation's `Data(contentsOf:)` throws `CocoaError.fileReadCorruptFile`
// ("无法打开该文件，因为它的格式不正确") for everything from missing files to
// permission errors. This extension maps those to `FloeError` with the file
// name so the UI shows something useful instead of a raw Cocoa error.

import Foundation

public extension Data {
    /// Reads a file, mapping Cocoa read errors to a readable `FloeError`.
    /// Use this instead of `Data(contentsOf:)` anywhere the error surfaces to
    /// the user.
    init(floeContentsOf url: URL, options: ReadingOptions = []) throws {
        do {
            try self.init(contentsOf: url, options: options)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain {
                let name = url.lastPathComponent
                switch error.code {
                case CocoaError.fileReadCorruptFile.rawValue:
                    throw FloeError.storageCorrupted("无法读取文件「\(name)」：文件可能已损坏或正在被其他进程占用")
                case CocoaError.fileReadNoSuchFile.rawValue:
                    throw FloeError.notFound("文件不存在：\(name)")
                case CocoaError.fileReadNoPermission.rawValue:
                    throw FloeError.validationFailed("没有权限读取文件「\(name)」")
                default:
                    throw FloeError.storageCorrupted("读取文件「\(name)」失败：\(error.localizedDescription)")
                }
            }
            throw error
        }
    }
}
