//
//  VideoAdjustsToolView.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import SwiftUI

struct VideoAdjustsToolView: View {

    // MARK: - Public Properties

    let adjusts: ColorAdjusts
    private let onChangeAdjusts: (ColorAdjusts) -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: 16) {
            adjustSlider(
                title: ColorAdjustType.brightness.title,
                systemImage: "sun.max",
                value: binding(
                    for: \.brightness
                )
            )
            adjustSlider(
                title: ColorAdjustType.contrast.title,
                systemImage: "circle.lefthalf.filled",
                value: binding(
                    for: \.contrast
                )
            )
            adjustSlider(
                title: ColorAdjustType.saturation.title,
                systemImage: "drop",
                value: binding(
                    for: \.saturation
                )
            )
        }
        .safeAreaPadding()
    }

    // MARK: - Initializer

    init(
        adjusts: ColorAdjusts,
        onChangeAdjusts: @escaping (ColorAdjusts) -> Void
    ) {
        self.adjusts = adjusts
        self.onChangeAdjusts = onChangeAdjusts
    }

}

extension VideoAdjustsToolView {

    // MARK: - Private Properties

    private func binding(
        for keyPath: WritableKeyPath<ColorAdjusts, Double>
    ) -> Binding<Double> {
        Binding(
            get: { adjusts[keyPath: keyPath] },
            set: { newValue in
                var updatedAdjusts = adjusts
                updatedAdjusts[keyPath: keyPath] = newValue
                onChangeAdjusts(updatedAdjusts)
            }
        )
    }

    // MARK: - Private Methods

    fileprivate func adjustSlider(
        title: String,
        systemImage: String,
        value: Binding<Double>
    ) -> some View {
        HStack {
            Image(systemName: systemImage)
                .accessibilityLabel(title)
            Slider(value: value, in: -1...1)
                .tint(Theme.accent)
            Text(value.wrappedValue, format: .number.precision(.fractionLength(1)))
                .monospacedDigit()
        }
        .font(.caption)
    }

}

#Preview {
    VideoAdjustsToolView(
        adjusts: Video.mock.colorAdjusts,
        onChangeAdjusts: { _ in }
    )
}
