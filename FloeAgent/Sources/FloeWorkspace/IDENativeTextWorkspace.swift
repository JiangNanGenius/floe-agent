// FloeWorkspace — Native IDE text workspace.
//
// SPDX-License-Identifier: MPL-2.0
//
// The native text/code editing path of the workspace IDE. It keeps one
// buffer per open file (multi-file tabs), tracks dirty state against the
// exact baseline the buffer was loaded from, and saves only through the
// existing guarded `WorkspaceFileService`: an atomic commit with
// `expectedMtime`/`expectedSHA256`, a three-way review on conflict, and the
// shared 4 MiB read/write policy. There is no second workspace database and
// no direct file write here — this model is an editor/session adapter over
// the services the Web workbench and the inspector already use.
//
// Everything in this file is Foundation/Observation only so the model can be
// exercised by SwiftPM tests without an App or simulator.

import Foundation
import Observation

/// Why a path may not use the native editor by default.
public enum IDENativeTextFallbackReason: Equatable, Sendable {
    /// The typed router owns the path with a non-text surface.
    case nonTextKind(WorkspaceFileKind)
    /// The bytes are not UTF-8 text (NUL byte or invalid UTF-8).
    case binaryContent
    /// The file exceeds the shared 4 MiB text policy.
    case exceedsNativeLimit(Int)
}

/// Which surface the IDE should default to for one path.
public enum IDENativeTextSurface: Equatable, Sendable {
    case native
    case webFallback(IDENativeTextFallbackReason)
}

/// Explicit user choice of editing kernel. Both kernels keep their buffers
/// mounted for the IDE lifetime, so switching never drops unsaved text.
public enum IDENativeTextSurfaceMode: String, Equatable, Sendable {
    case native
    case web

    public var opposite: IDENativeTextSurfaceMode { self == .native ? .web : .native }
}

/// Result of asking to switch kernels. Dirty buffers are *retained* by a
/// switch (never flushed or discarded implicitly); the caller uses this to
/// warn about the divergence before it happens.
public struct IDENativeTextSurfaceSwitch: Equatable, Sendable {
    public let to: IDENativeTextSurfaceMode
    public let retainedDirtyPaths: [String]
    public let webHasUnsavedChanges: Bool

    public init(to: IDENativeTextSurfaceMode, retainedDirtyPaths: [String], webHasUnsavedChanges: Bool) {
        self.to = to
        self.retainedDirtyPaths = retainedDirtyPaths
        self.webHasUnsavedChanges = webHasUnsavedChanges
    }

    public var requiresConfirmation: Bool {
        !retainedDirtyPaths.isEmpty || webHasUnsavedChanges
    }
}

public enum IDENativeTextPolicy {
    /// The native editor shares the workspace text policy limit instead of
    /// inventing a second threshold: the Web bridge refuses the same bytes.
    public static let maximumBytes = IDEWorkspaceSession.maximumFileBytes

    /// Default surface for a path, decided from the typed file classifier
    /// alone. Unknown extensions are verified by content when the buffer
    /// loads; a binary load failure falls back to the Web workbench.
    public static func defaultSurface(forPath relativePath: String) -> IDENativeTextSurface {
        let kind = WorkspaceTextPolicy.kind(forPath: relativePath)
        switch kind {
        case .text, .code, .unknown:
            return .native
        case .office, .pdf, .cad, .image, .media, .archive, .binary:
            return .webFallback(.nonTextKind(kind))
        }
    }

    public static func supportsNativeEditing(_ relativePath: String) -> Bool {
        defaultSurface(forPath: relativePath) == .native
    }
}

/// Close policy for one native buffer. Pure so focused tests can pin the
/// save/discard/cancel decision without a UI.
public enum IDENativeTextCloseDecision: Equatable, Sendable {
    case closeImmediately
    case askUser

    /// - Parameters:
    ///   - isDirty: buffer text differs from its saved baseline.
    ///   - isSaving: a save is in flight; closing under it is never safe.
    public static func decide(isDirty: Bool, isSaving: Bool) -> IDENativeTextCloseDecision {
        if isSaving { return .askUser }
        return isDirty ? .askUser : .closeImmediately
    }
}

/// Outcome of one save-all pass over the open buffers.
public struct IDENativeTextSaveReport: Equatable, Sendable {
    public var savedPaths: [String] = []
    public var failedPaths: [String] = []
    public var conflictPaths: [String] = []

    public init() {}

    /// True when every dirty buffer is now clean.
    public var isClean: Bool { failedPaths.isEmpty && conflictPaths.isEmpty }
    public var didSaveAnything: Bool { !savedPaths.isEmpty }
}

