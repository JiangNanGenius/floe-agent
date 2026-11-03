// Keep automatic Metal cache locks in the App-owned Caches directory on
// iOS-on-Mac, where RunningBoard permits them during system suspension.
// No private Metal entry point, HOME override, lock bypass or background lease.
#if canImport(UIKit)
import Foundation
import UIKit
import Darwin

@MainActor
enum MacMetalCacheLocation {
    private static var configured = false
    static func prepare() {
        guard !configured, ProcessInfo.processInfo.isiOSAppOnMac else { return }
        configured = true
        var report: [String: Any] = ["bundle": Bundle.main.bundleIdentifier ?? "", "at": Date().timeIntervalSince1970]
        var receipt: URL?
        do {
            guard let bundle = Bundle.main.bundleIdentifier, !bundle.isEmpty,
                  !bundle.contains("/"), bundle != ".", bundle != ".." else { return }
            let fm = FileManager.default
            let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            receipt = caches.appendingPathComponent("Floe-MetalCacheLocation.json")
            let count = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
            guard count > 1, count < 16384 else { throw CocoaError(.fileNoSuchFile) }
            var chars = [CChar](repeating: 0, count: count)
            guard confstr(_CS_DARWIN_USER_CACHE_DIR, &chars, count) == count else { throw CocoaError(.fileReadUnknown) }
            let raw = URL(fileURLWithPath: String(cString: chars), isDirectory: true).standardizedFileURL
            guard raw.isFileURL, raw.path.hasPrefix("/var/folders/") || raw.path.hasPrefix("/private/var/folders/") else { throw CocoaError(.fileReadUnknown) }
            // Metal appends the exact main-bundle ID to this public Darwin
            // cache root (which may already be per-bundle for iOS-on-Mac).
            let source = raw.appendingPathComponent(bundle, isDirectory: true).appendingPathComponent("com.apple.metal", isDirectory: true)
            let target = caches.appendingPathComponent("FloeMetalSystemCache", isDirectory: true)
            report["darwinCacheRoot"] = raw.path; report["source"] = source.path; report["target"] = target.path
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            let attributes = try? fm.attributesOfItem(atPath: source.path)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                guard source.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() else { throw CocoaError(.fileWriteFileExists) }
                report["result"] = "already-owned"
            } else {
                if fm.fileExists(atPath: source.path) {
                    guard attributes?[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteFileExists) }
                    // This is before application/graphics initialization. Keep
                    // the previous regenerable cache intact for diagnosis.
                    let old = target.deletingLastPathComponent().appendingPathComponent("FloeMetalPrevious-" + UUID().uuidString, isDirectory: true)
                    try fm.moveItem(at: source, to: old)
                    report["preservedPrevious"] = old.path
                }
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: source, withDestinationURL: target)
                report["result"] = "owned-cache-linked"
            }
            report["resolvedSource"] = source.resolvingSymlinksInPath().path
        } catch { report["result"] = "not-configured"; report["error"] = String(describing: error) }
        if let receipt, let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? bytes.write(to: receipt, options: .atomic)
        }
    }
}
#endif
