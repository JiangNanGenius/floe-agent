#if os(macOS)
import Foundation
import AppKit
@preconcurrency import ApplicationServices
import ScreenCaptureKit
import CryptoKit
import FloeMacBridgeProtocol

struct BridgeCleanupItem: Identifiable, Sendable {
    let category: String
    let itemID: String
    let version: String?
    let bytes: Int64
    var id: String { category + "/" + itemID + "/" + (version ?? "") }
    var title: String { version.map { itemID + " · " + $0 } ?? itemID }
}

extension BridgeService {
    func cleanupItems() async throws -> [BridgeCleanupItem] {
        let active = await jobs.activeTaskIDs()
        var result: [BridgeCleanupItem] = []
        let tasks = paths.root.appendingPathComponent("Tasks")
        for task in try FileManager.default.contentsOfDirectory(at: tasks, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            let id = task.lastPathComponent
            guard BridgeWire.validID(id), !active.contains(id),
                  let safe = try? paths.managed("Tasks", id: id),
                  let receipt = try? BridgePaths.safe("result.json", under: safe),
                  FileManager.default.fileExists(atPath: receipt.path) else { continue }
            result.append(BridgeCleanupItem(category: "Tasks", itemID: id, version: nil, bytes: try size(safe)))
        }
        let installed = try skillIndex()
        let skills = paths.root.appendingPathComponent("Skills")
        for skill in try FileManager.default.contentsOfDirectory(at: skills, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            let id = skill.lastPathComponent
            guard BridgeWire.validID(id), let safe = try? paths.managed("Skills", id: id) else { continue }
            for version in try FileManager.default.contentsOfDirectory(at: safe, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                let directory = version.lastPathComponent
                guard BridgeWire.validID(directory), installed[id]?["directory"]?.string != directory,
                      !skillPins.values.contains(where: { $0.contains(id + "/" + directory) }),
                      let checked = try? BridgePaths.safe(directory, under: safe) else { continue }
                result.append(BridgeCleanupItem(category: "Skills", itemID: id, version: directory, bytes: try size(checked)))
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    @MainActor
    func permissions(request: String?) -> [String: BridgeValue] {
        if request == "screenCapture", !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if request == "accessibility" {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        return ["screenCapture": .bool(CGPreflightScreenCaptureAccess()), "accessibility": .bool(AXIsProcessTrusted())]
    }
    func captureScreen() async throws -> [String: BridgeValue] {
        guard CGPreflightScreenCaptureAccess() else { throw BridgeFailure.remote("Allow screen recording for Floe Bridge in System Settings.") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw BridgeFailure.remote("No display is available.") }
        let configuration = SCStreamConfiguration()
        configuration.width = min(display.width, 1600)
        configuration.height = max(1, display.height * configuration.width / max(display.width, 1))
        configuration.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration)
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        guard let data, data.count < BridgeWire.maximumFrameBytes / 2 else { throw BridgeFailure.remote("The screenshot is too large to transfer.") }
        return ["png": .string(data.base64EncodedString()), "width": .integer(Int64(image.width)), "height": .integer(Int64(image.height))]
    }
    @MainActor
    func inspectAccessibility() throws -> [String: BridgeValue] {
        guard AXIsProcessTrusted() else { throw BridgeFailure.remote("Allow Accessibility for Floe Bridge in System Settings.") }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return ["focused": .null] }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        var result: [String: BridgeValue] = [:]
        for (key, attribute) in [("role", kAXRoleAttribute), ("title", kAXTitleAttribute), ("value", kAXValueAttribute)] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let text = value as? String {
                result[key] = .string(String(text.prefix(16_384)))
            }
        }
        return result
    }
    func storage() async throws -> [String: BridgeValue] {
        var values: [String: BridgeValue] = [:]
        for category in ["State", "Workspaces", "Tasks", "Skills", "Environments"] {
            let root = paths.root.appendingPathComponent(category)
            values[category] = .integer(try size(root))
        }
        values["Caches"] = .integer(try size(paths.caches)); values["Logs"] = .integer(try size(paths.logs))
        return values
    }
    private func size(_ root: URL) throws -> Int64 {
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey]) else { return 0 }
        var bytes: Int64 = 0
        for case let file as URL in items {
            let value = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey])
            if value.isSymbolicLink == true { items.skipDescendants(); continue }
            if value.isRegularFile == true { bytes += Int64(value.fileAllocatedSize ?? 0) }
        }
        return bytes
    }
    func cleanup(_ p: [String: BridgeValue]) async throws -> [String: BridgeValue] {
        let category = p["category"]?.string ?? ""
        let root: URL
        if category == "Caches" {
            // In-progress upload staging cannot be collected.
            guard transfersAreIdle() else { throw BridgeFailure.remote("A file transfer is still using the cache.") }
            root = paths.caches
        } else if category == "Logs" { root = paths.logs }
        else if category == "Tasks" {
            guard let id = p["id"]?.string, !(await jobs.activeTaskIDs()).contains(id) else { throw BridgeFailure.remote("This task is still running.") }
            root = try paths.managed("Tasks", id: id)
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("result.json").path) else { throw BridgeFailure.remote("This task has no confirmed exit. Its files were retained.") }
        } else if category == "Skills" {
            guard let id = p["id"]?.string, let version = p["version"]?.string,
                  BridgeWire.validID(version), !skillPins.values.contains(where: { $0.contains(id + "/" + version) }) else { throw BridgeFailure.remote("This skill version is in use.") }
            let index = try skillIndex()
            guard index[id]?["directory"]?.string != version else { throw BridgeFailure.remote("Remove the installed skill before cleaning its active version.") }
            root = try BridgePaths.safe(version, under: paths.managed("Skills", id: id))
        } else { throw BridgeFailure.remote("Only caches, logs and unused managed items can be cleaned here.") }
        let bytes = try size(root)
        try await MainActor.run {
            let items = (category == "Caches" || category == "Logs")
                ? try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) : [root]
            for file in items {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: file, resultingItemURL: &resulting)
            }
        }
        return ["movedToTrashBytes": .integer(bytes)]
    }
    func skillIndex() throws -> [String: [String: BridgeValue]] {
        let url = paths.root.appendingPathComponent("State/skills.json")
        if !FileManager.default.fileExists(atPath: url.path) { return [:] }
        return try BridgeWire.decode([String: [String: BridgeValue]].self, from: Data(contentsOf: url))
    }
    func skill(_ method: String, _ p: [String: BridgeValue]) async throws -> [String: BridgeValue] {
        var index = try skillIndex()
        if method == "skill.list" { return ["skills": .object(index.mapValues(BridgeValue.object))] }
        guard let id = p["id"]?.string, BridgeWire.validID(id) else { throw BridgeFailure.unsafePath }
        if method == "skill.pin" {
            guard let version = p["directory"]?.string ?? index[id]?["directory"]?.string,
                  BridgeWire.validID(version), let owner = p["owner"]?.string, BridgeWire.validID(owner) else { throw BridgeFailure.remote("Skill is not installed.") }
            let receiptURL = paths.root.appendingPathComponent("State/SkillVersions/" + id + "/" + version + ".json")
            let receipt = try BridgeWire.decode([String: BridgeValue].self, from: Data(contentsOf: receiptURL))
            let installedPath = try paths.managed("Skills", id: id).appendingPathComponent(version)
            guard FileManager.default.fileExists(atPath: installedPath.path) else { throw BridgeFailure.remote("The pinned skill version is missing.") }
            skillPins[owner, default: []].insert(id + "/" + version)
            try BridgeWire.encode(skillPins).write(to: paths.root.appendingPathComponent("State/skill-pins.json"), options: .atomic)
            return receipt
        }
        if method == "skill.unpin" {
            guard let owner = p["owner"]?.string else { throw BridgeFailure.unsafePath }
            skillPins.removeValue(forKey: owner)
            try BridgeWire.encode(skillPins).write(to: paths.root.appendingPathComponent("State/skill-pins.json"), options: .atomic)
            return [:]
        }
        if method == "skill.remove" {
            index.removeValue(forKey: id)
            try BridgeWire.encode(index).write(to: paths.root.appendingPathComponent("State/skills.json"), options: .atomic)
            return [:] // Versions remain recoverable and pinned tasks retain their immutable path.
        }
        guard method == "skill.activate", let version = p["version"]?.string, BridgeWire.validID(version),
              let commit = p["commit"]?.string, commit.count == 40,
              let digest = p["digest"]?.string, digest.count == 64,
              let files = p["files"]?.array, !files.isEmpty,
              let workspaceID = p["workspaceID"]?.string else { throw BridgeFailure.remote("The original skill package is incomplete.") }
        let source = try paths.managed("Workspaces", id: workspaceID)
        let skillRoot = try paths.managed("Skills", id: id)
        try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
        let directory = version + "-" + String(digest.prefix(16))
        let destination = skillRoot.appendingPathComponent(directory)
        let stage = skillRoot.appendingPathComponent(".install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        var manifest: [[String: String]] = []
        for value in files {
            guard let file = value.object, let path = file["path"]?.string, let expected = file["sha256"]?.string, let sourcePath = file["sourcePath"]?.string, let mode = file["mode"]?.string, ["100644", "100755"].contains(mode) else { throw BridgeFailure.unsafePath }
            let input = try BridgePaths.safe(path, under: source), output = try BridgePaths.safe(path, under: stage)
            let bytes = try Data(contentsOf: input, options: .mappedIfSafe)
            guard BridgeWire.digest(bytes) == expected else { throw BridgeFailure.remote("Original skill file verification failed.") }
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: input, to: output)
            try FileManager.default.setAttributes([.posixPermissions: mode == "100755" ? 0o755 : 0o644], ofItemAtPath: output.path)
            manifest.append(["path": path, "sourcePath": sourcePath, "sha256": expected, "mode": mode])
        }
        guard manifest.contains(where: { $0["path"] == "SKILL.md" }),
              BridgeWire.digest(try BridgeWire.encode(manifest.sorted { $0["path"]! < $1["path"]! })) == digest else { throw BridgeFailure.remote("Original skill manifest verification failed.") }
        let versionReceipt = paths.root.appendingPathComponent("State/SkillVersions/" + id + "/" + directory + ".json")
        if FileManager.default.fileExists(atPath: destination.path) {
            let old = try BridgeWire.decode([String: BridgeValue].self, from: Data(contentsOf: versionReceipt))
            guard old["digest"]?.string == digest, old["commit"]?.string == commit else { throw BridgeFailure.remote("A published skill version cannot change in place.") }
        } else { try FileManager.default.moveItem(at: stage, to: destination) }
        index[id] = ["id": .string(id), "version": .string(version), "commit": .string(commit),
                     "digest": .string(digest), "directory": .string(directory), "path": .string(destination.path),
                     "source": p["source"] ?? .string(""), "license": p["license"] ?? .string("")]
        let receipts = paths.root.appendingPathComponent("State/SkillVersions/" + id)
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        try BridgeWire.encode(index[id] ?? [:]).write(to: receipts.appendingPathComponent(directory + ".json"), options: .atomic)
        try BridgeWire.encode(index).write(to: paths.root.appendingPathComponent("State/skills.json"), options: .atomic)
        return index[id] ?? [:]
    }
}
#endif