/// One open text file. Editing happens against `text`; `baselineText` is the
/// last content confirmed on disk, so `isDirty` is exact and every save is
/// reviewed against the mtime+sha256 it was loaded from.
@MainActor
@Observable
public final class IDENativeTextBuffer {
    public let relativePath: String
    public var text: String = ""
    public private(set) var baselineText: String = ""
    public private(set) var baseMtime: Double?
    public private(set) var baseSHA256: String?
    public private(set) var isLoaded = false
    public private(set) var loadError: String?
    /// Set when the load failure means "not a native editor document"; the
    /// IDE offers the Web workbench for those bytes instead of a decode error.
    public private(set) var fallbackReason: IDENativeTextFallbackReason?
    public var saveError: String?
    public var conflict: WorkspaceEditConflict?
    public private(set) var isSaving = false

    public init(relativePath: String) {
        self.relativePath = relativePath
    }

    public var title: String { (relativePath as NSString).lastPathComponent }
    public var isDirty: Bool { text != baselineText }

    /// Loads the file through the same conflict-snapshot path as the
    /// inspector editor: the returned text, mtime and sha256 are internally
    /// consistent (a file that changes mid-read fails the digest check).
    public func load(service: WorkspaceFileService?) {
        guard !isLoaded else { return }
        guard let service else {
            loadError = IDENativeTextText.t("工作区不可用", "The workspace is unavailable")
            return
        }
        do {
            let snapshot = try service.editConflict(path: relativePath, base: nil, draft: "")
            text = snapshot.current
            baselineText = snapshot.current
            baseMtime = snapshot.currentMtime
            baseSHA256 = snapshot.currentSHA256
            loadError = nil
            fallbackReason = nil
            isLoaded = true
        } catch {
            applyLoadFailure(error)
        }
    }

    private func applyLoadFailure(_ error: Error) {
        isLoaded = false
        if let workspaceError = error as? WorkspaceToolError {
            switch workspaceError {
            case .tooLarge(let limit):
                fallbackReason = .exceedsNativeLimit(limit)
            case .invalidArguments(let reason) where reason.contains("not editable text"):
                fallbackReason = .binaryContent
            default:
                fallbackReason = nil
            }
            loadError = workspaceError.errorDescription ?? workspaceError.localizedDescription
        } else {
            fallbackReason = nil
            loadError = error.localizedDescription
        }
    }

