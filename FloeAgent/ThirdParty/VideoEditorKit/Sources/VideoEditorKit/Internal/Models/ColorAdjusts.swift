//
//  ColorAdjusts.swift
//  VideoEditorKit
//
//  Created by Codex on 30.03.2026.
//

import CoreImage
import Foundation

enum ColorAdjustType: CaseIterable {

    // MARK: - Public Properties

    case brightness
    case contrast
    case saturation

    var title: String {
        switch self {
        case .brightness:
            VideoEditorStrings.brightness
        case .contrast:
            VideoEditorStrings.contrast
        case .saturation:
            VideoEditorStrings.saturation
        }
    }

    var key: String {
        switch self {
        case .brightness: kCIInputBrightnessKey
        case .contrast: kCIInputContrastKey
        case .saturation: kCIInputSaturationKey
        }
    }

}

struct ColorAdjusts: Equatable, Sendable {

    // MARK: - Public Properties

    var brightness: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0

    var isIdentity: Bool {
        abs(brightness) <= 0.001
            && abs(contrast) <= 0.001
            && abs(saturation) <= 0.001
    }

    var appliedAdjustmentsCount: Int {
        [
            brightness,
            contrast,
            saturation,
        ]
        .filter { abs($0) > 0.001 }
        .count
    }

    // MARK: - Public Methods

    func updating(
        _ keyPath: WritableKeyPath<Self, Double>,
        to newValue: Double
    ) -> Self {
        var updatedAdjusts = self
        updatedAdjusts[keyPath: keyPath] = newValue
        return updatedAdjusts
    }

}
