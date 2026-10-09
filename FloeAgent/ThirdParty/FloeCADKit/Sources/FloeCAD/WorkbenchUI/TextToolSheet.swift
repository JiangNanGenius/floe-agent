//
//  TextToolSheet.swift
//  openshape3d
//
//  Text tool dialog (plan §B7, spec §1.12 v1): content, height, font.
//  Commit turns the string into glyph-outline sketch entities anchored at
//  the tapped placement point (EditorViewModel.commitText).
//

import SwiftUI

struct TextToolSheet: View {
    @State private var content = ""
    @State private var heightMM = 10.0
    @State private var fontName = "Helvetica"

    @Environment(\.dismiss) private var dismiss
    let onCommit: (String, Double, String) -> Void

    /// Families every iOS device ships with; the full installed-font list is
    /// a later polish pass.
    private static let fontNames = [
        "Helvetica", "Helvetica Neue", "Avenir Next", "Courier New",
        "Georgia", "Times New Roman", "Verdana",
    ]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Text", text: $content)
                    .accessibilityIdentifier("TextContentField")
                LabeledContent("Height (mm)") {
                    TextField("Height", value: $heightMM, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("TextHeightField")
                }
                Picker("Font", selection: $fontName) {
                    ForEach(Self.fontNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .accessibilityIdentifier("TextFontPicker")
            }
            .navigationTitle("Text")
            .onDisappear { MacWindowTitle.restore() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("TextCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onCommit(content, heightMM, fontName)
                        dismiss()
                    }
                    .disabled(
                        content.trimmingCharacters(in: .whitespaces).isEmpty || heightMM <= 0
                    )
                    .accessibilityIdentifier("TextAdd")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
