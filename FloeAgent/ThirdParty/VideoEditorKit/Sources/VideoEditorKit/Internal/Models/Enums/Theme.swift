//
//  Theme.swift
//  VideoEditorKit
//
//  Created by Didi on 24/03/26.
//

import SwiftUI

enum Theme {
    // MARK: - Public Properties

    static let accent = Color.accentColor
    static let primary = Color.primary
    static let secondary = Color.secondary
    static let selection = Color(uiColor: .systemBlue)
    static let destructive = Color(uiColor: .systemRed)
    static let outline = Color(uiColor: .separator).opacity(0.35)
    static let sliderTrack = Color(uiColor: .quaternaryLabel).opacity(0.35)
    static let sliderThumb = Color(uiColor: .systemBackground)
    static let rootBackground = LinearGradient(
        colors: [
            Color(uiColor: .systemBackground),
            Color(uiColor: .secondarySystemBackground),
            Color(uiColor: .tertiarySystemBackground),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let editorBackground = LinearGradient(
        colors: [
            Color(uiColor: .systemBackground),
            Color(uiColor: .secondarySystemBackground),
            Color(uiColor: .tertiarySystemBackground),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let editorGlow = RadialGradient(
        colors: [
            accent.opacity(0.24),
            .clear,
        ],
        center: .topTrailing,
        startRadius: 40,
        endRadius: 520
    )

    static let scrim = Color(uiColor: .label).opacity(0.18)
}
