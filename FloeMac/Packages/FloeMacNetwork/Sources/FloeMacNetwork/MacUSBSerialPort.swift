// SPDX-License-Identifier: MPL-2.0
//
// Explicitly selected Mac USB serial ports.
//
// This slice never scans for serial devices on its own: the catalog lists
// the callout nodes the system already exposes under /dev, and a session is
// admitted only for the exact path the person picked. Symbolic links are
// rejected so a crafted link cannot redirect an open outside /dev.

import Foundation

public struct MacUSBSerialPortDescriptor: Equatable, Sendable {
    public let path: String
    public let fileName: String
    public init(path: String, fileName: String) {
        self.path = path; self.fileName = fileName
    }
}

public enum MacUSBSerialPortError: Error, Equatable, Sendable {
    case emptyPath, notAbsolute, notCalloutDevice, parentReference, symbolicLink
}

public struct MacUSBSerialPortCatalog {
    private let deviceRoot: URL
    private let fileManager: FileManager

    public init(deviceRoot: URL = URL(fileURLWithPath: "/dev", isDirectory: true),
                fileManager: FileManager = .default) {
        self.deviceRoot = deviceRoot
        self.fileManager = fileManager
    }

    /// Callout nodes currently exposed by the system, sorted for stable UI.
    public func ports() -> [MacUSBSerialPortDescriptor] {
        let names = (try? fileManager.contentsOfDirectory(atPath: deviceRoot.path)) ?? []
        return names.filter { $0.hasPrefix("cu.") }
            .sorted()
            .map { name in
                MacUSBSerialPortDescriptor(path: deviceRoot.appendingPathComponent(name).path,
                                           fileName: name)
            }
    }

    /// Grammar check for a user-picked path before any open is attempted.
    /// Existence is not required here; the open reports a missing node.
    public func validate(path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MacUSBSerialPortError.emptyPath }
        guard trimmed.hasPrefix("/") else { throw MacUSBSerialPortError.notAbsolute }
        guard URL(fileURLWithPath: trimmed).deletingLastPathComponent().path
            == deviceRoot.path else { throw MacUSBSerialPortError.notCalloutDevice }
        guard trimmed.hasPrefix(deviceRoot.path + "/cu.") else {
            throw MacUSBSerialPortError.notCalloutDevice
        }
        let fileName = String(trimmed.dropFirst(deviceRoot.path.count + 1))
        guard fileName.count > 3, !fileName.contains("/") else {
            throw MacUSBSerialPortError.notCalloutDevice
        }
        guard fileName != ".", fileName != "..", !trimmed.split(separator: "/").contains("..") else {
            throw MacUSBSerialPortError.parentReference
        }
        // A live node must not be a symbolic link; a stale/absent node is
        // left for the open to report honestly.
        if (try? fileManager.destinationOfSymbolicLink(atPath: trimmed)) != nil {
            throw MacUSBSerialPortError.symbolicLink
        }
        return trimmed
    }
}
