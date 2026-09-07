import Foundation

/// One identifier contract for package validation, management and discovery.
public enum SkillIdentifier {
    public static func validate(_ value: String) throws {
        guard !value.isEmpty, value.count <= 64,
              value.first?.isLetter == true,
              value.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }),
              !value.hasSuffix("-"), !value.contains("--") else {
            throw SkillValidationError.invalidIdentifier(value)
        }
    }
}
