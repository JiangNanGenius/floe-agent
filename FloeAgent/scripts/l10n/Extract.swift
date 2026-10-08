// FloeL10n — extract string literals containing CJK and classify each by
// syntactic context. Emits JSON for the migration pipeline.
// Build: see scripts/l10n/build.sh

import Foundation
import SwiftSyntax
import SwiftParser

/// Decodes Swift string-literal escape sequences so catalog values hold the
/// real characters (newline/tab/quote/backslash), matching what the app
/// actually displays. Only standard escapes are handled; unknown sequences
/// are preserved verbatim.
func decodeSwiftEscapes(_ s: String) -> String {
    var out = ""
    let scalars = Array(s)
    var i = 0
    while i < scalars.count {
        let c = scalars[i]
        guard c == "\\", i + 1 < scalars.count else { out.append(c); i += 1; continue }
        let n = scalars[i + 1]
        switch n {
        case "n": out.append("\n"); i += 2
        case "t": out.append("\t"); i += 2
        case "r": out.append("\r"); i += 2
        case "\"": out.append("\""); i += 2
        case "'": out.append("'"); i += 2
        case "\\": out.append("\\"); i += 2
        case "0": out.append("\0"); i += 2
        case "u":
            // \u{XXXX}
            guard i + 2 < scalars.count, scalars[i + 2] == "{" else {
                out.append(c); i += 1; continue
            }
            var j = i + 3
            var hex = ""
            while j < scalars.count, scalars[j] != "}" {
                hex.append(scalars[j]); j += 1
            }
            if j < scalars.count, let v = UInt32(hex, radix: 16),
               let scalar = Unicode.Scalar(v) {
                out.append(Character(scalar)); i = j + 1
            } else {
                out.append(c); i += 1
            }
        default:
            out.append(c); i += 1
        }
    }
    return out
}

struct Occurrence: Encodable {
    let file: String
    let line: Int
    let column: Int
    let endLine: Int
    let endColumn: Int
    let offset: Int
    let length: Int
    let text: String          // literal text with interpolations blanked
    let interpolated: Bool
    let segments: [Segment]
    let callName: String?     // enclosing function call, e.g. Text
    let bareCallName: String? // final identifier of a member call, e.g. alert
    let argLabel: String?     // argument label in that call
    let argPosition: Int?
    let declName: String?     // enclosing function/computed property
    let assignmentTarget: String?
    let inDebugConfig: Bool
    let kind: String          // classification
}

struct Segment: Encodable {
    let kind: String          // "text" | "expr"
    let value: String
}

final class LiteralVisitor: SyntaxAnyVisitor {
    let file: String
    let converter: SourceLocationConverter
    var results: [Occurrence] = []

    init(file: String, tree: SourceFileSyntax) {
        self.file = file
        self.converter = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
        self.walk(tree)
    }

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        var segs: [Segment] = []
        var hasCJK = false
        for segment in node.segments {
            switch segment {
            case .stringSegment(let s):
                let t = decodeSwiftEscapes(s.content.text)
                segs.append(Segment(kind: "text", value: t))
                if t.range(of: "\\p{Han}", options: .regularExpression) != nil { hasCJK = true }
            case .expressionSegment(let e):
                let expr = e.expressions.map { $0.expression.trimmedDescription }.joined(separator: ", ")
                segs.append(Segment(kind: "expr", value: expr))
            @unknown default:
                break
            }
        }
        guard hasCJK else { return .visitChildren }

        let interpolated = segs.contains { $0.kind == "expr" }
        let text = segs.map { $0.kind == "text" ? $0.value : "" }.joined()

