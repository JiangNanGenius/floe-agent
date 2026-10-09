//
//  CommandRegistry.swift
//  openshape3d
//
//  Spec §8.4 — hotkeys and Command Search. One catalog of named commands, each
//  with an optional key chord, feeding both: the hardware-keyboard path looks a
//  chord up, the launcher fuzzy-matches a query against the same titles.
//
//  Keeping them in one place is what makes the spec's "Single Key Action"
//  setting possible at all: a bare letter is EITHER a hotkey or the first
//  character typed into Command Search, and both readings have to resolve
//  against the same list.
//

import Foundation

// MARK: - Key chords

nonisolated struct KeyChord: Hashable, Codable, Sendable {
    nonisolated struct Modifiers: OptionSet, Hashable, Codable, Sendable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
    }

    /// Lowercased character, or a name like "space" / "up" / "left".
    var key: String
    var modifiers: Modifiers

    init(_ key: String, _ modifiers: Modifiers = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// Menu-style label, e.g. "⇧⌘I".
    var label: String {
        var out = ""
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        return out + (key.count == 1 ? key.uppercased() : key.capitalized)
    }

    /// A chord with no modifiers — the "Single Key Action" setting decides
    /// whether these fire a command or open Command Search.
    var isBareKey: Bool { modifiers.isEmpty && key.count == 1 }
}

// MARK: - Commands

nonisolated struct AppCommand: Identifiable, Hashable, Sendable {
    nonisolated enum Category: String, Sendable, CaseIterable {
        case sketch, modeling, boolean, transform, view, edit, project
    }

    let id: String
    var title: String
    var category: Category
    var chord: KeyChord?
}

/// What a bare letter does (spec's Settings > Single Key Action).
nonisolated enum SingleKeyAction: String, Codable, Sendable, CaseIterable {
    case hotkeys, commandSearch
}

// MARK: - Registry

