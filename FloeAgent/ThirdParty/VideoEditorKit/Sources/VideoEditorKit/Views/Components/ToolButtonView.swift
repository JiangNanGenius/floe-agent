//
//  ToolButtonView.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import SwiftUI

struct ToolButtonView: View {

    // MARK: - Private Properties

    private let label: String
    private let image: String
    private let subtitle: String?
    private let isChange: Bool
    private let isBlocked: Bool
    private let horizontalPadding: CGFloat
    private let action: () -> Void

    // MARK: - Body

    var body: some View {
        Button {
            action()
        } label: {
            buttonContent
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    // MARK: - Private Properties

    private var buttonContent: some View {
        toolLabel
            .frame(maxWidth: .infinity, maxHeight: 80)
            .opacity(isBlocked ? 0.55 : 1)
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                if isBlocked {
                    blockedBadge
                }
            }
            .overlay(alignment: .topTrailing) {
                if isChange {
                    appliedBadge
                }
            }
            .card(
                cornerRadius: 16,
                prominent: isChange && !isBlocked,
                tint: buttonTint
            )
    }

    private var toolLabel: some View {
        VStack(spacing: subtitle == nil ? 4 : 2) {
            Image(systemName: image)
                .font(.headline.weight(.semibold))

            Text(label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            if let subtitle, isChange {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 8)
    }

    private var blockedBadge: some View {
        ZStack {
            Circle()
                .fill(Theme.rootBackground.opacity(0.95))

            Image(systemName: "lock.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.secondary)
        }
        .frame(width: 28, height: 28)
        .padding(8)
    }

    private var appliedBadge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.primary)
            .padding(8)
    }

    private var buttonTint: Color {
        isBlocked ? Theme.secondary : (isChange ? Theme.accent : Theme.secondary)
    }

    private var accessibilityLabel: String {
        VideoEditorStrings.toolButtonAccessibilityLabel(
            label: label,
            isBlocked: isBlocked
        )
    }

    private var accessibilityValue: String {
        VideoEditorStrings.toolButtonAccessibilityValue(
            subtitle: subtitle,
            isApplied: isChange,
            isBlocked: isBlocked
        )
    }

    private var accessibilityHint: String {
        isBlocked
            ? VideoEditorStrings.toolLockedHint
            : VideoEditorStrings.toolOpenHint
    }

    private var accessibilityIdentifier: String {
        "tool-button-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))"
    }

    // MARK: - Initializer

    init(
        _ label: String,
        image: String,
        subtitle: String? = nil,
        isChange: Bool,
        isBlocked: Bool = false,
        horizontalPadding: CGFloat = 12,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.image = image
        self.subtitle = subtitle
        self.isChange = isChange
        self.isBlocked = isBlocked
        self.horizontalPadding = horizontalPadding
        self.action = action
    }

}

#Preview {
    VStack {
        ToolButtonView("Cut", image: "scissors", isChange: false) {}
            .frame(minWidth: 100)
            .frame(height: 104)
        ToolButtonView("Presets", image: "aspectratio", subtitle: "Social 9:16", isChange: true) {}
            .frame(minWidth: 100)
            .frame(height: 104)
        ToolButtonView("Cut", image: "scissors", isChange: false, isBlocked: true) {}
            .frame(minWidth: 100)
            .frame(height: 104)
    }
}
