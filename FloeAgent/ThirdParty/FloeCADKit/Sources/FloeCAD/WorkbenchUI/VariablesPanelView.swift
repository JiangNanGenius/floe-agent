//
//  VariablesPanelView.swift
//  openshape3d
//
//  Variables panel (Phase D, Task B3): a floating sidebar listing the
//  document's parametric variables in creation order, each with an editable
//  name and expression, its resolved value, a delete button, and an error
//  badge when the expression can't resolve. A footer button appends a new
//  variable. Mirrors the structure and style of HistoryPanelView; consumes
//  the B2 VM panel API (variableRows / addVariable / setVariable /
//  deleteVariable).
//

import SwiftUI

struct VariablesPanelView: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader("Variables")
                if viewModel.variableRows.isEmpty {
                    emptyRow("No variables yet")
                }
                ForEach(viewModel.variableRows) { row in
                    VariableRowView(
                        row: row,
                        onCommit: { name, expression in
                            viewModel.setVariable(row.id, name: name, expression: expression)
                        },
                        onDelete: { viewModel.deleteVariable(row.id) }
                    )
                }
                Button(action: viewModel.addVariable) {
                    Label("Add Variable", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.top, 8)
                .padding(.horizontal, 8)
                .accessibilityIdentifier("AddVariableButton")
            }
            .padding(12)
        }
        .frame(width: 290)
        .frame(maxHeight: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .accessibilityIdentifier("VariablesPanel")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.barLabel)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.barLabelDim)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
    }
}

/// One variable row: an editable name field + "=" + an editable expression
/// field, the evaluated value ("= 40"), an error badge (with the resolver
/// message) when the expression can't resolve, and a delete button. Editing
/// either field commits both current drafts through `onCommit`.
private struct VariableRowView: View {
    let row: EditorViewModel.VariableRow
    let onCommit: (_ name: String, _ expression: String) -> Void
    let onDelete: () -> Void

    @State private var nameDraft = ""
    @State private var exprDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("name", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(width: 72, alignment: .leading)
                    .onSubmit(commit)
                    .accessibilityIdentifier("VariableNameField-\(row.name)")
                Text("=")
                    .font(.caption)
                    .foregroundStyle(.barLabel)
                TextField("expression", text: $exprDraft)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.done)
                    .onSubmit(commit)
                    .accessibilityIdentifier("VariableExprField-\(row.name)")
                Spacer(minLength: 4)
                if row.hasError {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                        .help(row.errorText ?? "Error")
                        .accessibilityIdentifier("VariableError-\(row.name)")
                }
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.barLabel)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("VariableDelete-\(row.name)")
            }

            HStack(spacing: 6) {
                Text("= \(Self.fmt(row.value))")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(row.hasError ? Color.orange : Color.barLabel)
                    .accessibilityIdentifier("VariableValue-\(row.name)")
                if row.hasError, let text = row.errorText {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("VariableRow-\(row.name)")
        .onAppear {
            nameDraft = row.name
            exprDraft = row.expression
        }
        .onChange(of: row.name) { _, updated in nameDraft = updated }
        .onChange(of: row.expression) { _, updated in exprDraft = updated }
    }

    private func commit() {
        onCommit(nameDraft, exprDraft)
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%g", (v * 1000).rounded() / 1000)
    }
}