nonisolated struct CommandRegistry: Sendable {

    /// Most-recent-first, capped; Command Search shows these on an empty query.
    private(set) var recentIDs: [String] = []
    var singleKeyAction: SingleKeyAction = .hotkeys

    static let recentsLimit = 8

    init(singleKeyAction: SingleKeyAction = .hotkeys) {
        self.singleKeyAction = singleKeyAction
    }

    // MARK: Lookup

    /// The command a chord fires, honouring Single Key Action: with the setting
    /// on Command Search a bare letter is a keystroke for the launcher, not a
    /// hotkey, so nothing is dispatched.
    func command(for chord: KeyChord) -> AppCommand? {
        if chord.isBareKey, singleKeyAction == .commandSearch { return nil }
        return Self.all.first { $0.chord == chord }
    }

    func command(id: String) -> AppCommand? { Self.all.first { $0.id == id } }

    mutating func markUsed(_ id: String) {
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
        if recentIDs.count > Self.recentsLimit { recentIDs.removeLast() }
    }

    // MARK: Command Search

    /// Fuzzy launcher results, best first.
    ///
    /// An empty query returns recents (spec), so the launcher is useful before
    /// the user types. `scope` narrows to a category when a selection implies
    /// one — the spec's "pre-selection scopes results".
    func search(
        _ query: String, scope: AppCommand.Category? = nil,
        in catalog: [AppCommand] = CommandRegistry.all
    ) -> [AppCommand] {
        let pool = scope.map { s in catalog.filter { $0.category == s } } ?? catalog
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return recentIDs.compactMap { id in pool.first { $0.id == id } }
        }
        return pool
            .compactMap { command in
                Self.score(query: trimmed, title: command.title).map { (command, $0) }
            }
            // Ties break on the shorter title: the more specific match of two
            // equally-scoring commands is the one with less unmatched text.
            .sorted {
                $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title.count < $1.0.title.count
            }
            .map(\.0)
    }

    /// Subsequence match with a bias toward WORD STARTS, which is what makes
    /// the spec's examples work: "p3" finds "Add Plane - 3 Points" and "snu"
    /// finds "Scale - Non-uniform" even though neither is a prefix. Nil when
    /// the query is not a subsequence of the title at all.
    static func score(query: String, title: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        let hay = Array(title.lowercased())
        guard !needle.isEmpty else { return nil }

        var total = 0, n = 0, previousMatch = -2
        for (i, character) in hay.enumerated() {
            guard n < needle.count, character == needle[n] else { continue }
            let atWordStart = i == 0 || !hay[i - 1].isLetter && !hay[i - 1].isNumber
            var points = 1
            if atWordStart { points += 8 }
            if i == previousMatch + 1 { points += 4 }   // consecutive run
            if i == 0 { points += 4 }                   // matches the very start
            total += points
            previousMatch = i
            n += 1
        }
        guard n == needle.count else { return nil }
        return total
    }

    // MARK: - The catalog

    /// Titles are the search corpus, so they read as the user would say them.
    static let all: [AppCommand] = [
        // Sketch (spec §8.4: A/C/G/I/L/O/R/T)
        AppCommand(id: "sketch.arc", title: "Arc", category: .sketch, chord: KeyChord("a")),
        AppCommand(id: "sketch.circle", title: "Circle", category: .sketch, chord: KeyChord("c")),
        AppCommand(id: "sketch.polygon", title: "Polygon", category: .sketch, chord: KeyChord("g")),
        /// Shapr3D: Space with the pointer over a plane or face starts a sketch
        /// there (observed live 2026-09-13 on the grid and on a box face).
        AppCommand(id: "sketch.onHoveredPlane", title: "Sketch on Hovered Plane", category: .sketch,
                   chord: KeyChord("space")),
        AppCommand(id: "sketch.image", title: "Insert Image", category: .sketch, chord: KeyChord("i")),
        AppCommand(id: "sketch.line", title: "Line", category: .sketch, chord: KeyChord("l")),
        AppCommand(id: "sketch.offset", title: "Offset", category: .sketch, chord: KeyChord("o")),
        AppCommand(id: "sketch.rectangle", title: "Rectangle", category: .sketch, chord: KeyChord("r")),
        AppCommand(id: "sketch.text", title: "Text", category: .sketch, chord: KeyChord("t")),
        AppCommand(id: "sketch.ellipse", title: "Ellipse", category: .sketch, chord: nil),
        AppCommand(id: "sketch.spline", title: "Spline", category: .sketch, chord: nil),
        AppCommand(id: "sketch.trim", title: "Trim", category: .sketch, chord: nil),
        AppCommand(id: "sketch.mirror", title: "Mirror", category: .sketch, chord: nil),
        AppCommand(id: "sketch.construction", title: "Make Construction", category: .sketch, chord: nil),

        // Modeling (E/F/H/M/N/P/S/V/W)
        AppCommand(id: "model.extrude", title: "Extrude", category: .modeling, chord: KeyChord("e")),
        AppCommand(id: "model.fillet", title: "Fillet", category: .modeling, chord: KeyChord("f")),
        AppCommand(id: "model.shell", title: "Shell", category: .modeling, chord: KeyChord("h")),
        AppCommand(id: "model.move", title: "Move / Rotate", category: .transform, chord: KeyChord("m")),
        AppCommand(id: "model.chamfer", title: "Chamfer", category: .modeling, chord: KeyChord("n")),
        AppCommand(id: "model.project", title: "Project", category: .modeling, chord: KeyChord("p")),
        AppCommand(id: "model.sweep", title: "Sweep", category: .modeling, chord: KeyChord("s")),
        AppCommand(id: "model.revolve", title: "Revolve", category: .modeling, chord: KeyChord("v")),
        AppCommand(id: "model.loft", title: "Loft", category: .modeling, chord: KeyChord("w")),
        AppCommand(id: "model.deleteFace", title: "Delete Face", category: .modeling, chord: nil),
        AppCommand(id: "model.replaceFace", title: "Replace Face", category: .modeling, chord: nil),
        AppCommand(id: "model.offsetFace", title: "Offset Face", category: .modeling, chord: nil),
        AppCommand(id: "model.offsetEdge", title: "Offset Edge", category: .modeling, chord: nil),
        AppCommand(id: "model.wrap", title: "Wrap - Emboss", category: .modeling, chord: nil),
        AppCommand(id: "model.split", title: "Split Body", category: .modeling, chord: nil),

        // Booleans (Cmd+U/B/I)
        AppCommand(id: "bool.union", title: "Union", category: .boolean,
                   chord: KeyChord("u", .command)),
        AppCommand(id: "bool.subtract", title: "Subtract", category: .boolean,
                   chord: KeyChord("b", .command)),
        AppCommand(id: "bool.intersect", title: "Intersect", category: .boolean,
                   chord: KeyChord("i", .command)),

        // Transform
        AppCommand(id: "transform.scaleUniform", title: "Scale - Uniform", category: .transform, chord: nil),
        AppCommand(id: "transform.scaleNonUniform", title: "Scale - Non-uniform",
                   category: .transform, chord: nil),
        AppCommand(id: "transform.mirror", title: "Mirror Bodies", category: .transform, chord: nil),
        AppCommand(id: "transform.pattern", title: "Pattern", category: .transform, chord: nil),

        // Construction geometry — the spec's "p3" example lives here.
        AppCommand(id: "plane.offset", title: "Add Plane - Offset", category: .modeling, chord: nil),
        AppCommand(id: "plane.threePoints", title: "Add Plane - 3 Points", category: .modeling, chord: nil),
        AppCommand(id: "plane.angle", title: "Add Plane - Angle", category: .modeling, chord: nil),
        AppCommand(id: "axis.twoPoints", title: "Add Axis - 2 Points", category: .modeling, chord: nil),

        // Edit
        AppCommand(id: "edit.undo", title: "Undo", category: .edit, chord: KeyChord("z", .command)),
        AppCommand(id: "edit.redo", title: "Redo", category: .edit, chord: KeyChord("z", [.command, .shift])),
        AppCommand(id: "edit.selectAll", title: "Select All", category: .edit, chord: KeyChord("a", .command)),
        AppCommand(id: "edit.delete", title: "Delete", category: .edit, chord: nil),

        // View (Cmd+1…7, plus Space)
        AppCommand(id: "view.front", title: "View - Front", category: .view, chord: KeyChord("1", .command)),
        AppCommand(id: "view.back", title: "View - Back", category: .view, chord: KeyChord("2", .command)),
        AppCommand(id: "view.left", title: "View - Left", category: .view, chord: KeyChord("3", .command)),
        AppCommand(id: "view.right", title: "View - Right", category: .view, chord: KeyChord("4", .command)),
        AppCommand(id: "view.top", title: "View - Top", category: .view, chord: KeyChord("5", .command)),
        AppCommand(id: "view.bottom", title: "View - Bottom", category: .view, chord: KeyChord("6", .command)),
        AppCommand(id: "view.isometric", title: "View - Isometric", category: .view, chord: KeyChord("7", .command)),
        /// No chord: Space is Sketch on Hovered Plane (what the reference app
        /// does with it — the earlier "hover + Space zooms" reading was wrong).
        AppCommand(id: "view.zoomToSelection", title: "Zoom to Selection", category: .view,
                   chord: nil),
        AppCommand(id: "view.fit", title: "Zoom to Fit", category: .view, chord: nil),

        // Command Search itself (X or Cmd+F).
        AppCommand(id: "app.commandSearch", title: "Command Search", category: .edit,
                   chord: KeyChord("x")),
        AppCommand(id: "app.commandSearchAlt", title: "Command Search (Find)", category: .edit,
                   chord: KeyChord("f", .command)),

        // Dashboard / project. The spec calls out that importing INTO the
        // current project and importing AS a new one are distinct commands.
        AppCommand(id: "project.new", title: "New Project", category: .project,
                   chord: KeyChord("n", .command)),
        AppCommand(id: "project.importIntoCurrent", title: "Import into Current Project",
                   category: .project, chord: KeyChord("i", [.command, .shift])),
        AppCommand(id: "project.importAsNew", title: "Import as New Project",
                   category: .project, chord: KeyChord("i", [.command, .option])),
        AppCommand(id: "project.insertProject", title: "Insert Project", category: .project, chord: nil),
        AppCommand(id: "project.export", title: "Export", category: .project, chord: nil),
        AppCommand(id: "project.duplicate", title: "Duplicate Project", category: .project, chord: nil),
        AppCommand(id: "project.rename", title: "Rename Project", category: .project, chord: nil),
    ]

    /// Every command that has a chord, for the cheat sheet (long-press ⌘).
    static var cheatSheet: [AppCommand.Category: [AppCommand]] {
        Dictionary(grouping: all.filter { $0.chord != nil }, by: \.category)
    }
}
