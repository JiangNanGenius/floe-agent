import Foundation

public enum TranscriptWordEditingCoordinator {

    private struct TokenMatch: Equatable {

        // MARK: - Public Properties

        let wordIndex: Int
        let tokenIndex: Int

    }

    // MARK: - Public Methods

    public static func reconcileWords(
        _ words: [EditableTranscriptWord],
        with editedSegmentText: String
    ) -> [EditableTranscriptWord]? {
        let tokens = mergedWordTokens(
            from: editedSegmentText
        )

        guard tokens.isEmpty == false else { return nil }
        guard words.isEmpty == false else { return nil }

        if tokens.count == words.count {
            return wordsUpdated(
                from: words,
                with: tokens
            )
        }

        let anchorTokens = words.map(\.originalText).map(normalizedAnchorToken)
        let tokenKeys = tokens.map(normalizedAnchorToken)
        let matches = longestCommonSubsequence(
            wordAnchors: anchorTokens,
            tokenAnchors: tokenKeys
        )

        let resolvedTokens: [String]

        if matches.count == words.count {
            resolvedTokens = groupedTokens(
                tokens: tokens,
                words: words,
                matches: matches
            )
        } else {
            resolvedTokens = fallbackGroupedTokens(
                tokens: tokens,
                words: words,
                matches: matches
            )
        }

        return wordsUpdated(
            from: words,
            with: resolvedTokens
        )
    }

    public static func resolvedWords(
        for segment: EditableTranscriptSegment
    ) -> [EditableTranscriptWord] {
        // Floe: manual captions have no measured word timings. Render the full
        // caption over its segment instead of inventing word-by-word timings.
        guard !segment.words.isEmpty else { return [] }
        let tokens = mergedWordTokens(
            from: segment.editedText
        )

        guard tokens.isEmpty == false else { return [] }

        if let reconciledWords = reconcileWords(
            segment.words,
            with: segment.editedText
        ) {
            return reconciledWords
        }

        return syntheticWords(
            from: tokens,
            segmentTimeMapping: segment.timeMapping
        )
    }

    // MARK: - Private Methods

    private static func wordsUpdated(
        from words: [EditableTranscriptWord],
        with tokens: [String]
    ) -> [EditableTranscriptWord]? {
        guard tokens.count == words.count else { return nil }

        return zip(words, tokens).map { word, token in
            var updatedWord = word
            updatedWord.editedText = token
            return updatedWord
        }
    }

    private static func mergedWordTokens(
        from text: String
    ) -> [String] {
        let rawTokens =
            text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }

        var mergedTokens = [String]()
        var pendingPrefix = ""

        for rawToken in rawTokens {
            if rawToken.containsWordCharacters {
                mergedTokens.append(pendingPrefix + rawToken)
                pendingPrefix = ""
                continue
            }

            if let lastIndex = mergedTokens.indices.last {
                mergedTokens[lastIndex].append(rawToken)
            } else {
                pendingPrefix.append(rawToken)
            }
        }

        if pendingPrefix.isEmpty == false, let firstIndex = mergedTokens.indices.first {
            mergedTokens[firstIndex] = pendingPrefix + mergedTokens[firstIndex]
        }

