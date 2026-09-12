//
//  SystemColorSwatchPicker.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 30.03.2026.
//

import SwiftUI

struct SystemColorSwatchPicker: View {

    // MARK: - Bindings

    @Binding private var selectedColor: Color

    // MARK: - Public Properties

    let title: String
    let options: [SystemColorOption]

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(options) { option in
                        swatchButton(option)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Initializer

    init(
        _ selectedColor: Binding<Color>,
        title: String,
        options: [SystemColorOption]
    ) {
        _selectedColor = selectedColor

        self.title = title
        self.options = options
    }

    // MARK: - Private Methods

    private func swatchButton(_ option: SystemColorOption) -> some View {
        Button {
            selectedColor = option.color
        } label: {
            Circle()
                .fill(option.color)
                .overlay {
                    Circle()
                        .strokeBorder(borderColor(for: option), lineWidth: borderWidth(for: option))
                }
                .overlay {
                    if isSelected(option) {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(checkmarkColor(for: option))
                    }
                }
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.id)
        .accessibilityValue(
            isSelected(option)
                ? VideoEditorStrings.selected
                : VideoEditorStrings.notSelected
        )
    }

    private func isSelected(_ option: SystemColorOption) -> Bool {
        SystemColorPalette.matches(selectedColor, option.color)
    }

    private func borderColor(for option: SystemColorOption) -> Color {
        if isSelected(option) {
            return Theme.accent
        }

        return Color.primary.opacity(0.14)
    }

    private func borderWidth(for option: SystemColorOption) -> CGFloat {
        isSelected(option) ? 3 : 1
    }

    private func checkmarkColor(for option: SystemColorOption) -> Color {
        option.checkmarkColor
    }

}

#Preview {
    @Previewable @State var color: Color = .blue
    SystemColorSwatchPicker(
        $color,
        title: "Background",
        options: SystemColorPalette.textBackgrounds
    )
    .padding()
}
