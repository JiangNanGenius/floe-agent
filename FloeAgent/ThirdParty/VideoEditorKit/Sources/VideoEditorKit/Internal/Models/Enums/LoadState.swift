//
//  LoadState.swift
//  VideoEditorKit
//
//  Created by Didi on 27/03/26.
//

import Foundation

enum LoadState: Identifiable, Equatable {

    case unknown, loading
    case loaded(URL)
    case failed

    var id: Int {
        switch self {
        case .unknown: 0
        case .loading: 1
        case .loaded: 2
        case .failed: 3
        }
    }

}
