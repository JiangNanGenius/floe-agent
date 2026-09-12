//
//  View+Extension.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import SwiftUI

extension View {

    // MARK: - Public Methods

    @ViewBuilder
    nonisolated func card(
        cornerRadius: CGFloat = 28,
        prominent: Bool = false,
        tint: Color? = nil
    ) -> some View {
        adaptativeGlass(
            .roundedRectangle(cornerRadius: cornerRadius),
            prominent: prominent,
            tint: tint
        )
    }

    @ViewBuilder
    nonisolated func circleControl(
        prominent: Bool = false,
        tint: Color? = nil
    ) -> some View {
        adaptativeGlass(
            .circle,
            prominent: prominent,
            tint: tint,
            isInteractive: true
        )
    }

    @ViewBuilder
    nonisolated func capsuleControl(
        prominent: Bool = false,
        tint: Color? = nil
    ) -> some View {
        adaptativeGlass(
            .capsule,
            prominent: prominent,
            tint: tint,
            isInteractive: true
        )
    }

    func vBottom() -> some View {
        frame(maxHeight: .infinity, alignment: .bottom)
    }

    func hCenter() -> some View {
        frame(maxWidth: .infinity, alignment: .center)
    }

    func hLeading() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
    }

    func allFrame() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
