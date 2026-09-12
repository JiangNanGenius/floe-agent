//
//  AudioModel.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import AVKit
import SwiftUI

struct Audio: Identifiable, Equatable {

    // MARK: - Public Properties

    var id: UUID = UUID()
    var url: URL
    var duration: Double
    var volume: Float = 1.0
    var asset: AVAsset {
        AVURLAsset(url: url)
    }

    struct AudioSample: Identifiable {

        var id: Int
        var size: CGFloat = CGFloat((5...25).randomElement() ?? 5)

    }

    // MARK: - Public Methods

    mutating func setVolume(_ value: Float) {
        volume = value
    }

    func createSamples(_ size: CGFloat) -> [AudioSample] {
        let sampleCount = Int(size / 3)
        return (1...sampleCount).map { .init(id: $0) }
    }

}
