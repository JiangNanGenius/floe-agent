import Foundation

struct OpenAIWhisperResponseMapper {

    // MARK: - Public Methods

    func map(_ response: WhisperVerboseTranscriptionResponseDTO) -> VideoTranscriptionResult {
        let normalizedWords = normalizedWords(from: response.words)
        let segments = mappedSegments(
            from: response.segments,
            normalizedWords: normalizedWords
        )

        guard !segments.isEmpty else {
            return fallbackResult(
                from: response,
                normalizedWords: normalizedWords
            )
        }

        return VideoTranscriptionResult(segments: segments)
    }

    // MARK: - Private Methods

    private func mappedSegments(
        from segments: [WhisperVerboseTranscriptionResponseDTO.Segment],
        normalizedWords: [TranscriptionWord]
    ) -> [TranscriptionSegment] {
        segments
            .sorted(by: segmentSortComparator(_:_:))
            .compactMap { segment in
                let segmentWords = words(
                    for: segment,
                    normalizedWords: normalizedWords
                )
                let text = resolvedSegmentText(
                    segment.text,
                    segmentWords: segmentWords
                )

                guard !text.isEmpty else { return nil }

                return TranscriptionSegment(
                    id: UUID(),
                    startTime: normalizedStartTime(for: segment.start),
                    endTime: normalizedEndTime(
                        startTime: segment.start,
                        endTime: segment.end
                    ),
                    text: text,
                    words: segmentWords
                )
            }
    }

    private func words(
        for segment: WhisperVerboseTranscriptionResponseDTO.Segment,
        normalizedWords: [TranscriptionWord]
    ) -> [TranscriptionWord] {
        let startTime = normalizedStartTime(for: segment.start)
        let endTime = normalizedEndTime(
            startTime: segment.start,
            endTime: segment.end
        )

        return normalizedWords.filter { word in
            let midpoint = (word.startTime + word.endTime) / 2
            return midpoint >= startTime && midpoint <= endTime
        }
    }

    private func normalizedWords(
        from words: [WhisperVerboseTranscriptionResponseDTO.Word]
    ) -> [TranscriptionWord] {
        words
            .sorted(by: wordSortComparator(_:_:))
            .compactMap { word in
                let text = normalizedText(word.word)
                guard !text.isEmpty else { return nil }

                return TranscriptionWord(
                    id: UUID(),
                    startTime: normalizedStartTime(for: word.start),
                    endTime: normalizedEndTime(
                        startTime: word.start,
                        endTime: word.end
                    ),
                    text: text
                )
            }
    }

    private func fallbackResult(
        from response: WhisperVerboseTranscriptionResponseDTO,
        normalizedWords: [TranscriptionWord]
    ) -> VideoTranscriptionResult {
        let text = resolvedSegmentText(
            response.text,
            segmentWords: normalizedWords
        )

        guard !text.isEmpty else {
            return VideoTranscriptionResult()
        }

        let bounds = fallbackTimeBounds(
            response: response,
            normalizedWords: normalizedWords
        )

        return VideoTranscriptionResult(
            segments: [
                TranscriptionSegment(
                    id: UUID(),
                    startTime: bounds.startTime,
                    endTime: bounds.endTime,
                    text: text,
                    words: normalizedWords
                )
            ]
        )
    }

    private func fallbackTimeBounds(
        response: WhisperVerboseTranscriptionResponseDTO,
        normalizedWords: [TranscriptionWord]
    ) -> (startTime: Double, endTime: Double) {
        if let firstWord = normalizedWords.first,
            let lastWord = normalizedWords.last
        {
            return (
                startTime: firstWord.startTime,
                endTime: max(firstWord.startTime, lastWord.endTime)
            )
        }

        let duration = max(response.duration ?? 0, 0)
        return (startTime: 0, endTime: duration)
    }

    private func resolvedSegmentText(
        _ text: String,
        segmentWords: [TranscriptionWord]
    ) -> String {
        let normalizedSegmentText = normalizedText(text)
        guard normalizedSegmentText.isEmpty else { return normalizedSegmentText }

        return normalizedText(
            segmentWords
                .map(\.text)
                .joined(separator: " ")
        )
    }

    private func normalizedText(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func normalizedStartTime(for time: Double) -> Double {
        max(time, 0)
    }

    private func normalizedEndTime(startTime: Double, endTime: Double) -> Double {
        let resolvedStartTime = normalizedStartTime(for: startTime)
        return max(normalizedStartTime(for: endTime), resolvedStartTime)
    }

    private func segmentSortComparator(
        _ lhs: WhisperVerboseTranscriptionResponseDTO.Segment,
        _ rhs: WhisperVerboseTranscriptionResponseDTO.Segment
    ) -> Bool {
        if lhs.start != rhs.start {
            return lhs.start < rhs.start
        }

        return lhs.end < rhs.end
    }

    private func wordSortComparator(
        _ lhs: WhisperVerboseTranscriptionResponseDTO.Word,
        _ rhs: WhisperVerboseTranscriptionResponseDTO.Word
    ) -> Bool {
        if lhs.start != rhs.start {
            return lhs.start < rhs.start
        }

        return lhs.end < rhs.end
    }

}
