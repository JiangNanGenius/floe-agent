//
//  CommandSearchView.swift
//  openshape3d
//
//  Spec §8.4 — the Command Search launcher. `CommandRegistry` has carried the
//  fuzzy matcher and the recents list since the hotkey pass; this is the view
//  that finally opens it.
//
//  Two decisions worth knowing:
//
//  * **It only lists commands that can actually run.** The catalog is wider
//    than `runCommand`'s routing table on purpose — it also names commands
//    whose editor entry points do not exist yet. Offering those would be the
//    same silent failure as a dead hotkey, and worse, because the user just
//    read the name off a list. See `CommandRegistry.launchableCommands`.
//  * **A result that is real but not applicable right now keeps the panel
//    open** and says why. Closing on a keystroke that did nothing is the
//    behaviour that makes a launcher feel broken.
//
//  It is an OVERLAY, not a sheet: `EditorView` already stacks ~20 presentation
//  modifiers, two of them cannot be up at once, and the launcher has to be
//  openable from anywhere — including while a sheet is showing.
//

import SwiftUI

struct CommandSearchView: View {
    @Bindable var viewModel: EditorViewModel

    @State private var query = ""
    @State private var highlighted = 0
    /// Set when a chosen command refused (wrong mode, nothing selected).
    @State private var refusal: String?
    @FocusState private var focused: Bool

    private var results: [AppCommand] { viewModel.commandSearchResults(for: query) }

    var body: some View {
        ZStack(alignment: .top) {
            // Tap-out to dismiss, and a scrim so the panel reads as modal
            // even though it is an overlay.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { viewModel.closeCommandSearch() }
                .accessibilityIdentifier("CommandSearchScrim")

            panel
                .frame(maxWidth: 460)
                .padding(.top, 90)
        }
        .transition(.opacity)
        .onAppear {
            query = viewModel.commandSearchSeed
            focused = true
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            field
            if let refusal {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("CommandSearchRefusal")
            }
            Divider()
            resultList
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        // `.contain` FIRST: an identifier on a container otherwise collapses it
        // into one a11y element and swallows every child's — the field came
        // back as `textFields["CommandSearchPanel"]` and `CommandSearchField`
        // did not exist at all (gotcha 2, third time in this codebase).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CommandSearchPanel")
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.barLabel)
            TextField("Search commands", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .onKeyPress(.escape) {
                    viewModel.closeCommandSearch()
                    return .handled
                }
                .submitLabel(.go)
                .onSubmit { run(highlightedCommand) }
                .onChange(of: query) { _, _ in
                    highlighted = 0
                    refusal = nil
                }
                .accessibilityIdentifier("CommandSearchField")
            Button {
                viewModel.closeCommandSearch()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("CommandSearchClose")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var resultList: some View {
        let rows = results
        if rows.isEmpty {
            Text(query.isEmpty
                 ? "Type to search, or pick a recent command."
                 : "No command matches “\(query)”.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .accessibilityIdentifier("CommandSearchEmpty")
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, command in
                        row(command, isHighlighted: index == highlighted)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private func row(_ command: AppCommand, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Text(command.title)
                .font(.callout)
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            Text(command.category.rawValue.capitalized)
                .font(.caption2)
                .foregroundStyle(.barLabel)
            if let chord = command.chord {
                Text(chord.label)
                    .font(.caption.monospaced())
                    .foregroundStyle(.barLabel)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isHighlighted ? Color.accentColor.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { run(command) }
        // Leaf identifier only — an id on this HStack would collapse it into
        // one a11y element (gotcha 2).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CommandResult-\(command.title)")
    }

    private var highlightedCommand: AppCommand? {
        let rows = results
        guard rows.indices.contains(highlighted) else { return rows.first }
        return rows[highlighted]
    }

    private func run(_ command: AppCommand?) {
        guard let command else { return }
        if !viewModel.runCommandFromSearch(command.id) {
            refusal = "“\(command.title)” isn't available right now."
        }
    }
}
