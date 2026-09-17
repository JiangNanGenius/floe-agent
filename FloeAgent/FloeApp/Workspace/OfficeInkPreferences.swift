// SPDX-License-Identifier: MPL-2.0
// Floe-owned, per-document stroke settings for the app-owned Office pen panel.
//
// These values never read or write Notes or Canvas/PencilKit state and never
// touch the pinned Collabora host. They are persisted under their own defaults
// key so that deleting a Notes/Canvas item cannot change Office ink and vice
// versa. OfficeExplicitSaveBridge converts them into the verified Collabora UNO
// argument encodings at dispatch time.
//
// Keep this file free of UIKit so the conversion logic stays type-checkable on
// a plain Swift toolchain; the SwiftUI panel observes it directly.
import Foundation
import SwiftUI
import Observation

/// Inline en/zh strings for the app-owned Office ink surface, mirroring the
/// `IDELanguageRunText` pattern used elsewhere in Workspace. The primary agent
/// may move these keys into `Localizable.xcstrings`.
enum OfficeInkText {
    static var isChinese: Bool { Locale.current.identifier.hasPrefix("zh") }
    static func t(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
}

enum OfficeInkColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case black, blue, red, green, yellow

    var id: String { rawValue }

    /// `#RRGGBB`; the only shape `OfficeInkStroke` validation accepts.
    var hex: String {
        switch self {
        case .black: "#000000"
        case .blue: "#0000FF"
        case .red: "#FF0000"
        case .green: "#00A650"
        case .yellow: "#FFCC00"
        }
    }

    var title: String {
        switch self {
        case .black: OfficeInkText.t("黑色", "Black")
        case .blue: OfficeInkText.t("蓝色", "Blue")
        case .red: OfficeInkText.t("红色", "Red")
        case .green: OfficeInkText.t("绿色", "Green")
        case .yellow: OfficeInkText.t("黄色", "Yellow")
        }
    }

    var swatch: Color { Color(officeHex: hex) }
}

enum OfficeInkWidthPreset: Double, CaseIterable, Identifiable, Sendable {
    case hairline = 0.5
    case standard = 1.5
    case bold = 3.0

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .hairline: OfficeInkText.t("细", "Hairline")
        case .standard: OfficeInkText.t("中", "Medium")
        case .bold: OfficeInkText.t("粗", "Bold")
        }
    }
}

/// One document's native freehand stroke configuration.
///
/// The stored values are user-facing (millimetres, transparency percent). The
/// `…Value` properties are the exact wire values in the shapes the verified
/// Collabora/LibreOffice slots expect; see `OfficeExplicitSaveBridge` for the
/// command encodings and their evidence.
struct OfficeInkStroke: Codable, Equatable, Sendable {
    static let widthRange: ClosedRange<Double> = 0.25...6.0
    static let defaultWidthMillimeters = OfficeInkWidthPreset.standard.rawValue

    var colorHex: String = OfficeInkColor.black.hex
    /// Display width in millimetres. `.uno:LineWidth` takes 1/100 mm.
    var widthMillimeters: Double = OfficeInkWidthPreset.standard.rawValue
    /// UNO line transparency in percent. `0` is fully opaque/solid.
    var transparencyPercent: Int = 0

    init(colorHex: String = OfficeInkColor.black.hex,
         widthMillimeters: Double = OfficeInkWidthPreset.standard.rawValue,
         transparencyPercent: Int = 0) {
        self.colorHex = OfficeInkPreferences.validHex(colorHex)
            ? colorHex.uppercased() : OfficeInkColor.black.hex
        self.widthMillimeters = Self.clampedWidth(widthMillimeters)
        self.transparencyPercent = max(0, min(100, transparencyPercent))
    }

