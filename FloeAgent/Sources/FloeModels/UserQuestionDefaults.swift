import Foundation
import FloeCore

/// Device preference used only while materializing a NEW explicitly optional
/// question with a declared fallback. Published deadlines remain immutable.
public struct UserQuestionDefaults: Codable, Equatable, Sendable {
    public static let settingsKey = "floe.settings.userQuestionDefaults.v1"
    public static let initialTimeoutSeconds = 15
    public var optionalTimeoutSeconds: Int

    public init(optionalTimeoutSeconds: Int = initialTimeoutSeconds) {
        self.optionalTimeoutSeconds = optionalTimeoutSeconds
    }
    public func validated() throws -> Self {
        guard (UserQuestionRequest.minimumDeadlineSeconds...UserQuestionRequest.maximumDeadlineSeconds).contains(optionalTimeoutSeconds) else {
            throw FloeError.validationFailed("Question timeout must be 5–86400 seconds.")
        }
        return self
    }
    public static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: settingsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              let valid = try? value.validated() else { return .init() }
        return valid
    }
    public func save(to defaults: UserDefaults) throws {
        let value = try validated()
        defaults.set(try JSONEncoder().encode(value), forKey: Self.settingsKey)
    }
}

extension UserQuestionRequest {
    /// Required and legacy untimed optionalContinue requests stay unchanged.
    /// Missing fallback/invalid explicit values still fail normal validation.
    public func resolvingDefaults(_ defaults: UserQuestionDefaults) throws -> Self {
        var result = self
        for index in questions.indices {
            let question = questions[index]
            let policy = question.effectiveWaitPolicy(default: waitPolicy)
            guard policy == .optionalDeadline || policy == .optionalContinue,
                  question.answerSensitivity == .ordinary,
                  question.fallback != nil,
                  question.effectiveTimeoutSeconds(default: timeoutSeconds) == nil else { continue }
            result.questions[index].timeoutSeconds = try defaults.validated().optionalTimeoutSeconds
        }
        return result
    }
}

/// Read-only display projection of the already-declared fallback, never an
/// answer or selection. Sensitive defaults expose no value in the card.
public struct UserQuestionFallbackPresentation: Equatable, Sendable {
    public let isSensitive: Bool
    public let components: [String]
    public init?(question: UserQuestion) {
        guard question.deadlineAt != nil, let fallback = question.fallback else { return nil }
        isSensitive = question.answerSensitivity == .credential
        if isSensitive { components = []; return }
        let labels = fallback.selectedOptionIDs.compactMap { id in question.options.first(where: { $0.id == id })?.label }
        let text = fallback.freeText?.trimmingCharacters(in: .whitespacesAndNewlines)
        components = labels + ((text?.isEmpty == false) ? [text!] : [])
    }
}
