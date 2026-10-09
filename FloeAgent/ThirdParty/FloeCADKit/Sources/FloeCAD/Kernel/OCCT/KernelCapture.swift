//
//  KernelCapture.swift
//  openshape3d — failing-op capture (docs/FREECAD_PLAYBOOK.md D2)
//
//  When a kernel op fails, the inputs are transient: the live preview or the
//  replay owns them for a moment and they are gone, so reproducing the
//  failure means rebuilding the whole model by hand. This captures them at
//  the point of detection instead — each failure becomes a directory of
//  `.brep` blobs plus a `manifest.json` naming the op, its parameters and
//  the typed error, replayable offline by `KernelCaptureReplay` and
//  promotable to a committed regression fixture
//  (openshape3dTests/Fixtures/Captures).
//
//  The pattern is FreeCAD's, twice over: its TechDraw module dumps every
//  intermediate shape of a pipeline behind one debug preference ("flip the
//  flag, reproduce, zip the folder"), and its document format IS the repro
//  artifact because every feature's shape is serialized. Our documents only
//  hold shapes that SUCCEEDED — this fills the gap for the ones that didn't.
//

import OCCTShim
import Foundation

#if DEBUG

/// DEBUG-only. On by default in the running app; off under XCTest (the suite
/// exercises failure paths on purpose, hundreds of times per run).
/// `OS3D_KERNEL_CAPTURE=1` forces on, `=0` forces off.
nonisolated enum KernelCapture {

    /// Tests point capture at their own temp directory. Read/written only on
    /// the MainActor in practice (all OCCT work runs there — see
    /// `BRepHandle`'s caveat), which is what makes the `unsafe` safe.
    nonisolated(unsafe) static var directoryOverride: URL?

    /// Tests force capture on — the XCTest default below is off, and
    /// `ProcessInfo.environment` cannot be changed once read.
    nonisolated(unsafe) static var forceEnabledForTesting = false

    static var isEnabled: Bool {
        if forceEnabledForTesting { return true }
        switch ProcessInfo.processInfo.environment["OS3D_KERNEL_CAPTURE"] {
        case "0": return false
        case "1": return true
        default: return NSClassFromString("XCTestCase") == nil
        }
    }

    /// Newest-first retention: a debugging session that hits the same broken
    /// op in a loop must not fill the sandbox.
    static let keepCount = 20

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("KernelCaptures", isDirectory: true)
    }

    /// Capture a failed op. Called from the failure paths of the
    /// `OCCTKernel.*Result` functions — the one seam below both the feature
    /// replay and the interactive tools, so both are covered identically.
    /// Never throws into the op path: a capture that cannot be written is
    /// dropped, because the op's own error is the thing that matters.
    @discardableResult
    static func recordFailure(op: String,
                              inputs: [(label: String, handle: BRepHandle)],
                              params: [String: Any],
                              error: OCCTOpError) -> URL? {
        guard isEnabled else { return nil }
        return write(op: op, inputs: inputs, params: params,
                     extra: ["error": String(describing: error),
                             "message": error.message])
    }

    /// Capture the CURRENT state on request — the "op succeeded but the
    /// geometry looks wrong" case no failure hook can see. Explicitly
    /// requested (the `/v1/capture` endpoint), so it ignores the XCTest
    /// default and honours only an explicit `OS3D_KERNEL_CAPTURE=0`.
    @discardableResult
    static func recordSnapshot(inputs: [(label: String, handle: BRepHandle)],
                               note: String) -> URL? {
        guard ProcessInfo.processInfo.environment["OS3D_KERNEL_CAPTURE"] != "0"
        else { return nil }
        return write(op: "snapshot", inputs: inputs,
                     params: ["note": note], extra: [:])
    }

    // MARK: - Writing

    private static func write(op: String,
                              inputs: [(label: String, handle: BRepHandle)],
                              params: [String: Any],
                              extra: [String: Any]) -> URL? {
        let fileManager = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmssSSS"
        let stamp = formatter.string(from: Date())
        let suffix = UUID().uuidString.prefix(4)
        let bundle = directory.appendingPathComponent(
            "\(stamp)-\(op)-\(suffix)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: bundle,
                                            withIntermediateDirectories: true)
            var inputRows: [[String: Any]] = []
            var usedFiles = Set<String>()
            for (label, handle) in inputs {
                guard let blob = OCCTKernel.serialize(handle) else {
                    inputRows.append(["label": label, "unserializable": true])
                    continue
                }
                // Labels are body names in a snapshot, and two bodies can
                // share one ("Extrude"): the second file used to overwrite
                // the first while the manifest listed both.
                var file = "\(label).brep"
                var copy = 2
                while !usedFiles.insert(file).inserted {
                    file = "\(label)-\(copy).brep"
                    copy += 1
                }
                try blob.write(to: bundle.appendingPathComponent(file))
                let faceCounts = OCCTKernel.faceTypeCounts(handle)
                // Enough per-input context to read the manifest without
                // loading the shapes: was garbage already going IN?
                inputRows.append([
                    "label": label,
                    "file": file,
                    "volumeMM3": OCCTKernel.volume(handle),
                    "maxTolerance": OCCTBridge.maxTolerance(of: handle.shape),
                    "valid": OCCTKernel.healthReport(for: handle).isValid,
                    "faceCounts": ["planar": faceCounts.planar,
                                   "cylindrical": faceCounts.cylindrical,
                                   "other": faceCounts.other],
                ])
            }
            var manifest: [String: Any] = [
                "version": 1,
                "op": op,
                "date": ISO8601DateFormatter().string(from: Date()),
                "params": params,
                "inputs": inputRows,
            ]
            for (key, value) in extra { manifest[key] = value }
            let json = try JSONSerialization.data(
                withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: bundle.appendingPathComponent("manifest.json"))
            prune()
            NSLog("OS3D kernel capture: %@ -> %@", op, bundle.path)
            return bundle
        } catch {
            try? fileManager.removeItem(at: bundle)
            return nil
        }
    }

    /// Drop the oldest bundles past `keepCount`. Timestamp-prefixed names
    /// sort chronologically, so name order IS age order.
    private static func prune() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return }
        let bundles = entries
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in bundles.dropFirst(keepCount) {
            try? fileManager.removeItem(at: stale)
        }
    }
}

#else

/// Release builds compile the call sites but never capture.
nonisolated enum KernelCapture {
    @discardableResult
    static func recordFailure(op: String,
                              inputs: [(label: String, handle: BRepHandle)],
                              params: [String: Any],
                              error: OCCTOpError) -> URL? { nil }
    @discardableResult
    static func recordSnapshot(inputs: [(label: String, handle: BRepHandle)],
                               note: String) -> URL? { nil }
}

#endif