    /// Persisted JSON is untrusted recovery data: a missing, non-finite or
    /// huge scalar must clamp to a valid stroke instead of trapping during an
    /// `Int` conversion. Values are decoded as `Double` so a corrupt file can
    /// never overflow the integer initializer.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let color = (try? container.decode(String.self, forKey: .colorHex)) ?? OfficeInkColor.black.hex
        let width = (try? container.decode(Double.self, forKey: .widthMillimeters))
            ?? Self.defaultWidthMillimeters
        let transparency = (try? container.decode(Double.self, forKey: .transparencyPercent)) ?? 0
        self.init(colorHex: color,
                  widthMillimeters: width,
                  transparencyPercent: Int(Self.clampedTransparency(transparency)))
    }

    private enum CodingKeys: String, CodingKey {
        case colorHex, widthMillimeters, transparencyPercent
    }

    /// Guards every consumer against non-finite or out-of-range persisted
    /// widths before any multiplication/`Int` conversion.
    static func clampedWidth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultWidthMillimeters }
        return min(widthRange.upperBound, max(widthRange.lowerBound, value))
    }

    static func clampedTransparency(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(0, value.rounded()))
    }

    /// `0xRRGGBB` long value for the shape line-color command.
    var colorValue: Int {
        guard let value = UInt32(colorHex.dropFirst(), radix: 16) else { return 0 }
        return Int(value & 0xFFFFFF)
    }

    /// `.uno:LineWidth` receives a `sal_Int32` metric value in 1/100 mm.
    /// Clamp before multiplying so a huge finite value cannot overflow.
    var lineWidthValue: Int {
        let clamped = Self.clampedWidth(widthMillimeters)
        return max(1, Int((clamped * 100).rounded()))
    }

    /// `.uno:LineTransparence` receives an unsigned-16 percent; 0 = solid.
    var transparencyValue: Int { max(0, min(100, transparencyPercent)) }
}

/// Explicit, stable logical identity for an Office document whose local
/// editing URL is a transient remote-preview copy (cloud workspace or network
/// mount). The workspace identity plus the workspace-relative path survive the
/// changing temporary copy directory; the physical preview URL therefore must
/// never be part of the key.
///
/// Only `FilePreviewView` builds this, and only for a remote file. Local Office
/// documents and Notes pass none and keep their physical-URL identity.
struct OfficeInkDocumentIdentity: Equatable, Sendable {
    let workspaceIdentity: String?
    let relativePath: String

    /// Bounded, privacy-safe persisted key. Same workspace + same relative
    /// path always folds to the same key; a same-named file in another
    /// workspace folds to a different key, and no raw path is persisted.
    var scopedKey: String {
        OfficeInkPreferences.scopedDocumentKey(workspaceIdentity: workspaceIdentity,
                                               documentKey: relativePath)
    }
}

/// Persists one stroke configuration per document key. Settings survive app
/// restarts but are intentionally independent from Notes and Canvas ink.
@MainActor @Observable final class OfficeInkPreferences {
    static let storageKey = "office.ink.preferences.v1"

    private struct Snapshot: Codable {
        var strokes: [String: OfficeInkStroke] = [:]
    }

    let documentKey: String
    private(set) var stroke: OfficeInkStroke
    @ObservationIgnored private let defaults: UserDefaults

    private init(documentKey: String, stroke: OfficeInkStroke, defaults: UserDefaults) {
        self.documentKey = documentKey
        self.stroke = stroke
        self.defaults = defaults
    }

