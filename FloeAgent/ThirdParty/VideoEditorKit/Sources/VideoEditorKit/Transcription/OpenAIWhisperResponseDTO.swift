import Foundation

struct WhisperVerboseTranscriptionResponseDTO: Decodable, Equatable, Sendable {

    // MARK: - Public Properties

    let task: String?
    let language: String?
    let duration: Double?
    let text: String
    let segments: [Segment]
    let words: [Word]

    // MARK: - Initializer

    init(
        task: String? = nil,
        language: String? = nil,
        duration: Double? = nil,
        text: String,
        segments: [Segment] = [],
        words: [Word] = []
    ) {
        self.task = task
        self.language = language
        self.duration = duration
        self.text = text
        self.segments = segments
        self.words = words
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        task = try container.decodeIfPresent(String.self, forKey: .task)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        text = try container.decode(String.self, forKey: .text)
        segments = try container.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        words = try container.decodeIfPresent([Word].self, forKey: .words) ?? []
    }

    // MARK: - Private Properties

    private enum CodingKeys: String, CodingKey {
        case task
        case language
        case duration
        case text
        case segments
        case words
    }

}

extension WhisperVerboseTranscriptionResponseDTO {

    struct Segment: Decodable, Equatable, Sendable {

        // MARK: - Public Properties

        let id: Int?
        let start: Double
        let end: Double
        let text: String
    }

    struct Word: Decodable, Equatable, Sendable {

        // MARK: - Public Properties

        let start: Double
        let end: Double
        let word: String
    }

}
