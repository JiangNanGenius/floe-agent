//
//  AVAudioSession+Ext.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import AVFoundation

extension AVAudioSession {

    // MARK: - Public Methods

    func playAndRecord() {
        do {
            try setCategory(.playAndRecord, mode: .default)
            try overrideOutputAudioPort(.none)
        } catch {
            assertionFailure("Failed to configure play-and-record audio session: \(error.localizedDescription)")
        }
    }

    func configureRecordAudioSessionCategory() {
        do {
            try setCategory(.record, mode: .default)
            try overrideOutputAudioPort(.none)
        } catch {
            assertionFailure("Failed to configure record audio session: \(error.localizedDescription)")
        }
    }

    func configurePlaybackSession() {
        do {
            try setCategory(.playback, mode: .default)
            try overrideOutputAudioPort(.none)
            try setActive(true)
        } catch {
            assertionFailure("Failed to configure playback audio session: \(error.localizedDescription)")
        }
    }

}
