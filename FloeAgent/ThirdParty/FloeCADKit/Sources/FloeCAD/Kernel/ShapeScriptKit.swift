//
//  ShapeScriptKit.swift
//  FloeCADKit
//
//  Headless evaluation of ShapeScript (MIT; pinned revision cda3024, 1.11.6)
//  into a FloeCAD `RenderMesh`. ShapeScript is a pure geometry description
//  language: evaluating a program produces a triangle scene, nothing else.
//  No native code is loaded, no network is used, and every file access an
//  `import`/`texture`/font statement could attempt is refused by the
//  evaluation delegate and its URL sandbox (below).
//
//  Units: ShapeScript's spatial units are arbitrary and scale-free; this
//  bridge maps them 1:1 onto FloeCAD millimetres (1 ShapeScript unit = 1 mm).
//  Scripts that want centimetres can emit their own `scale`.
//
//  Bounds (all enforced here, not by the interpreter):
//   * `maxSourceBytes`  — source size gate before parsing.
//   * `maxWallClockSeconds` — wall-clock deadline checked by `isCancelled`
//     inside the interpreter's loops, mesh build, CSG and triangulation.
//     ShapeScript swallows its cancellation error and returns a partial
//     scene, so this bridge re-checks the clock after every stage.
//   * `maxTriangles` — triangle cap after evaluation.
//
//  Honest limitation: Swift cannot catch a stack overflow. ShapeScript itself
//  caps call recursion (`maxCallDepth` = 1024 in the 1.11.6 interpreter) and
//  validates nesting depth at parse time, but a pathological case that still
//  exhausts the stack terminates the process rather than returning an error.
//

import Foundation
import ShapeScript

// MARK: - Public limits / outcome

public nonisolated struct ShapeScriptLimits: Sendable {
    public var maxSourceBytes: Int = 64 * 1024
    public var maxWallClockSeconds: Double = 10
    public var maxTriangles: Int = 200_000

    public init() {}
}

/// Result of one evaluation. Exactly one of `mesh` / `errorCode` is set.
/// `errorLine` (1-based) and the line/column suffix in `errorMessage` refer to
/// the source the caller handed to `evaluate`; `CADScriptService` uses the
/// internal `lineOffset` variant so a parameter prelude is not counted.
///
/// `mesh` is module-internal because `RenderMesh` is a kernel type below the
/// public facade (see `FloeCADDocument.swift`); external callers consume
/// geometry through `CADScriptService`/`CADMeshService` instead.
public nonisolated struct ShapeScriptOutcome: Sendable {
    var mesh: RenderMesh?
    public var polygonCount: Int
    public var triangleCount: Int
    /// parse_error | runtime_error | limit_source | limit_time |
    /// limit_geometry | empty_geometry
    public var errorCode: String?
    public var errorMessage: String?
    public var errorLine: Int?

    init(mesh: RenderMesh? = nil,
         polygonCount: Int = 0,
         triangleCount: Int = 0,
         errorCode: String? = nil,
         errorMessage: String? = nil,
         errorLine: Int? = nil) {
        self.mesh = mesh
        self.polygonCount = polygonCount
        self.triangleCount = triangleCount
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.errorLine = errorLine
    }
}

// MARK: - Evaluator

