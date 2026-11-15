// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeInteriorCore

struct FurnitureOBJParseResult: Equatable, Sendable {
    var bounds: FurnitureSourceBounds
    var vertexCount: Int
    var materialLibraries: [String]
}

struct FurnitureMTLTextureReference: Equatable, Sendable {
    var path: String
}

struct FurnitureMTLParseResult: Equatable, Sendable {
    var textureReferences: [FurnitureMTLTextureReference]
    var issues: [FurnitureAssetIssue]
}

enum FurnitureAssetMapParseError: Error, Equatable {
    case unsupportedOption(String)
    case malformed(String)
}

enum FurnitureOBJParser {
    static func parse(_ data: Data, limits: FurnitureAssetLibraryLimits) throws -> FurnitureOBJParseResult {
        guard var text = String(data: data, encoding: .utf8) else {
            throw FurnitureAssetLibraryError.invalidOBJ("the file is not valid UTF-8")
        }
        if text.unicodeScalars.first?.value == 0xFEFF {
            text.removeFirst()
        }

        var minimum = InteriorVector3(.infinity, .infinity, .infinity)
        var maximum = InteriorVector3(-.infinity, -.infinity, -.infinity)
        var vertexCount = 0
        var textureCoordinateCount = 0
        var normalCount = 0
        var maximumVertexIndex = 0
        var maximumTextureIndex = 0
        var maximumNormalIndex = 0
        var materialLibraries: [String] = []
        var lineNumber = 0

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lineNumber += 1
            if lineNumber % 4_096 == 0 {
                try Task.checkCancellation()
            }
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard line.utf8.count <= limits.maximumLineBytes else {
                throw FurnitureAssetLibraryError.invalidOBJ("line \(lineNumber) exceeds the line budget")
            }
            let dataLine = removingInlineComment(from: line)
            let parts = dataLine.split(whereSeparator: \.isWhitespace)
            guard let firstPart = parts.first else { continue }
            let command = String(firstPart)

            switch command {
            case "v":
                guard parts.count >= 4 else {
                    throw FurnitureAssetLibraryError.invalidOBJ("line \(lineNumber) has an incomplete vertex")
                }
                let x = try finiteDouble(parts[1], line: lineNumber)
                let y = try finiteDouble(parts[2], line: lineNumber)
                let z = try finiteDouble(parts[3], line: lineNumber)
                if parts.count == 5 {
                    let w = try finiteDouble(parts[4], line: lineNumber)
                    guard w == 1 else {
                        throw FurnitureAssetLibraryError.invalidOBJ("line \(lineNumber) uses an unsupported vertex weight")
                    }
                } else if parts.count >= 7 {
                    let w = try finiteDouble(parts[4], line: lineNumber)
                    guard w == 1 else {
                        throw FurnitureAssetLibraryError.invalidOBJ("line \(lineNumber) uses an unsupported vertex weight")
                    }
                }
                if parts.count > 4 {
                    for token in parts.dropFirst(4) {
                        _ = try finiteDouble(token, line: lineNumber)
                    }
                }
                minimum = .init(min(minimum.x, x), min(minimum.y, y), min(minimum.z, z))
                maximum = .init(max(maximum.x, x), max(maximum.y, y), max(maximum.z, z))
                vertexCount += 1
                guard vertexCount <= limits.maximumVertices else {
                    throw FurnitureAssetLibraryError.budgetExceeded("the OBJ exceeds \(limits.maximumVertices) vertices")
                }

            case "vt":
                guard parts.count >= 2 else {
                    throw FurnitureAssetLibraryError.invalidOBJ("line \(lineNumber) has an incomplete texture coordinate")
                }
                for token in parts.dropFirst() {
                    _ = try finiteDouble(token, line: lineNumber)
                }
                textureCoordinateCount += 1

            case "vn":
                guard parts.count >= 4 else {
                    throw FurnitureAssetLibraryError.invalidOBJ("line \(lineNumber) has an incomplete normal")
                }
                for token in parts.dropFirst() {
                    _ = try finiteDouble(token, line: lineNumber)
                }
                normalCount += 1

            case "f", "l", "p":
                let minimumElements = command == "f" ? 3 : (command == "l" ? 2 : 1)
                guard parts.count >= minimumElements + 1 else {
                    throw FurnitureAssetLibraryError.invalidOBJ("line \(lineNumber) has too few \(command) elements")
                }
                for token in parts.dropFirst() {
                    try parseIndexToken(
                        token,
                        line: lineNumber,
                        vertexCount: vertexCount,
                        textureCoordinateCount: textureCoordinateCount,
                        normalCount: normalCount,
                        maximumVertexIndex: &maximumVertexIndex,
                        maximumTextureIndex: &maximumTextureIndex,
                        maximumNormalIndex: &maximumNormalIndex
                    )
                }

            case "mtllib":
                let argument = String(line.dropFirst("mtllib".count)).trimmingCharacters(in: .whitespaces)
                guard !argument.isEmpty else {
                    throw FurnitureAssetLibraryError.invalidOBJ("line \(lineNumber) has an empty mtllib reference")
                }
                materialLibraries.append(argument)

            default:
                continue
            }
        }