        return mergedTokens
    }

    private static func normalizedAnchorToken(
        _ text: String
    ) -> String {
        text
            .folding(options: .diacriticInsensitive, locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    private static func longestCommonSubsequence(
        wordAnchors: [String],
        tokenAnchors: [String]
    ) -> [TokenMatch] {
        guard wordAnchors.isEmpty == false, tokenAnchors.isEmpty == false else { return [] }

        let rowCount = wordAnchors.count + 1
        let columnCount = tokenAnchors.count + 1
        var lengths = Array(
            repeating: Array(repeating: 0, count: columnCount),
            count: rowCount
        )

        for wordIndex in wordAnchors.indices {
            for tokenIndex in tokenAnchors.indices {
                if wordAnchors[wordIndex].isEmpty == false,
                    wordAnchors[wordIndex] == tokenAnchors[tokenIndex]
                {
                    lengths[wordIndex + 1][tokenIndex + 1] =
                        lengths[wordIndex][tokenIndex] + 1
                } else {
                    lengths[wordIndex + 1][tokenIndex + 1] = max(
                        lengths[wordIndex][tokenIndex + 1],
                        lengths[wordIndex + 1][tokenIndex]
                    )
                }
            }
        }

        var matches = [TokenMatch]()
        var wordCursor = wordAnchors.count
        var tokenCursor = tokenAnchors.count

        while wordCursor > 0, tokenCursor > 0 {
            if wordAnchors[wordCursor - 1].isEmpty == false,
                wordAnchors[wordCursor - 1] == tokenAnchors[tokenCursor - 1]
            {
                matches.append(
                    TokenMatch(
                        wordIndex: wordCursor - 1,
                        tokenIndex: tokenCursor - 1
                    )
                )
                wordCursor -= 1
                tokenCursor -= 1
            } else if lengths[wordCursor - 1][tokenCursor] >= lengths[wordCursor][tokenCursor - 1] {
                wordCursor -= 1
            } else {
                tokenCursor -= 1
            }
        }

        return matches.reversed()
    }

    private static func groupedTokens(
        tokens: [String],
        words: [EditableTranscriptWord],
        matches: [TokenMatch]
    ) -> [String] {
        var groupedTokens = Array(
            repeating: "",
            count: words.count
        )
        let matchesByWordIndex = Dictionary(
            uniqueKeysWithValues: matches.map { ($0.wordIndex, $0.tokenIndex) }
        )
        let sortedMatches = matches.sorted { lhs, rhs in
            lhs.wordIndex < rhs.wordIndex
        }

        for wordIndex in words.indices {
            guard let matchedTokenIndex = matchesByWordIndex[wordIndex] else { continue }

            let nextMatchTokenIndex =
                sortedMatches
                .first(where: { $0.wordIndex > wordIndex })?
                .tokenIndex
                ?? tokens.count

            groupedTokens[wordIndex] = tokens[matchedTokenIndex..<nextMatchTokenIndex]
                .joined(separator: " ")
        }

        if let firstMatchedWordIndex = sortedMatches.first?.wordIndex,
            let firstMatchedTokenIndex = sortedMatches.first?.tokenIndex,
            firstMatchedTokenIndex > 0
        {
            let leadingText = tokens[..<firstMatchedTokenIndex].joined(separator: " ")
            groupedTokens[firstMatchedWordIndex] =
                leadingText + " " + groupedTokens[firstMatchedWordIndex]
        }

        return groupedTokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func fallbackGroupedTokens(
        tokens: [String],
        words: [EditableTranscriptWord],
        matches: [TokenMatch]
    ) -> [String] {
        guard words.isEmpty == false else { return [] }

        let sortedMatches = matches.sorted { lhs, rhs in
            lhs.wordIndex < rhs.wordIndex
        }
        var groupedTokens = Array(
            repeating: "",
            count: words.count
        )

        if sortedMatches.isEmpty {
            applyDistributedTokens(
                tokens,
                to: 0..<words.count,
                in: &groupedTokens
            )
            return
                groupedTokens
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        for match in sortedMatches {
            groupedTokens[match.wordIndex] = tokens[match.tokenIndex]
        }

        if let firstMatch = sortedMatches.first {
            let leadingTokens = Array(tokens[..<firstMatch.tokenIndex])
            applyDistributedTokens(
                leadingTokens,
                to: 0..<firstMatch.wordIndex,
                in: &groupedTokens
            )

            if leadingTokens.isEmpty == false, firstMatch.wordIndex == 0 {
                groupedTokens[firstMatch.wordIndex] = combinedText(
                    leadingTokens.joined(separator: " "),
                    groupedTokens[firstMatch.wordIndex]
                )
            }
        }

        for index in sortedMatches.indices.dropLast() {
            let currentMatch = sortedMatches[index]
            let nextMatch = sortedMatches[index + 1]
            let intermediateTokens = Array(
                tokens[(currentMatch.tokenIndex + 1)..<nextMatch.tokenIndex]
            )
            let intermediateSlots = (currentMatch.wordIndex + 1)..<nextMatch.wordIndex

            applyDistributedTokens(
                intermediateTokens,
                to: intermediateSlots,
                in: &groupedTokens
            )

            if intermediateTokens.isEmpty == false, intermediateSlots.isEmpty {
                groupedTokens[currentMatch.wordIndex] = combinedText(
                    groupedTokens[currentMatch.wordIndex],
                    intermediateTokens.joined(separator: " ")
                )
            }
        }

        if let lastMatch = sortedMatches.last {
            let trailingTokens = Array(tokens[(lastMatch.tokenIndex + 1)...])
            let trailingSlots = (lastMatch.wordIndex + 1)..<words.count

            applyDistributedTokens(
                trailingTokens,
                to: trailingSlots,
                in: &groupedTokens
            )

            if trailingTokens.isEmpty == false, trailingSlots.isEmpty {
                groupedTokens[lastMatch.wordIndex] = combinedText(
                    groupedTokens[lastMatch.wordIndex],
                    trailingTokens.joined(separator: " ")
                )
            }
        }

        return groupedTokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func applyDistributedTokens(
        _ tokens: [String],
        to slotRange: Range<Int>,
        in groupedTokens: inout [String]
    ) {
        guard tokens.isEmpty == false else { return }
        guard slotRange.isEmpty == false else { return }

        let tokenGroups = distributedTokenGroups(
            tokens: tokens,
            slotCount: slotRange.count
        )

        for (offset, slotIndex) in slotRange.enumerated() {
            let tokenGroup = tokenGroups[offset]
            guard tokenGroup.isEmpty == false else { continue }
            groupedTokens[slotIndex] = tokenGroup
        }
    }

    private static func distributedTokenGroups(
        tokens: [String],
        slotCount: Int
    ) -> [String] {
        guard slotCount > 0 else { return [] }
        guard tokens.isEmpty == false else {
            return Array(
                repeating: "",
                count: slotCount
            )
        }

        let baseCount = tokens.count / slotCount
        let remainder = tokens.count % slotCount
        var groups = [String]()
        var tokenCursor = 0

        for slotIndex in 0..<slotCount {
            let tokenCount = baseCount + (slotIndex < remainder ? 1 : 0)
            guard tokenCount > 0 else {
                groups.append("")
                continue
            }

            let nextCursor = min(
                tokenCursor + tokenCount,
                tokens.count
            )
            groups.append(
                tokens[tokenCursor..<nextCursor]
                    .joined(separator: " ")
            )
            tokenCursor = nextCursor
        }

        return groups
    }

    private static func syntheticWords(
        from tokens: [String],
        segmentTimeMapping: TranscriptTimeMapping
    ) -> [EditableTranscriptWord] {
        let sourceRanges = distributedRanges(
            count: tokens.count,
            within: segmentTimeMapping.sourceRange
        )
        let timelineRanges = segmentTimeMapping.timelineRange.map {
            distributedRanges(
                count: tokens.count,
                within: $0
            )
        }

        return tokens.enumerated().map { index, token in
            let sourceRange = sourceRanges[index]
            let timelineRange = timelineRanges?[index]

            return EditableTranscriptWord(
                id: UUID(),
                timeMapping: .init(
                    sourceStartTime: sourceRange.lowerBound,
                    sourceEndTime: sourceRange.upperBound,
                    timelineStartTime: timelineRange?.lowerBound,
                    timelineEndTime: timelineRange?.upperBound
                ),
                originalText: token,
                editedText: token
            )
        }
    }

    private static func distributedRanges(
        count: Int,
        within range: ClosedRange<Double>
    ) -> [ClosedRange<Double>] {
        guard count > 0 else { return [] }

        let duration = max(
            range.upperBound - range.lowerBound,
            0
        )

        return (0..<count).map { index in
            let start = range.lowerBound + (duration * Double(index) / Double(count))
            let end =
                if index == count - 1 {
                    range.upperBound
                } else {
                    range.lowerBound + (duration * Double(index + 1) / Double(count))
                }

            return start...end
        }
    }

    private static func combinedText(
        _ leadingText: String,
        _ trailingText: String
    ) -> String {
        guard leadingText.isEmpty == false else { return trailingText }
        guard trailingText.isEmpty == false else { return leadingText }
        return "\(leadingText) \(trailingText)"
    }

}

extension String {

    // MARK: - Private Properties

    fileprivate var containsWordCharacters: Bool {
        rangeOfCharacter(from: .alphanumerics) != nil
    }

}
