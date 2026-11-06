import Foundation
import FloeCanvasCore
import FloeCanvasIntegration

// MARK: - Variable frames
//
// Variables are typed and lexically scoped. The runtime maintains a chain
// of frames: run → composite instance (loop/batch/subgraph) → iteration.
// Resolution walks innermost-out; the first frame that holds a binding
// wins, so inner scopes shadow outer ones deterministically. Each frame
// carries the declarations of its owner, which is what type checking uses
// — never a global first-match by name.

public struct FlowVariableFrame: Sendable {
    /// The node that owns this frame (loop, batch, subgraph node) or nil
    /// for the run frame.
    public var ownerNodeID: UUID?
    /// Declarations whose owner is this frame's owner. Same-name
    /// declarations in inner frames shadow outer ones, possibly with a
    /// different type — that is legal and checked per frame.
    public var declarations: [FlowVariable]
    public var values: [String: FlowValue]

    public init(
        ownerNodeID: UUID? = nil,
        declarations: [FlowVariable] = [],
        values: [String: FlowValue] = [:]
    ) {
        self.ownerNodeID = ownerNodeID
        self.declarations = declarations
        self.values = values
    }

    public func declaration(of name: String) -> FlowVariable? {
        declarations.first(where: { $0.name == name })
    }
}

public enum FlowVariableError: Error, Hashable, Sendable {
    case undefinedVariable(String)
    case typeMismatch(variable: String, expected: FlowValueType, found: FlowValueType)
}

// MARK: - Operand evaluation

public enum FlowOperandError: Error, Hashable, Sendable {
    case nodeOutputUnavailable(nodeID: UUID, portName: String)
    case typeMismatch(String)
}

/// Pure operand/predicate evaluation against completed node outputs and the
/// variable frame chain. No I/O, no host calls — the same inputs always
/// produce the same value.
public enum FlowEvaluation {
    /// The effective runtime type used for compatibility checks: a `.json`
    /// payload is checked by its natural shape, and `.json` is also the
    /// wildcard declaration type that accepts any value.
    public static func naturalType(of value: FlowValue) -> FlowValueType {
        switch value {
        case .json(let json):
            switch json {
            case .null: return .json
            case .bool: return .bool
            case .number: return .number
            case .string: return .string
            case .array: return .list
            case .object: return .json
            }
        default:
            return value.valueType
        }
    }

    /// A declaration of `.json` accepts any value (wildcard). A null JSON
    /// payload is compatible with any declaration. Otherwise the natural
    /// runtime type must equal the declared type exactly.
    public static func isCompatible(_ value: FlowValue, with declared: FlowValueType) -> Bool {
        if declared == .json { return true }
        if case .json(.null) = value { return true }
        return naturalType(of: value) == declared
    }

    /// Projects a `.json` payload into a concrete port type where possible.
    /// Non-JSON values pass through unchanged; unconvertible payloads stay
    /// `.json` (deterministic, never a crash).
    public static func project(_ value: FlowValue, to type: FlowValueType) -> FlowValue {
        guard case .json(let payload) = value, type != .json else { return value }
        guard let converted = try? FlowLiterals.value(payload, as: type) else { return value }
        return converted
    }

    /// Strict edge compatibility. `.json` is the wildcard/projection type:
    /// it is compatible with any port and is projected at runtime. The
    /// P0 validator waives type checks when a variadic port is involved;
    /// this rule set is the real check the strict compiler enforces:
    ///
    /// - normal → normal: same type, or either side `.json`.
    /// - normal(T) → variadic-input(E): per-element check T→E; the input
    ///   aggregates one item per edge into a `.list`.
    /// - variadic-output(T) → variadic-input(E): element-wise T→E; the
    ///   runtime flattens the produced list into the target's items.
    /// - variadic-output(T) → normal(D): the delivered value is a `.list`,
    ///   so D must be `.list` or `.json`.
    public static func edgeCompatible(
        source: FlowValueType,
        sourceVariadic: Bool,
        destination: FlowValueType,
        destinationVariadic: Bool
    ) -> Bool {
        if sourceVariadic && destinationVariadic {
            return elementCompatible(source, destination)
        }
        if sourceVariadic {
            // Delivered value is a list of `source`.
            return destination == .list || destination == .json
        }
        if destinationVariadic {
            return elementCompatible(source, destination)
        }
        return source == destination || source == .json || destination == .json
    }

    static func elementCompatible(_ source: FlowValueType, _ element: FlowValueType) -> Bool {
        source == element || source == .json || element == .json
    }