        guard vertexCount > 0 else {
            throw FurnitureAssetLibraryError.invalidOBJ("the OBJ has no vertices")
        }
        guard maximumVertexIndex <= vertexCount else {
            throw FurnitureAssetLibraryError.invalidOBJ("a face references a vertex past the declared vertex count")
        }
        guard maximumTextureIndex <= textureCoordinateCount else {
            throw FurnitureAssetLibraryError.invalidOBJ("a face references a texture coordinate past the declared count")
        }
        guard maximumNormalIndex <= normalCount else {
            throw FurnitureAssetLibraryError.invalidOBJ("a face references a normal past the declared count")
        }

        let bounds = FurnitureSourceBounds(minimum: minimum, maximum: maximum)
        return .init(bounds: bounds, vertexCount: vertexCount, materialLibraries: materialLibraries)
    }

    static func quotedTokens(_ text: String) throws -> [String] {
        var scanner = MTLScanner(text: text)
        var result: [String] = []
        while true {
            scanner.skipWhitespace()
            guard !scanner.isAtEnd else { break }
            guard let token = scanner.readTokenOrQuoted() else {
                throw FurnitureAssetLibraryError.invalidOBJ("an mtllib reference has an unterminated quote")
            }
            result.append(token)
        }
        return result
    }

    private static func parseIndexToken(
        _ token: Substring,
        line: Int,
        vertexCount: Int,
        textureCoordinateCount: Int,
        normalCount: Int,
        maximumVertexIndex: inout Int,
        maximumTextureIndex: inout Int,
        maximumNormalIndex: inout Int
    ) throws {
        let fields = token.split(separator: "/", omittingEmptySubsequences: false)
        guard !fields.isEmpty, fields.count <= 3 else {
            throw FurnitureAssetLibraryError.invalidOBJ("line \(line) has an invalid element index")
        }
        try parseIndex(fields[0], currentCount: vertexCount, line: line, kind: "vertex", maximum: &maximumVertexIndex)
        if fields.count >= 2, !fields[1].isEmpty {
            try parseIndex(fields[1], currentCount: textureCoordinateCount, line: line, kind: "texture coordinate", maximum: &maximumTextureIndex)
        }
        if fields.count == 3, !fields[2].isEmpty {
            try parseIndex(fields[2], currentCount: normalCount, line: line, kind: "normal", maximum: &maximumNormalIndex)
        }
    }

    private static func parseIndex(
        _ field: Substring,
        currentCount: Int,
        line: Int,
        kind: String,
        maximum: inout Int
    ) throws {
        guard let index = Int(field), index != 0 else {
            throw FurnitureAssetLibraryError.invalidOBJ("line \(line) has an invalid \(kind) index")
        }
        if index > 0 {
            maximum = max(maximum, index)
        } else {
            guard -index <= currentCount else {
                throw FurnitureAssetLibraryError.invalidOBJ("line \(line) has a negative \(kind) index past the current count")
            }
        }
    }

    private static func finiteDouble(_ token: Substring, line: Int) throws -> Double {
        guard let value = Double(token), value.isFinite else {
            throw FurnitureAssetLibraryError.invalidOBJ("line \(line) has a non-finite or malformed number")
        }
        return value
    }

    private static func removingInlineComment(from line: String) -> String {
        var previous: Character?
        for index in line.indices {
            let character = line[index]
            if character == "#", previous?.isWhitespace == true {
                return String(line[..<index])
            }
            previous = character
        }
        return line
    }
}

enum FurnitureMTLParser {
    private static let namedTextureCommands: Set<String> = [
        "bump", "disp", "decal", "refl", "norm"
    ]