        var parent: Syntax? = node.parent
        var callName: String?
        var labeledExpr: LabeledExprSyntax?
        var assignmentTarget: String?
        var stop = false
        while let p = parent, !stop {
            if let le = p.as(LabeledExprSyntax.self),
               let list = le.parent?.as(LabeledExprListSyntax.self),
               let call = list.parent?.as(FunctionCallExprSyntax.self) {
                labeledExpr = le
                callName = call.calledExpression.trimmedDescription
                stop = true
                break
            }
            if let assign = p.as(InfixOperatorExprSyntax.self),
               assign.operator.trimmedDescription == "=" {
                assignmentTarget = assign.leftmostExpr?.trimmedDescription
                stop = true
                break
            }
            // Stop once we leave an argument expression into statements.
            if p.is(CodeBlockItemSyntax.self) || p.is(ReturnStmtSyntax.self) ||
                p.is(SwitchCaseItemSyntax.self) || p.is(InitializerClauseSyntax.self) {
                stop = true
                break
            }
            parent = p.parent
        }
        if assignmentTarget == nil,
           let assign = node.parent?.as(InfixOperatorExprSyntax.self),
           assign.operator.trimmedDescription == "=" {
            assignmentTarget = assign.leftmostExpr?.trimmedDescription
        }

        var bareCallName: String?
        if let call = callName {
            if let match = call.range(of: #"\.([A-Za-z_][A-Za-z0-9_]*)\s*$"#,
                                      options: .regularExpression) {
                bareCallName = String(call[match])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            } else {
                bareCallName = call
            }
        }

        var argLabel: String?
        var argPosition: Int?
        if let le = labeledExpr {
            argLabel = le.label?.text
            if let list = le.parent?.as(LabeledExprListSyntax.self) {
                var pos = 0
                for item in list {
                    if item == le { break }
                    pos += 1
                }
                argPosition = pos
            }
        }

        let decl = node.enclosingDeclName()
        let inDebug = node.isInsideDebugConfig()
        let kind = classify(
            interpolated: interpolated, callName: callName, argLabel: argLabel,
            argPosition: argPosition, declName: decl, assignmentTarget: assignmentTarget
        )

        let start = node.startLocation(converter: converter)
        let end = node.endLocation(converter: converter)
        results.append(Occurrence(
            file: file, line: start.line, column: start.column,
            endLine: end.line, endColumn: end.column,
            offset: start.offset, length: end.offset - start.offset,
            text: text, interpolated: interpolated, segments: segs,
            callName: callName, bareCallName: bareCallName,
            argLabel: argLabel, argPosition: argPosition,
            declName: decl, assignmentTarget: assignmentTarget,
            inDebugConfig: inDebug, kind: kind
        ))
        return .visitChildren
    }
}

extension StringLiteralExprSyntax {
    func nearestLabeledExpr(within call: FunctionCallExprSyntax) -> LabeledExprSyntax? {
        var p: Syntax? = Syntax(self)
        while let node = p, node != Syntax(call) {
            if let le = node.as(LabeledExprSyntax.self) { return le }
            p = node.parent
        }
        return nil
    }

    func enclosingDeclName() -> String? {
        var p: Syntax? = self.parent
        while let node = p {
            if let fn = node.as(FunctionDeclSyntax.self) { return fn.name.text }
            if let v = node.as(VariableDeclSyntax.self), let b = v.bindings.first {
                return b.pattern.trimmedDescription
            }
            if let en = node.as(EnumCaseDeclSyntax.self) { return "enumCase" }
            p = node.parent
        }
        return nil
    }

    func isInsideDebugConfig() -> Bool {
        var p: Syntax? = self.parent
        while let node = p {
            if let clause = node.as(IfConfigClauseSyntax.self),
               clause.condition?.description.contains("DEBUG") == true {
                return true
            }
            p = node.parent
        }
        return false
    }
}

extension InfixOperatorExprSyntax {
    var leftmostExpr: ExprSyntax? {
        if let infix = leftOperand.as(InfixOperatorExprSyntax.self) { return infix.leftmostExpr }
        return leftOperand
    }
}

// MARK: - Classification

