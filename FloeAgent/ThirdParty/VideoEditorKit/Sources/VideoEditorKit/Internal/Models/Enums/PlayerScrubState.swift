//
//  PlayerScrubState.swift
//  VideoEditorKit
//
//  Created by Didi on 27/03/26.
//

import Foundation

enum PlayerScrubState {
    case reset
    case scrubStarted
    case scrubEnded(Double)
}
