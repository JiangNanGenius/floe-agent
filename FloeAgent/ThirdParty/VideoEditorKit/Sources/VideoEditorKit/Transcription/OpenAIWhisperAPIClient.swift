import Foundation

protocol HTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPSession {}

struct OpenAIWhisperAPIClient {

    // MARK: - Public Properties

    struct Request: Sendable {
        let audioFileURL: URL
        let model: String
        let language: String?
        let responseFormat: String
        let timestampGranularities: [String]

        init(
            audioFileURL: URL,
            model: String = "whisper-1",
            language: String? = nil,
            responseFormat: String = "verbose_json",
            timestampGranularities: [String] = ["segment", "word"]
        ) {
            self.audioFileURL = audioFileURL
            self.model = model
            self.language = language
            self.responseFormat = responseFormat
            self.timestampGranularities = timestampGranularities
        }
    }

    enum ClientError: Error, Equatable, LocalizedError {
        case invalidAudioFileURL
        case invalidServerResponse
        case unsuccessfulStatusCode(Int, String?)
        case emptyResponseData

        var errorDescription: String? {
            switch self {
            case .invalidAudioFileURL:
                VideoEditorStrings.whisperInvalidAudioURL
            case .invalidServerResponse:
                VideoEditorStrings.whisperInvalidResponse
            case .unsuccessfulStatusCode(let statusCode, let message):
                message ?? VideoEditorStrings.whisperHTTPError(statusCode)
            case .emptyResponseData:
                VideoEditorStrings.whisperEmptyResponse
            }
        }
    }

    // MARK: - Private Properties

    private let apiKey: String
    private let session: any HTTPSession
    private let endpoint: URL
    private let multipartBuilder: OpenAIWhisperMultipartFormDataBuilder
    private let decoder: JSONDecoder
    private static let defaultEndpoint: URL = {
        guard let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            preconditionFailure("The default Whisper transcription endpoint must be a valid URL.")
        }

        return endpoint
    }()

    // MARK: - Initializer

    init(
        apiKey: String,
        session: any HTTPSession = URLSession.shared,
        endpoint: URL = Self.defaultEndpoint,
        multipartBuilder: OpenAIWhisperMultipartFormDataBuilder = .init(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
        self.multipartBuilder = multipartBuilder
        self.decoder = decoder
    }

    // MARK: - Public Methods

    func createTranscription(
        request: Request
    ) async throws -> WhisperVerboseTranscriptionResponseDTO {
        guard request.audioFileURL.isFileURL else {
            throw ClientError.invalidAudioFileURL
        }

        let audioData = try Data(contentsOf: request.audioFileURL)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(multipartBuilder.contentTypeHeaderValue, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let fields = requestFields(for: request)
        let repeatedFields = requestRepeatedFields(for: request)
        let filePart = OpenAIWhisperMultipartFormDataBuilder.FilePart(
            fieldName: "file",
            filename: request.audioFileURL.lastPathComponent,
            mimeType: mimeType(for: request.audioFileURL),
            data: audioData
        )

        urlRequest.httpBody = multipartBuilder.makeBody(
            fields: fields,
            repeatedFields: repeatedFields,
            filePart: filePart
        )

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidServerResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw ClientError.unsuccessfulStatusCode(
                httpResponse.statusCode,
                parseErrorMessage(from: data)
            )
        }

        guard !data.isEmpty else {
            throw ClientError.emptyResponseData
        }

        return try decoder.decode(WhisperVerboseTranscriptionResponseDTO.self, from: data)
    }

    // MARK: - Private Methods

    private func requestFields(for request: Request) -> [String: String] {
        var fields = [
            "model": request.model,
            "response_format": request.responseFormat,
        ]

        if let language = normalizedLanguageCode(from: request.language) {
            fields["language"] = language
        }

        return fields
    }

    private func requestRepeatedFields(for request: Request) -> [String: [String]] {
        let values = request.timestampGranularities.filter { !$0.isEmpty }
        guard !values.isEmpty else { return [:] }
        return ["timestamp_granularities[]": values]
    }

    private func normalizedLanguageCode(from language: String?) -> String? {
        guard
            let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmedLanguage.isEmpty
        else {
            return nil
        }

        let normalizedSeparators = trimmedLanguage.replacingOccurrences(of: "_", with: "-")
        let languageToken =
            normalizedSeparators
            .split(separator: "-", maxSplits: 1)
            .first?
            .lowercased()

        guard let languageToken, !languageToken.isEmpty else { return nil }

        if languageToken.count == 2 {
            return languageToken
        }

        return iso6391CodeByISO6392Code[languageToken]
    }

    private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "m4a":
            "audio/m4a"
        case "mp3":
            "audio/mpeg"
        case "wav":
            "audio/wav"
        default:
            "application/octet-stream"
        }
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        guard
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = payload["error"] as? [String: Any]
        else {
            return nil
        }

        return error["message"] as? String
    }

    private var iso6391CodeByISO6392Code: [String: String] {
        [
            "ara": "ar",
            "ben": "bn",
            "chi": "zh",
            "cmn": "zh",
            "dan": "da",
            "deu": "de",
            "dut": "nl",
            "eng": "en",
            "fin": "fi",
            "fra": "fr",
            "fre": "fr",
            "ger": "de",
            "gre": "el",
            "ell": "el",
            "heb": "he",
            "hin": "hi",
            "ind": "id",
            "ita": "it",
            "jpn": "ja",
            "kor": "ko",
            "nld": "nl",
            "nor": "no",
            "pol": "pl",
            "por": "pt",
            "ron": "ro",
            "rum": "ro",
            "rus": "ru",
            "spa": "es",
            "swe": "sv",
            "tha": "th",
            "tur": "tr",
            "ukr": "uk",
            "vie": "vi",
            "zho": "zh",
        ]
    }

}