public nonisolated enum ShapeScriptKit {

    public static func evaluate(source: String,
                                limits: ShapeScriptLimits = .init()) -> ShapeScriptOutcome {
        evaluate(source: source, limits: limits, lineOffset: 0)
    }

    /// `lineOffset` lets a caller that prepends generated lines (the parameter
    /// prelude in `CADScriptService`) report error locations in the user's
    /// source rather than in the composed text. `externalCancellation` folds a
    /// caller-side cancellation (tool cancel / task cancellation) into the
    /// same interpreter-visible stop flag as the wall-clock deadline.
    static func evaluate(source: String,
                         limits: ShapeScriptLimits,
                         lineOffset: Int,
                         externalCancellation: @escaping @Sendable () -> Bool = { false }) -> ShapeScriptOutcome {
        let sourceBytes = source.utf8.count
        guard sourceBytes <= limits.maxSourceBytes else {
            return ShapeScriptOutcome(
                errorCode: "limit_source",
                errorMessage: "Source is \(sourceBytes) bytes; the limit is \(limits.maxSourceBytes).")
        }

        let clock = EvaluationDeadlineClock(seconds: limits.maxWallClockSeconds)
        // Imports (models, .shape files, textures, fonts) resolve through the
        // delegate URL holster inside a random, never-created directory. The
        // interpreter's own file checks then fail, so no host file can be
        // read no matter what path the script names. Nothing is created on
        // disk, so there is nothing to clean up.
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("floecad-shapescript-\(UUID().uuidString)", isDirectory: true)
        let delegate = RefusingShapeScriptDelegate(sandbox: sandbox)
        let isCancelled: @Sendable () -> Bool = { clock.isExpired() || externalCancellation() }

        func stopped() -> Bool {
            clock.expired || externalCancellation()
        }

        func limitTime() -> ShapeScriptOutcome {
            if externalCancellation() && !clock.expired {
                return ShapeScriptOutcome(errorCode: "cancelled",
                                          errorMessage: "Evaluation was cancelled.")
            }
            return ShapeScriptOutcome(
                errorCode: "limit_time",
                errorMessage: "Evaluation exceeded the \(limits.maxWallClockSeconds)-second wall-clock limit.")
        }

        do {
            let program = try ShapeScript.parse(source)
            let scene = try ShapeScript.evaluate(program,
                                                 delegate: delegate,
                                                 isCancelled: isCancelled)
            // The interpreter catches its own cancellation and returns a
            // partial scene, so the clock is the authority here.
            guard !stopped() else { return limitTime() }
            guard scene.build(isCancelled) else { return limitTime() }
            guard !stopped() else { return limitTime() }

            let geometry = scene.visibleGeometry
            guard geometry.hasMesh else {
                return ShapeScriptOutcome(
                    errorCode: "empty_geometry",
                    errorMessage: "The script produced no solid mesh (only paths, cameras or lights).")
            }

            let mesh = geometry.merged(isCancelled)
            guard !stopped() else { return limitTime() }
            let polygonCount = mesh.polygons.count
            guard polygonCount > 0 else {
                return ShapeScriptOutcome(
                    errorCode: "empty_geometry",
                    errorMessage: "The script's visible geometry is empty.")
            }

            let triangleCount = geometry.triangles(isCancelled).count
            guard !stopped() else { return limitTime() }
            guard triangleCount <= limits.maxTriangles else {
                return ShapeScriptOutcome(
                    polygonCount: polygonCount,
                    triangleCount: triangleCount,
                    errorCode: "limit_geometry",
                    errorMessage: "The script produced \(triangleCount) triangles; the limit is \(limits.maxTriangles).")
            }

            let render = EuclidBridge.renderMesh(from: mesh)
            guard !render.indices.isEmpty else {
                return ShapeScriptOutcome(
                    errorCode: "empty_geometry",
                    errorMessage: "The script's visible geometry carries no triangles.")
            }
            return ShapeScriptOutcome(mesh: render,
                                      polygonCount: polygonCount,
                                      triangleCount: triangleCount)
        } catch {
            if stopped() { return limitTime() }
            return mapError(error, source: source, lineOffset: lineOffset)
        }
    }

    // MARK: Error mapping

    private static func mapError(_ error: Error,
                                 source: String,
                                 lineOffset: Int) -> ShapeScriptOutcome {
        let programError = ProgramError(error)
        let code: String
        switch programError {
        case .lexerError, .parserError:
            code = "parse_error"
        case .runtimeError, .unknownError:
            code = "runtime_error"
        }

        var message = programError.message
        if let hint = programError.hint, !hint.isEmpty {
            message += " — \(hint)"
        }
        var line: Int?
        if let range = programError.range,
           let location = lineAndColumn(of: range, in: source) {
            let reported = (lineOffset > 0 && location.line > lineOffset)
                ? location.line - lineOffset
                : location.line
            line = reported
            message += " (line \(reported), column \(location.column))"
        }
        return ShapeScriptOutcome(errorCode: code, errorMessage: message, errorLine: line)
    }

    /// `SourceRange` is `Range<String.Index>`; ShapeScript's own
    /// `lineAndColumn` helper is internal, so this computes it here.
    private static func lineAndColumn(of range: Range<String.Index>,
                                      in source: String) -> (line: Int, column: Int)? {
        let lower = range.lowerBound
        guard lower >= source.startIndex, lower <= source.endIndex else { return nil }
        var line = 1
        var column = 1
        for character in source[source.startIndex..<lower] {
            if character.isNewline {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return (line, column)
    }
}

// MARK: - Refusing delegate

/// `resolveURL` holsters every requested path inside an empty, never-created
/// sandbox directory; `importGeometry` returns nil (the protocol's refusal
/// default). The interpreter's own file-existence/readability checks then
/// fail for `.shape`, model, image and font imports alike — no host file is
/// ever opened. `texture`/`import` produce a normal runtime error instead.
private nonisolated final class RefusingShapeScriptDelegate: EvaluationDelegate {
    let sandbox: URL

    init(sandbox: URL) { self.sandbox = sandbox }

    func resolveURL(for path: String) -> URL {
        let raw = (path as NSString).lastPathComponent
        let name = (raw.isEmpty || raw == "." || raw == "..") ? "__refused__" : raw
        return sandbox.appendingPathComponent(name)
    }

    func importGeometry(for _: URL) throws -> Geometry? {
        nil
    }

    func debugLog(_: [AnyHashable]) {}
}

// MARK: - Deadline

/// Wall-clock deadline shared by the ShapeScript interpreter callbacks and the
/// mesh services. `@unchecked Sendable`: all state is lock-guarded, and the
/// deadline is monotonically used by a single evaluator at a time.
nonisolated final class EvaluationDeadlineClock: @unchecked Sendable {
    private let deadline: Date
    private let lock = NSLock()
    private var didExpire = false

    init(seconds: Double) {
        deadline = Date().addingTimeInterval(max(seconds, 0))
    }

    func isExpired() -> Bool {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        if now >= deadline {
            didExpire = true
        }
        return didExpire
    }

    /// True once the deadline passed, even if `isExpired()` was never called
    /// at the moment it passed (used after each evaluation stage).
    var expired: Bool {
        lock.lock()
        defer { lock.unlock() }
        if Date() >= deadline {
            didExpire = true
        }
        return didExpire
    }
}
