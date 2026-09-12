//
//  SystemColorPalette.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import SwiftUI

struct SystemColorOption: Identifiable, Hashable {

    // MARK: - Public Properties

    let id: String
    let color: Color
    let checkmarkColor: Color

}

enum SystemColorPalette {
    // MARK: - Public Properties

    static let textBackgrounds: [SystemColorOption] = [
        .init(id: "background", color: Color(uiColor: .systemBackground), checkmarkColor: .black.opacity(0.75)),
        .init(
            id: "secondaryBackground",
            color: Color(uiColor: .secondarySystemBackground),
            checkmarkColor: .black.opacity(0.75)
        ),
        .init(
            id: "tertiaryBackground",
            color: Color(uiColor: .tertiarySystemBackground),
            checkmarkColor: .black.opacity(0.75)
        ),
        .init(id: "blue", color: Color(uiColor: .systemBlue), checkmarkColor: .white),
        .init(id: "teal", color: Color(uiColor: .systemTeal), checkmarkColor: .white),
        .init(id: "green", color: Color(uiColor: .systemGreen), checkmarkColor: .white),
        .init(id: "orange", color: Color(uiColor: .systemOrange), checkmarkColor: .white),
        .init(id: "red", color: Color(uiColor: .systemRed), checkmarkColor: .white),
    ]

    static let textForegrounds: [SystemColorOption] = [
        .init(id: "label", color: Color(uiColor: .label), checkmarkColor: .white),
        .init(id: "secondaryLabel", color: Color(uiColor: .secondaryLabel), checkmarkColor: .white),
        .init(id: "tertiaryLabel", color: Color(uiColor: .tertiaryLabel), checkmarkColor: .white),
        .init(id: "background", color: Color(uiColor: .systemBackground), checkmarkColor: .black.opacity(0.75)),
        .init(id: "blue", color: Color(uiColor: .systemBlue), checkmarkColor: .white),
        .init(id: "teal", color: Color(uiColor: .systemTeal), checkmarkColor: .white),
        .init(id: "orange", color: Color(uiColor: .systemOrange), checkmarkColor: .white),
        .init(id: "red", color: Color(uiColor: .systemRed), checkmarkColor: .white),
    ]

    static let frameColors: [SystemColorOption] = [
        .init(id: "background", color: Color(uiColor: .systemBackground), checkmarkColor: .black.opacity(0.75)),
        .init(
            id: "secondaryBackground",
            color: Color(uiColor: .secondarySystemBackground),
            checkmarkColor: .black.opacity(0.75)
        ),
        .init(id: "blue", color: Color(uiColor: .systemBlue), checkmarkColor: .white),
        .init(id: "teal", color: Color(uiColor: .systemTeal), checkmarkColor: .white),
        .init(id: "green", color: Color(uiColor: .systemGreen), checkmarkColor: .white),
        .init(id: "orange", color: Color(uiColor: .systemOrange), checkmarkColor: .white),
        .init(id: "red", color: Color(uiColor: .systemRed), checkmarkColor: .white),
    ]

    // MARK: - Public Methods

    static func matches(_ lhs: Color, _ rhs: Color) -> Bool {
        UIColor(lhs).resolvedColor(with: .current).cgColor == UIColor(rhs).resolvedColor(with: .current).cgColor
    }
}
