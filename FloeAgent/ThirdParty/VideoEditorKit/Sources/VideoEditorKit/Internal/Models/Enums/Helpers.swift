//
//  Helpers.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import CoreImage
import Foundation

enum Helpers {

    // MARK: - Public Methods

    static func createColorAdjustsFilter(_ colorAdjusts: ColorAdjusts?) -> CIFilter? {
        guard let colorAdjusts else { return nil }

        let colorAdjustsFilter = CIFilter(name: "CIColorControls")

        colorAdjustsFilter?.setValue(
            colorAdjusts.brightness,
            forKey: ColorAdjustType.brightness.key
        )

        colorAdjustsFilter?.setValue(
            colorAdjusts.contrast + 1,
            forKey: ColorAdjustType.contrast.key
        )

        colorAdjustsFilter?.setValue(
            colorAdjusts.saturation + 1,
            forKey: ColorAdjustType.saturation.key
        )

        return colorAdjustsFilter
    }

    static func createColorAdjustsFilters(
        colorAdjusts: ColorAdjusts?
    ) -> [CIFilter] {
        guard let adjustsFilter = createColorAdjustsFilter(colorAdjusts) else {
            return []
        }

        return [adjustsFilter]
    }

}
