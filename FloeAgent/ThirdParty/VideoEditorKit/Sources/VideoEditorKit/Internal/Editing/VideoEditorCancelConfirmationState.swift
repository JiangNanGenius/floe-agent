//
//  VideoEditorCancelConfirmationState.swift
//  VideoEditorKit
//
//  Created by Codex on 25.04.2026.
//

import Foundation

enum VideoEditorCancelConfirmationState: Equatable, Identifiable {

    // MARK: - Cases

    case unsavedChanges

    // MARK: - Public Properties

    var id: Self { self }

}