    /// Saves the buffer with optimistic concurrency. A conflict creates the
    /// review model instead of writing; every other failure leaves the dirty
    /// text in place and reports through `saveError`.
    @discardableResult
    public func save(service: WorkspaceFileService?) async -> Bool {
        guard isLoaded else {
            saveError = loadError ?? IDENativeTextText.t("文件尚未加载", "The file is not loaded")
            return false
        }
        guard isDirty else { return true }
        guard let service else {
            saveError = IDENativeTextText.t("工作区不可用", "The workspace is unavailable")
            return false
        }
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let outcome = try service.writeFile(
                relativePath, content: text,
                expectedMtime: baseMtime,
                expectedSHA256: baseSHA256
            )
            baselineText = text
            baseMtime = outcome.mtime
            baseSHA256 = outcome.sha256
            saveError = nil
            conflict = nil
            return true
        } catch let error as WorkspaceToolError {
            if case .conflict = error {
                do {
                    conflict = try service.editConflict(
                        path: relativePath, base: baselineText, draft: text, preserveDraft: true
                    )
                } catch {
                    saveError = error.localizedDescription
                }
            } else {
                saveError = error.errorDescription ?? error.localizedDescription
            }
            return false
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    /// Applies a reviewed resolution with the reviewed version's own
    /// mtime+sha256. A newer edit re-opens the review rather than forcing the
    /// old resolution onto disk.
    @discardableResult
    public func resolve(_ review: WorkspaceEditConflict, content: String, service: WorkspaceFileService?) async -> Bool {
        guard let service else { return false }
        text = content
        isSaving = true
        defer { isSaving = false }
        do {
            let outcome = try service.resolveConflict(review, content: content)
            baselineText = content
            baseMtime = outcome.mtime
            baseSHA256 = outcome.sha256
            conflict = nil
            saveError = nil
            return true
        } catch let error as WorkspaceToolError {
            if case .conflict = error {
                do {
                    conflict = try service.editConflict(
                        path: relativePath, base: review.current, draft: content, preserveDraft: true
                    )
                } catch {
                    saveError = error.localizedDescription
                }
            } else {
                saveError = error.errorDescription ?? error.localizedDescription
            }
            return false
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}

/// The IDE's set of open native buffers. Buffers stay alive for the IDE
/// lifetime (also while the Web kernel is showing), so switching kernels or
/// switching tabs never loses text.
@MainActor
@Observable
public final class IDENativeTextWorkspace {
    public private(set) var buffers: [IDENativeTextBuffer] = []
    public private(set) var activePath: String?
    public let maximumOpenBuffers: Int
    private let service: WorkspaceFileService?

    public init(files: WorkspaceFileService?, maximumOpenBuffers: Int = 12) {
        self.service = files
        self.maximumOpenBuffers = maximumOpenBuffers
    }

    public var activeBuffer: IDENativeTextBuffer? {
        guard let activePath else { return nil }
        return buffers.first { $0.relativePath == activePath }
    }

    public var openPaths: [String] { buffers.map(\.relativePath) }
    public var hasDirty: Bool { buffers.contains { $0.isDirty } }

    /// Dirty paths in tab order.
    public var dirtyPaths: [String] { buffers.filter(\.isDirty).map(\.relativePath) }

    public func buffer(_ relativePath: String) -> IDENativeTextBuffer? {
        buffers.first { $0.relativePath == relativePath }
    }

    /// Opens (or re-activates) a buffer and loads it on first open. Refuses
    /// to exceed the open-buffer budget: the oldest *clean* buffer is evicted,
    /// never a dirty one.
    @discardableResult
    public func open(_ relativePath: String) async -> IDENativeTextBuffer? {
        guard !relativePath.isEmpty, relativePath != "." else { return nil }
        if let existing = buffer(relativePath) {
            activePath = relativePath
            return existing
        }
        if buffers.count >= maximumOpenBuffers {
            guard let index = buffers.firstIndex(where: { !$0.isDirty }) else { return nil }
            buffers.remove(at: index)
        }
        let created = IDENativeTextBuffer(relativePath: relativePath)
        buffers.append(created)
        activePath = relativePath
        created.load(service: service)
        return created
    }

    public func activate(_ relativePath: String) {
        guard buffer(relativePath) != nil else { return }
        activePath = relativePath
    }

    public func closeDecision(for relativePath: String) -> IDENativeTextCloseDecision {
        guard let buffer = buffer(relativePath) else { return .closeImmediately }
        return IDENativeTextCloseDecision.decide(isDirty: buffer.isDirty, isSaving: buffer.isSaving)
    }

    /// Closes a buffer. A dirty buffer is only closed when `force` is set —
    /// callers ask the user through `closeDecision(for:)` first.
    @discardableResult
    public func close(_ relativePath: String, force: Bool = false) -> Bool {
        guard let index = buffers.firstIndex(where: { $0.relativePath == relativePath }) else { return true }
        guard force || !buffers[index].isDirty else { return false }
        buffers.remove(at: index)
        if activePath == relativePath {
            activePath = buffers.indices.contains(index) ? buffers[index].relativePath : buffers.last?.relativePath
        }
        return true
    }

    /// Saves one buffer (a tab close offers save before the buffer is
    /// released). Returns true when that buffer is clean afterwards.
    @discardableResult
    public func save(_ relativePath: String) async -> Bool {
        guard let buffer = buffer(relativePath) else { return false }
        return await buffer.save(service: service)
    }

    /// Saves every dirty buffer in tab order. Never clears a save error and
    /// never writes through a conflict review.
    public func saveAll() async -> IDENativeTextSaveReport {
        var report = IDENativeTextSaveReport()
        for buffer in buffers where buffer.isDirty {
            if await buffer.save(service: service) {
                report.savedPaths.append(buffer.relativePath)
            } else if buffer.conflict != nil {
                report.conflictPaths.append(buffer.relativePath)
            } else {
                report.failedPaths.append(buffer.relativePath)
            }
        }
        return report
    }

    @discardableResult
    public func resolveConflict(path: String, content: String) async -> Bool {
        guard let buffer = buffer(path), let review = buffer.conflict else { return false }
        return await buffer.resolve(review, content: content, service: service)
    }

    /// The first buffer with an unresolved conflict, in tab order.
    public func pendingConflict() -> (path: String, conflict: WorkspaceEditConflict)? {
        for buffer in buffers {
            if let conflict = buffer.conflict { return (buffer.relativePath, conflict) }
        }
        return nil
    }

    /// Plan a kernel switch. Both kernels keep their buffers, so this only
    /// reports what would be left unsaved where the other kernel cannot see
    /// it; the caller confirms before applying.
    public func planSurfaceSwitch(
        to mode: IDENativeTextSurfaceMode,
        webHasUnsavedChanges: Bool
    ) -> IDENativeTextSurfaceSwitch {
        IDENativeTextSurfaceSwitch(
            to: mode,
            retainedDirtyPaths: mode == .web ? dirtyPaths : [],
            webHasUnsavedChanges: webHasUnsavedChanges
        )
    }
}

/// Bilingual strings for the Foundation-only model layer, where the App's
/// `IDELanguageRunText` helper is not available. Keep both languages together
/// so no user-facing text is ever added in one language only.
enum IDENativeTextText {
    static func t(_ zh: String, _ en: String) -> String {
        Locale.current.identifier.hasPrefix("zh") ? zh : en
    }
}
