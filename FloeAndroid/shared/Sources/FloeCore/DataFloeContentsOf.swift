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
                    throw FloeError.storageCorrupted(FloeL10n.l("core.data_floe_contents_of.could_not_read_the_file_it", name))
                case CocoaError.fileReadNoSuchFile.rawValue:
                    throw FloeError.notFound(FloeL10n.l("core.data_floe_contents_of.file_does_not_exist", name))
                case CocoaError.fileReadNoPermission.rawValue:
                    throw FloeError.validationFailed(FloeL10n.l("core.data_floe_contents_of.no_permission_to_read_the_file", name))
                default:
                    throw FloeError.storageCorrupted(FloeL10n.l("core.data_floe_contents_of.failed_to_read_the_file", name, error.localizedDescription))
                }
            }
            throw error
        }
    }
}