    public static func resolve(
        _ operand: FlowOperand,
        variables: [FlowVariableFrame],
        nodeOutputs: [UUID: [String: FlowValue]],
        graphVariables: [FlowVariable]
    ) throws -> FlowValue {
        switch operand {
        case .literal(let value):
            return value
        case .variable(let name):
            // Innermost frame with a binding wins; the declaration used for
            // the type check is the first one found walking outward from
            // the HIT frame (lexical chain), never a global name match.
            for index in stride(from: variables.count - 1, through: 0, by: -1) {
                let frame = variables[index]
                guard let value = frame.values[name] else { continue }
                let declaration = lexicalDeclaration(of: name, from: index, in: variables)
                    ?? graphVariables.first(where: { $0.name == name })
                if let declaration {
                    guard isCompatible(value, with: declaration.dataType) else {
                        throw FlowVariableError.typeMismatch(
                            variable: name,
                            expected: declaration.dataType,
                            found: value.valueType)
                    }
                }
                return value
            }
            throw FlowVariableError.undefinedVariable(name)
        case .nodeOutput(let nodeID, let portName):
            guard let value = nodeOutputs[nodeID]?[portName] else {
                throw FlowOperandError.nodeOutputUnavailable(nodeID: nodeID, portName: portName)
            }
            return value
        }
    }

    static func lexicalDeclaration(
        of name: String,
        from index: Int,
        in frames: [FlowVariableFrame]
    ) -> FlowVariable? {
        var cursor = index
        while cursor >= 0 {
            if let declaration = frames[cursor].declaration(of: name) {
                return declaration
            }
            cursor -= 1
        }
        return nil
    }

    public static func evaluate(
        _ predicate: FlowPredicate,
        variables: [FlowVariableFrame],
        nodeOutputs: [UUID: [String: FlowValue]],
        graphVariables: [FlowVariable]
    ) throws -> Bool {
        switch predicate {
        case .and(let predicates):
            for predicate in predicates
            where try !evaluate(predicate, variables: variables, nodeOutputs: nodeOutputs, graphVariables: graphVariables) {
                return false
            }
            return true
        case .or(let predicates):
            for predicate in predicates
            where try evaluate(predicate, variables: variables, nodeOutputs: nodeOutputs, graphVariables: graphVariables) {
                return true
            }
            return false
        case .not(let predicate):
            return try !evaluate(predicate, variables: variables, nodeOutputs: nodeOutputs, graphVariables: graphVariables)
        case .comparison(let comparator, let lhs, let rhs):
            // Unary comparators resolve only the operand they need; a
            // placeholder rhs must never fail evaluation.
            switch comparator {
            case .isEmpty:
                let left = try resolve(lhs, variables: variables, nodeOutputs: nodeOutputs, graphVariables: graphVariables)
                return try compare(comparator, left: left, right: nil)
            default:
                let left = try resolve(lhs, variables: variables, nodeOutputs: nodeOutputs, graphVariables: graphVariables)
                let right = try resolve(rhs, variables: variables, nodeOutputs: nodeOutputs, graphVariables: graphVariables)
                return try compare(comparator, left: left, right: right)
            }
        }
    }

    static func compare(
        _ comparator: FlowPredicate.Comparator,
        left: FlowValue,
        right: FlowValue?
    ) throws -> Bool {
        switch comparator {
        case .equal:
            guard let right else { throw FlowOperandError.typeMismatch("equal requires two operands") }
            guard naturalType(of: left) == naturalType(of: right) else { return false }
            return left == right
        case .notEqual:
            guard let right else { throw FlowOperandError.typeMismatch("notEqual requires two operands") }
            guard naturalType(of: left) == naturalType(of: right) else { return true }
            return left != right
        case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
            guard let right else {
                throw FlowOperandError.typeMismatch("\(comparator.rawValue) requires two operands")
            }
            guard case .number(let l) = left, case .number(let r) = right else {
                throw FlowOperandError.typeMismatch(
                    "\(comparator.rawValue) requires number operands, got \(left.valueType.rawValue) and \(right.valueType.rawValue)")
            }
            switch comparator {
            case .lessThan: return l < r
            case .lessThanOrEqual: return l <= r
            case .greaterThan: return l > r
            case .greaterThanOrEqual: return l >= r
            default: preconditionFailure("handled above")
            }
        case .contains:
            guard let right else {
                throw FlowOperandError.typeMismatch("contains requires two operands")
            }
            switch (left, right) {
            case (.string(let haystack), .string(let needle)):
                return haystack.contains(needle)
            case (.list(let items), _):
                return items.contains(right)
            default:
                throw FlowOperandError.typeMismatch(
                    "contains requires string⊇string or list∋value, got \(left.valueType.rawValue) and \(right.valueType.rawValue)")
            }
        case .isEmpty:
            switch left {
            case .string(let string): return string.isEmpty
            case .list(let items): return items.isEmpty
            case .table(_, let rows): return rows.isEmpty
            default:
                throw FlowOperandError.typeMismatch(
                    "isEmpty requires string/list/table, got \(left.valueType.rawValue)")
            }
        case .matchesRegex:
            guard let right else {
                throw FlowOperandError.typeMismatch("matchesRegex requires two operands")
            }
            guard case .string(let pattern) = right, case .string(let value) = left else {
                throw FlowOperandError.typeMismatch(
                    "matchesRegex requires string operands, got \(left.valueType.rawValue) and \(right.valueType.rawValue)")
            }
            return value.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
