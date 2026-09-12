//
//  TimeInterval+Ext.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import Foundation

extension TimeInterval {

    // MARK: - Public Properties

    var minutesSecondsMilliseconds: String {
        guard isFinite, self >= 0 else {
            return "00:00:00"
        }

        let totalSeconds = Int(self.rounded(.down))
        let minutes = (totalSeconds / 60) % 60
        let seconds = totalSeconds % 60
        let centiseconds = Int((self * 100).rounded(.down)) % 100

        return "\(minutes.twoDigitString):\(seconds.twoDigitString):\(centiseconds.twoDigitString)"
    }

    var minuteSeconds: String {
        guard isFinite, self > 0 else {
            return VideoEditorStrings.unknown
        }

        let totalSeconds = Int(self.rounded(.down))
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60

        return "\(minutes.twoDigitString):\(seconds.twoDigitString)"
    }

    // MARK: - Public Methods

    func formatterTimeString() -> String {
        guard isFinite, self >= 0 else {
            return "00:00"
        }

        let totalSeconds = Int(self.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours.twoDigitString):\(minutes.twoDigitString):\(seconds.twoDigitString)"
        }

        let totalMinutes = totalSeconds / 60
        return "\(totalMinutes.twoDigitString):\(seconds.twoDigitString)"
    }

    func formatterPreciseTimeString() -> String {
        guard isFinite, self >= 0 else {
            return "00:00.00"
        }

        let totalCentiseconds = Int((self * 100).rounded())
        let hours = totalCentiseconds / 360_000
        let minutes = (totalCentiseconds % 360_000) / 6_000
        let seconds = (totalCentiseconds % 6_000) / 100
        let centiseconds = totalCentiseconds % 100

        if hours > 0 {
            return
                "\(hours.twoDigitString):\(minutes.twoDigitString):\(seconds.twoDigitString).\(centiseconds.twoDigitString)"
        }

        let totalMinutes = totalCentiseconds / 6_000
        return "\(totalMinutes.twoDigitString):\(seconds.twoDigitString).\(centiseconds.twoDigitString)"
    }

}

extension Int {

    // MARK: - Public Methods

    func secondsToTime() -> String {
        let totalSeconds = Swift.max(0, self)
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        return "\(minutes.twoDigitString):\(seconds.twoDigitString)"
    }

}

extension BinaryInteger {

    // MARK: - Private Properties

    fileprivate var twoDigitString: String {
        let digits = String(self)
        return digits.count == 1 ? "0\(digits)" : digits
    }

}