    /// Bounded, path-free key. The caller passes a workspace-relative document
    /// identity so two same-named files in different folders stay separate and
    /// no absolute path is written to defaults.
    nonisolated static func normalizedDocumentKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(untitled)" }
        return String(trimmed.prefix(240))
    }

    /// Persistent identity for one document inside one workspace. The workspace
    /// identity and document path are folded through a stable digest so a
    /// same-named file in another workspace cannot share settings and no raw
    /// path or identifier is ever written to defaults.
    nonisolated static func scopedDocumentKey(workspaceIdentity: String?, documentKey: String) -> String {
        let trimmedWorkspace = (workspaceIdentity ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = trimmedWorkspace.isEmpty ? "unscoped-workspace" : trimmedWorkspace
        let document = normalizedDocumentKey(documentKey)
        return "doc-" + stableDigest(scope + "\u{1F}" + document)
    }

    /// Deterministic 64-bit FNV-1a digest, hex encoded. Used only to build a
    /// stable, bounded and privacy-safe preferences key (not a security hash).
    nonisolated static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Resolves the persisted preferences key for a session.
    ///
    /// `stableIdentity` is supplied only for a cloud/network file whose local
    /// editing URL is a transient preview copy (the copy directory changes on
    /// every load, so it can never be part of the key). When present it wins
    /// over the session URL. Local Office documents and Notes supply no remote
    /// identity and keep their stable physical-URL identity, so a transient
    /// workspace id can never rebind their settings. The fallback is used only
    /// before a session has opened a document.
    nonisolated static func resolvedDocumentKey(stableIdentity: OfficeInkDocumentIdentity?,
                                                originalURL: URL?,
                                                fallbackWorkspaceIdentity: String?,
                                                fallbackDocumentKey: String) -> String {
        if let stableIdentity { return stableIdentity.scopedKey }
        if let originalURL {
            return scopedDocumentKey(
                workspaceIdentity: originalURL.deletingLastPathComponent().standardizedFileURL.path,
                documentKey: originalURL.lastPathComponent)
        }
        return scopedDocumentKey(workspaceIdentity: fallbackWorkspaceIdentity,
                                 documentKey: fallbackDocumentKey)
    }

    static func session(forDocument documentKey: String,
                        defaults: UserDefaults = .standard) -> OfficeInkPreferences {
        let key = normalizedDocumentKey(documentKey)
        return OfficeInkPreferences(documentKey: key,
                                    stroke: load(from: defaults).strokes[key] ?? OfficeInkStroke(),
                                    defaults: defaults)
    }

    var color: OfficeInkColor? {
        OfficeInkColor.allCases.first { $0.hex.caseInsensitiveCompare(stroke.colorHex) == .orderedSame }
    }

    func setColor(_ color: OfficeInkColor) {
        setColorHex(color.hex)
    }

    func setColorHex(_ hex: String) {
        guard Self.validHex(hex) else { return }
        var updated = stroke
        updated.colorHex = hex.uppercased()
        update(updated)
    }

    func setWidthMillimeters(_ value: Double) {
        guard value.isFinite else { return }
        var updated = stroke
        updated.widthMillimeters = min(OfficeInkStroke.widthRange.upperBound,
                                       max(OfficeInkStroke.widthRange.lowerBound, value))
        update(updated)
    }

    func setTransparencyPercent(_ value: Int) {
        var updated = stroke
        updated.transparencyPercent = max(0, min(100, value))
        update(updated)
    }

    func reset() { update(OfficeInkStroke()) }

    private func update(_ updated: OfficeInkStroke) {
        guard updated != stroke else { return }
        stroke = updated
        var snapshot = Self.load(from: defaults)
        snapshot.strokes[documentKey] = updated
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private static func load(from defaults: UserDefaults) -> Snapshot {
        guard let data = defaults.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot()
        }
        return snapshot
    }

    nonisolated static func validHex(_ value: String) -> Bool {
        value.count == 7 && value.first == "#" && UInt32(value.dropFirst(), radix: 16) != nil
    }
}

/// Serializes and coalesces asynchronous ink dispatches. Only the newest
/// request may publish a result; a completion for a superseded generation, or
/// one arriving after `invalidate()`, is rejected so it cannot overwrite the
/// settings of a document that has since closed or switched.
///
/// Pure value logic on purpose: the owning `OfficeFileSession` runs the
/// dispatch loop, and this type stays unit-testable without UIKit/WebKit.
struct OfficeInkApplySequencer {
    private(set) var requested = 0
    private(set) var completed = 0
    private(set) var running = false
    private(set) var epoch = 0

    /// Records a new request. Returns true when the caller should start the
    /// drain loop; false means a loop is already running and will pick the
    /// latest request up on its next iteration.
    mutating func begin() -> Bool {
        requested += 1
        if running { return false }
        running = true
        return true
    }

    /// The newest generation still to run, or nil when the loop is drained.
    /// Always returns the latest `requested`, so superseded generations are
    /// skipped instead of dispatched.
    mutating func next(epoch expectedEpoch: Int? = nil) -> Int? {
        guard expectedEpoch == nil || expectedEpoch == epoch else { return nil }
        guard completed < requested else {
            running = false
            return nil
        }
        return requested
    }

    /// Marks a generation complete. Returns false when a newer request arrived
    /// while it was in flight, in which case its result must be discarded.
    mutating func complete(_ generation: Int, epoch expectedEpoch: Int? = nil) -> Bool {
        guard expectedEpoch == nil || expectedEpoch == epoch else { return false }
        guard generation >= requested else { return false }
        completed = generation
        return true
    }

    /// Drops any in-flight result and stops the loop (document close/switch).
    mutating func invalidate() {
        epoch += 1
        requested += 1
        completed = requested
        running = false
    }
}

extension Color {
    /// Builds a SwiftUI color from the `#RRGGBB` strings stored by
    /// `OfficeInkPreferences`. Invalid input falls back to black.
    init(officeHex hex: String) {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}