let swiftUILocalizingCalls: Set<String> = [
    "Text", "Label", "Button", "Menu", "Link", "Section", "Picker", "Toggle",
    "TextField", "SecureField", "NavigationLink", "ContentUnavailableView",
    "ProgressView", "GroupBox", "LabeledContent", "ShareLink", "Help"
]

let swiftUILocalizingMethods: Set<String> = [
    "navigationTitle", "navigationSubtitle", "alert", "confirmationDialog",
    "help", "accessibilityLabel", "accessibilityHint", "searchable",
    "tabItem", "status", "label", "prompt"
]

let userFacingLabels: Set<String> = [
    "title", "message", "subtitle", "label", "placeholder", "prompt", "text",
    "reason", "header", "footer", "hint", "help", "summary",
    "emptyContent", "cancel", "confirm", "action", "name", "body",
    "accessibilityLabel", "accessibilityHint", "shortTitle", "localizedTitle",
    "displayName", "providerMessage", "statusText", "headline"
]

let userFacingAssignSuffixes: [String] = [
    ".title", ".body", ".subtitle", ".alertTitle", ".alertMessage"
]

let userFacingDeclNames: Set<String> = [
    "errorDescription", "failureReason", "recoverySuggestion", "helpAnchor",
    "localizedTitle", "localizedDescription", "approvalModeTitle", "explanation",
    "title", "subtitle", "placeholder", "label", "providerMessage", "displayName",
    "sendAccessibilityLabel", "accessibilityLabel"
]

let loggingCalls: Set<String> = [
    "FloeLogger", "logger", "os_log", "print", "debugPrint", "NSLog",
    "assertionFailure", "preconditionFailure", "fatalError", "XCTAssert",
    "Issue.record"
]

func classify(
    interpolated: Bool, callName: String?, argLabel: String?, argPosition: Int?,
    declName: String?, assignmentTarget: String?
) -> String {
    if let call = callName {
        // Member calls arrive as `<base>.method` where base may itself be a
        // large expression; the localizing method is the final identifier.
        let bare: String
        if let match = call.range(of: #"\.([A-Za-z_][A-Za-z0-9_]*)\s*$"#,
                                  options: .regularExpression) {
            bare = String(call[match]).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        } else {
            bare = call
        }
        if loggingCalls.contains(bare) || loggingCalls.contains(call) {
            return "skip_log"
        }
        if swiftUILocalizingCalls.contains(bare) {
            if bare == "Text" || (argPosition == 0 && argLabel == nil) ||
               (argLabel.map({ userFacingLabels.contains($0) }) == true) {
                return interpolated ? "swiftui_interp" : "swiftui_keyed"
            }
        }
        if swiftUILocalizingMethods.contains(bare) {
            if (argPosition == 0 && argLabel == nil) ||
               (argLabel.map({ ["title", "message", "prompt", "text", "label", "placeholder", "headline"].contains($0) }) == true) {
                return interpolated ? "swiftui_interp" : "swiftui_keyed"
            }
        }
        if let label = argLabel, userFacingLabels.contains(label) {
            return interpolated ? "plain_interp" : "plain_string"
        }
        if argPosition == 0 && argLabel == nil {
            return "review_callarg"
        }
        return "review_labeled"
    }
    if let target = assignmentTarget,
       userFacingAssignSuffixes.contains(where: { target.hasSuffix($0) }) {
        return interpolated ? "plain_interp" : "plain_string"
    }
    if let decl = declName, userFacingDeclNames.contains(decl) {
        return interpolated ? "plain_interp" : "plain_string"
    }
    return "review"
}

// MARK: - Driver

@main
enum Driver {
static func main() throws {
let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: l10n-extract <files...>\n".data(using: .utf8)!)
    exit(2)
}

var all: [Occurrence] = []
for path in args.dropFirst() {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
        continue
    }
    let tree = Parser.parse(source: source)
    all.append(contentsOf: LiteralVisitor(file: path, tree: tree).results)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
let data = try encoder.encode(all)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}
}
