//
//  PlayerView.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import AVKit
import SwiftUI

struct PlayerView: View {

    // MARK: - Private Properties

    private let player: AVPlayer
    private let showControls: Bool
    private let videoGravity: AVLayerVideoGravity

    // MARK: - Initializer

    init(
        _ player: AVPlayer,
        showControls: Bool = false,
        videoGravity: AVLayerVideoGravity = .resizeAspect
    ) {
        self.player = player
        self.showControls = showControls
        self.videoGravity = videoGravity
    }

    // MARK: - Body

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(contentMode: Self.resolvedContentMode(for: videoGravity))
            .clipped()
            .allowsHitTesting(showControls)
            .accessibilityRespondsToUserInteraction(showControls)
            .background(.clear)
    }

    // MARK: - Private Properties

    nonisolated static func resolvedContentMode(for videoGravity: AVLayerVideoGravity) -> ContentMode {
        switch videoGravity {
        case .resizeAspectFill:
            .fill
        case .resizeAspect, .resize:
            .fit
        default:
            .fit
        }
    }

}

#Preview {
    PlayerView(AVPlayer())
        .frame(height: 300)
}