    static func parse(_ data: Data, sourceRelativePath: String, limits: FurnitureAssetLibraryLimits) -> FurnitureMTLParseResult {
        guard var text = String(data: data, encoding: .utf8) else {
            return .init(
                textureReferences: [],
                issues: [.init(
                    kind: .invalidMaterialLibrary,
                    sourceRelativePath: sourceRelativePath,
                    role: .materialLibrary,
                    detail: "The material library is not valid UTF-8."
                )]
            )
        }
        if text.unicodeScalars.first?.value == 0xFEFF {
            text.removeFirst()
        }

        var references: [FurnitureMTLTextureReference] = []
        var issues: [FurnitureAssetIssue] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard line.utf8.count <= limits.maximumLineBytes else {
                issues.append(.init(
                    kind: .invalidMaterialLibrary,
                    sourceRelativePath: sourceRelativePath,
                    role: .materialLibrary,
                    detail: "A material line exceeds the line budget."
                ))
                break
            }
            guard let separator = line.firstIndex(where: \.isWhitespace) else {
                let command = line.lowercased()
                if command.hasPrefix("map_") || namedTextureCommands.contains(command) {
                    issues.append(.init(
                        kind: .invalidTextureReference,
                        sourceRelativePath: sourceRelativePath,
                        role: .materialLibrary,
                        detail: "The texture map has no file path."
                    ))
                }
                continue
            }
            let command = String(line[..<separator]).lowercased()
            guard command.hasPrefix("map_") || namedTextureCommands.contains(command) else { continue }
            let rest = String(line[line.index(after: separator)...])
            let result = parseMapPath(rest)
            switch result {
            case .success(let path):
                references.append(.init(path: path))
            case .failure(.unsupportedOption(let option)):
                issues.append(.init(
                    kind: .unsupportedMapOption,
                    sourceRelativePath: sourceRelativePath,
                    role: .materialLibrary,
                    detail: "The texture map uses an unsupported option \(option)."
                ))
            case .failure(.malformed(let reason)):
                issues.append(.init(
                    kind: .invalidTextureReference,
                    sourceRelativePath: sourceRelativePath,
                    role: .materialLibrary,
                    detail: reason
                ))
            }
        }
        return .init(textureReferences: references, issues: issues)
    }

    static func parseMapPath(_ text: String) -> Result<String, FurnitureAssetMapParseError> {
        var scanner = MTLScanner(text: text)
        scanner.skipWhitespace()
        while !scanner.isAtEnd, scanner.peek() == "-" {
            guard let option = scanner.readToken() else {
                return .failure(.malformed("The texture map has an incomplete option."))
            }
            switch option.lowercased() {
            case "-blendu", "-blendv", "-boost", "-texres", "-bm", "-imfchan", "-type", "-clamp", "-halo":
                guard scanner.skipOperands(1) else {
                    return .failure(.malformed("The texture map option \(option) has no value."))
                }
            case "-mm":
                guard scanner.skipOperands(2) else {
                    return .failure(.malformed("The texture map option -mm needs two values."))
                }
            case "-o", "-s", "-t":
                guard scanner.skipNumericOperands(maximum: 3) else {
                    return .failure(.malformed("The texture map option \(option) needs numeric values."))
                }
            default:
                return .failure(.unsupportedOption(option))
            }
            scanner.skipWhitespace()
        }

        scanner.skipWhitespace()
        guard !scanner.isAtEnd else {
            return .failure(.malformed("The texture map has no file path."))
        }
        let path: String
        if scanner.peek() == "\"" || scanner.peek() == "'" {
            guard let quoted = scanner.readQuoted() else {
                return .failure(.malformed("The texture map has an unterminated quoted path."))
            }
            scanner.skipWhitespace()
            guard scanner.isAtEnd else {
                return .failure(.malformed("The texture map has unexpected text after its quoted path."))
            }
            path = quoted
        } else {
            path = scanner.remaining().trimmingCharacters(in: .whitespaces)
        }
        guard !path.isEmpty else {
            return .failure(.malformed("The texture map has an empty file path."))
        }
        return .success(path)
    }
}

private struct MTLScanner {
    let text: String
    var index: String.Index

    init(text: String) {
        self.text = text
        self.index = text.startIndex
    }

    var isAtEnd: Bool { index == text.endIndex }

    func peek() -> Character? {
        isAtEnd ? nil : text[index]
    }

    mutating func skipWhitespace() {
        while !isAtEnd, text[index].isWhitespace {
            index = text.index(after: index)
        }
    }

    mutating func readToken() -> String? {
        skipWhitespace()
        let start = index
        while !isAtEnd, !text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard start != index else { return nil }
        return String(text[start..<index])
    }

    mutating func readTokenOrQuoted() -> String? {
        skipWhitespace()
        guard !isAtEnd else { return nil }
        if text[index] == "\"" || text[index] == "'" {
            return readQuoted()
        }
        return readToken()
    }

    mutating func readQuoted() -> String? {
        guard !isAtEnd, text[index] == "\"" || text[index] == "'" else { return nil }
        let quote = text[index]
        index = text.index(after: index)
        let start = index
        while !isAtEnd, text[index] != quote {
            index = text.index(after: index)
        }
        guard !isAtEnd else { return nil }
        let result = String(text[start..<index])
        index = text.index(after: index)
        return result
    }

    mutating func skipOperands(_ count: Int) -> Bool {
        for _ in 0..<count {
            guard readToken() != nil else { return false }
        }
        return true
    }

    mutating func skipNumericOperands(maximum: Int) -> Bool {
        var count = 0
        while count < maximum {
            skipWhitespace()
            guard let token = peekToken(), Double(token) != nil else { break }
            _ = readToken()
            count += 1
        }
        return count > 0
    }

    private mutating func peekToken() -> String? {
        let saved = index
        let token = readToken()
        index = saved
        return token
    }

    mutating func remaining() -> String {
        String(text[index...])
    }
}
