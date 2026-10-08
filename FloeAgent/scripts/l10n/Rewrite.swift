// FloeL10n — AST rewriter.
//
// Reads an offset map (JSON): { "<utf8Offset>": {"key": "...", "mode":
// "keyed|lookup"} } and rewrites targeted string literals:
//   * non-interpolated, keyed   -> "dotted.key"   (LocalizedStringKey slot)
//   * non-interpolated, lookup  -> FloeL10n.l("dotted.key")
//   * interpolated (any context)-> FloeL10n.l("dotted.key", arg1, arg2)
// Interpolation expressions are recursively rewritten, so nested fallback
// literals such as `title ?? "文档"` or `["细","中","粗"][i]` are translated
// while the outer string becomes one format lookup (no byte-range overlap).
//
// usage: l10n-rewrite <offset-map.json> <file.swift>...   (files edited in place)

import Foundation
import SwiftSyntax
import SwiftParser
import SwiftSyntaxBuilder

struct Target { let key: String; let mode: String }

final class Rewrite: SyntaxRewriter {
    var targets: [Int: Target] = [:]
    let converterFile: String
    init(file: String) { self.converterFile = file; super.init() }

    override func visit(_ node: StringLiteralExprSyntax) -> ExprSyntax {
        // Only simple/regular string literals are catalog driven.
        let offset = node.positionAfterSkippingLeadingTrivia.utf8Offset
        guard let target = targets[offset] else {
            return ExprSyntax(super.visit(node))
        }

        // Carry the original literal's trailing trivia onto the replacement
        // so a following binary operator keeps symmetric whitespace
        // (`"...\n" + suffix`); otherwise `...) + suffix` can parse as
        // postfix when whitespace is only on the operator's right.
        let trailing = node.trailingTrivia
        let leading = node.leadingTrivia

        // Single non-interpolated string segment.
        let segs = node.segments
        let isInterpolated = segs.contains { if case .expressionSegment = $0 { return true } else { return false } }
        if !isInterpolated, case .stringSegment = segs.first, segs.count == 1 {
            if target.mode == "keyed" {
                var lit = makeStringLiteral(target.key)
                lit.leadingTrivia = leading
                lit.trailingTrivia = trailing
                return ExprSyntax(lit)
            }
            var call = makeLCall(key: target.key, args: [])
            call.leadingTrivia = leading
            call.trailingTrivia = trailing
            return ExprSyntax(call)
        }

        // Interpolated: collect expression segments in order and localize
        // any nested targeted literals inside them.
        var argExprs: [ExprSyntax] = []
        for segment in segs {
            if case .expressionSegment(let exprSeg) = segment {
                for labeled in exprSeg.expressions {
                    let rewritten = Self.rewriteExpressions(labeled.expression,
                                                             targets: targets)
                    argExprs.append(rewritten)
                }
            }
        }
        var call = makeLCall(key: target.key, args: argExprs)
        call.leadingTrivia = leading
        call.trailingTrivia = trailing
        return ExprSyntax(call)
    }


    /// Rewrites targeted string literals found anywhere inside an expression.
    static func rewriteExpressions(_ expr: ExprSyntax, targets: [Int: Target]) -> ExprSyntax {
        let r = ExprLiteralRewriter(targets: targets)
        return ExprSyntax(r.rewrite(Syntax(expr)))!
    }
}

/// Rewriter used only inside interpolation expressions. It localizes nested
/// literal occurrences but never an enclosing (already handled) format string.
final class ExprLiteralRewriter: SyntaxRewriter {
    let targets: [Int: Target]
    init(targets: [Int: Target]) { self.targets = targets; super.init() }

    override func visit(_ node: StringLiteralExprSyntax) -> ExprSyntax {
        let offset = node.positionAfterSkippingLeadingTrivia.utf8Offset
        guard let target = targets[offset] else { return ExprSyntax(super.visit(node)) }
        let segs = node.segments
        let isInterpolated = segs.contains { if case .expressionSegment = $0 { return true } else { return false } }
        if !isInterpolated, segs.count == 1 {
            // Nested fallback labels are value expressions.
            return ExprSyntax(makeLCall(key: target.key, args: []))
        }
        var argExprs: [ExprSyntax] = []
        for segment in segs {
            if case .expressionSegment(let exprSeg) = segment {
                for labeled in exprSeg.expressions {
                    let inner = ExprSyntax(ExprLiteralRewriter(targets: targets)
                        .rewrite(Syntax(labeled.expression)))!
                    argExprs.append(inner)
                }
            }
        }
        return ExprSyntax(makeLCall(key: target.key, args: argExprs))
    }
}

func makeStringLiteral(_ s: String) -> StringLiteralExprSyntax {
    StringLiteralExprSyntax(content: s)
}

/// Builds `FloeL10n.l("key", arg1, arg2)` by parsing source, avoiding
/// SwiftSyntaxBuilder API churn across toolchain versions.
func makeLCall(key: String, args: [ExprSyntax]) -> FunctionCallExprSyntax {
    let keyLiteral = key
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let src: String
    if args.isEmpty {
        src = "FloeL10n.l(\"\(keyLiteral)\")"
    } else {
        src = "FloeL10n.l(\"\(keyLiteral)\", "
            + args.map { $0.trimmedDescription }.joined(separator: ", ") + ")"
    }
    let parsed = Parser.parse(source: src)
    return parsed.statements.first!.item.cast(FunctionCallExprSyntax.self)
}

// MARK: - Driver

@main
enum Driver {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write("usage: l10n-rewrite <map.json> <files...>\n".data(using: .utf8)!)
            exit(2)
        }
        struct Item: Decodable { let key: String; let mode: String }
        let mapData = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let rawMap = try JSONDecoder().decode([String: Item].self, from: mapData)
        var targets: [Int: Target] = [:]
        for (k, v) in rawMap { targets[Int(k)!] = Target(key: v.key, mode: v.mode) }

        for path in args.dropFirst(2) {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            let tree = Parser.parse(source: source)
            let rewriter = Rewrite(file: path)
            rewriter.targets = targets
            let newTree = rewriter.rewrite(tree)
            let out = newTree.description
            if out != source {
                try out.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}
