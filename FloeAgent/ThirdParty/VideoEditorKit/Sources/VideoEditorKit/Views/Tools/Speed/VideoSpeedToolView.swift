//
//  VideoSpeedToolView.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import SwiftUI

struct VideoSpeedToolView: View {

    private enum SpeedOption: Double, CaseIterable, Identifiable {
        case x1 = 1
        case x2 = 2
        case x3 = 3

        // MARK: - Public Properties

        var id: Double { rawValue }

        var title: String {
            "\(Int(rawValue))x"
        }

        // MARK: - Public Methods

        static func closest(to rate: Double) -> Self {
            allCases.min { lhs, rhs in
                abs(lhs.rawValue - rate) < abs(rhs.rawValue - rate)
            } ?? .x1
        }
    }

    // MARK: - Public Properties

    let selectedRate: Double
    private let onSelectRate: (Double) -> Void

    // MARK: - Body

    var body: some View {
        Picker(VideoEditorStrings.toolSpeed, selection: selectedOptionBinding) {
            ForEach(SpeedOption.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .safeAreaPadding()
    }

    // MARK: - Private Properties

    private var selectedOptionBinding: Binding<SpeedOption> {
        Binding(
            get: { SpeedOption.closest(to: selectedRate) },
            set: { option in
                onSelectRate(option.rawValue)
            }
        )
    }

    // MARK: - Initializer

    init(
        selectedRate: Double,
        onSelectRate: @escaping (Double) -> Void
    ) {
        self.selectedRate = selectedRate
        self.onSelectRate = onSelectRate
    }

}

#Preview {
    VideoSpeedToolView(
        selectedRate: 1,
        onSelectRate: { _ in }
    )
}
