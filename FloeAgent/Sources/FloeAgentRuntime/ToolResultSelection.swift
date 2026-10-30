// FloeAgentRuntime — budget-aware tool-result selection for one provider
// request.
//
// Provider context is a real, finite resource: the system envelope, history,
// tool schemas, images and the reserved output all consume the SAME window as
// tool results. A fixed 2 KiB or 4 KiB result cap is therefore wrong in both
// directions: it hides complete evidence a large model could easily afford,
// and it still overflows a small model whose schemas and history already fill
// the window.
//
// This planner sizes the exact outgoing request pieces it is given (messages,
// rendered schemas, images, replay pairs and the output reservation) and then
// allocates the remaining bytes to pending tool results:
//
//  * when every complete result fits, every result is sent complete;
//  * otherwise the available budget is shared deterministically, small results
//    keep all of their bytes, and a large result keeps an explicit head/tail
//    excerpt with its stable capture ref, byte length and a `tools.readResult`
//    instruction (the captured bytes remain readable);
//  * a `tools.readResult` page is never partially cut: a page's own header
//    promises a `nextOffset`, so a second summary would make that cursor lie.
//    If it cannot fit, the request carries a ref-only pointer instead;
//  * when even a minimal pointer would not fit, the caller is told so and the
//    output is not invented.
//
// Everything here is pure value logic so it can be exercised without a
// provider, a model or a network.

import Foundation
import FloeModels
import FloeProviders

/// One pending tool result offered to the planner. `text` is the complete
/// post-redaction capture when retention has it; otherwise it is the bounded
/// model-visible summary and `retentionAvailable` is false.
public struct ToolResultSelectionInput: Sendable, Equatable {
    public var callID: String
    public var toolName: String
    public var text: String
    /// Deterministic `tr_...` reference, present only when the text is the
    /// retained capture (or a durable projection that can still be paged).
    public var ref: String?
    public var totalBytes: Int
    /// The retained capture was truncated at execution/retention time.
    public var captureTruncated: Bool
    /// The tool itself reported truncating its capture.
    public var executionReportedTruncation: Bool
    /// The complete output could not be retained; paging will not recover it.
    public var captureUnavailable: Bool
    /// This result is the page returned by `tools.readResult` itself.
    public var isPagingPage: Bool
    /// Model-visible only for this request, never pageable. An over-budget
    /// sensitive value is omitted whole rather than partially exposed.
    public var isSensitive: Bool
    /// A saved summary is not a byte prefix of its retained capture. Such a
    /// projection must start a read at zero rather than skip summary bytes.
    public var continuationOffset: Int?

    public init(
        callID: String,
        toolName: String,
        text: String,
        ref: String?,
        totalBytes: Int,
        captureTruncated: Bool = false,
        executionReportedTruncation: Bool = false,
        captureUnavailable: Bool = false,
        isPagingPage: Bool = false,
        isSensitive: Bool = false,
        continuationOffset: Int? = nil
    ) {
        self.callID = callID
        self.toolName = toolName
        self.text = text
        self.ref = ref
        self.totalBytes = max(0, totalBytes)
        self.captureTruncated = captureTruncated
        self.executionReportedTruncation = executionReportedTruncation
        self.captureUnavailable = captureUnavailable
        self.isPagingPage = isPagingPage
        self.isSensitive = isSensitive
        self.continuationOffset = continuationOffset.map { max(0, $0) }
    }
}

public struct ToolResultSelection: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var callID: String
        public var output: String
        public var sentBytes: Int
        public var totalBytes: Int
        /// The complete retented output was placed in the request.
        public var complete: Bool
        /// Only a pointer was placed (no excerpt at all).
        public var pointerOnly: Bool
        /// The model-visible text is an excerpt; `ref` pages the remainder.
        public var excerpted: Bool
        public var ref: String?
    }

    public var items: [Item]
    public var budgetBytes: Int
    public var requestedBytes: Int
    public var sentBytes: Int
    /// Every complete result fit.
    public var allComplete: Bool
}

public enum ToolResultPlanner {
    /// Smallest useful excerpt (excluding the marker). Below this a pointer is
    /// more honest than a few scattered bytes.
    static let minimumExcerptBytes = 384
    /// Per-result pointer overhead estimate (marker text + ids).
    static let pointerOverheadBytes = 160
    /// Excerpt marker overhead estimate.
    static let excerptMarkerOverheadBytes = 260

    public static func plan(
        inputs: [ToolResultSelectionInput],
        budgetBytes: Int
    ) -> ToolResultSelection {
        let budget = max(0, budgetBytes)
        let completeOutputs = inputs.map(completeText)
        let requested = completeOutputs.reduce(0) { $0 + $1.utf8.count }
        guard !inputs.isEmpty else {
            return ToolResultSelection(
                items: [], budgetBytes: budget, requestedBytes: 0, sentBytes: 0, allComplete: true
            )
        }
        // The complete request fits: never summarize anything.
        if requested <= budget {
            let items = inputs.enumerated().map { index, input in
                let output = completeOutputs[index]
                return ToolResultSelection.Item(
                    callID: input.callID,
                    output: output,
                    sentBytes: output.utf8.count,
                    totalBytes: input.totalBytes,
                    complete: true,
                    pointerOnly: false,
                    excerpted: false,
                    ref: input.ref
                )
            }
            return ToolResultSelection(
                items: items,
                budgetBytes: budget,
                requestedBytes: requested,
                sentBytes: requested,
                allComplete: true
            )
        }

        let count = inputs.count
        let reservedPointers = count * pointerOverheadBytes
        var remaining = max(0, budget - reservedPointers)
        var allocations = [Int](repeating: 0, count: count)
        var complete = [Bool](repeating: false, count: count)

        // First pass: a result that fits an equal share is sent complete and
        // the remainder returns to the shared pool. Iterating to a fixed point
        // is what lets several small results coexist with one large one.
        var pending = Array(inputs.indices)
        var changed = true
        while changed, !pending.isEmpty {
            changed = false
            let share = max(0, remaining / pending.count)
            var next: [Int] = []
            for index in pending {
                let size = completeOutputs[index].utf8.count
                if size <= share, size <= remaining {
                    allocations[index] = size
                    complete[index] = true
                    remaining -= size
                    changed = true
                } else {
                    next.append(index)
                }
            }
            pending = next
        }

        // Second pass: split what is left equally among the results that did
        // not fit. A small remainder still becomes a useful excerpt before it
        // degrades to a pointer.
        if !pending.isEmpty, remaining > 0 {
            let share = remaining / pending.count
            for index in pending {
                allocations[index] = min(inputs[index].text.utf8.count, share)
            }
        }

        var items: [ToolResultSelection.Item] = []
        items.reserveCapacity(count)
        var sent = 0
        for (index, input) in inputs.enumerated() {
            let total = max(input.totalBytes, input.text.utf8.count)
            if complete[index] {
                let output = completeOutputs[index]
                sent += output.utf8.count
                items.append(ToolResultSelection.Item(
                    callID: input.callID,
                    output: output,
                    sentBytes: output.utf8.count,
                    totalBytes: total,
                    complete: true,
                    pointerOnly: false,
                    excerpted: false,
                    ref: input.ref
                ))
                continue
            }
            // A paging page must never be re-summarized: its header already
            // reports the returned range and nextOffset. Only a ref-only
            // pointer is honest when the page itself does not fit.
            let allocation = allocations[index]
            if input.isSensitive {
                let omitted = "[ephemeral sensitive output omitted whole: \(total) bytes exceed this request's remaining budget; it is not persisted or pageable. Ask the user to narrow the request if the value is required.]"
                sent += omitted.utf8.count
                items.append(ToolResultSelection.Item(
                    callID: input.callID,
                    output: omitted,
                    sentBytes: omitted.utf8.count,
                    totalBytes: total,
                    complete: false,
                    pointerOnly: true,
                    excerpted: false,
                    ref: nil
                ))
                continue
            }
            if input.isPagingPage
                || allocation < minimumExcerptBytes + excerptMarkerOverheadBytes {
                let pointer = pointerText(for: input, totalBytes: total)
                sent += pointer.utf8.count
                items.append(ToolResultSelection.Item(
                    callID: input.callID,
                    output: pointer,
                    sentBytes: pointer.utf8.count,
                    totalBytes: total,
                    complete: false,
                    pointerOnly: true,
                    excerpted: false,
                    ref: input.ref
                ))
                continue
            }
            let excerpt = excerptText(for: input, allocation: allocation, totalBytes: total)
            sent += excerpt.utf8.count
            items.append(ToolResultSelection.Item(
                callID: input.callID,
                output: excerpt,
                sentBytes: excerpt.utf8.count,
                totalBytes: total,
                complete: false,
                pointerOnly: false,
                excerpted: true,
                ref: input.ref
            ))
        }
        return ToolResultSelection(
            items: items,
            budgetBytes: budget,
            requestedBytes: requested,
            sentBytes: sent,
            allComplete: false
        )
    }

    /// A window that fits the retained bytes must still be told when the
    /// producer/store discarded part of the original. Charge that notice to
    /// the same request budget; it is not part of the pageable capture.
    private static func completeText(_ input: ToolResultSelectionInput) -> String {
        guard !input.isPagingPage, !input.isSensitive else { return input.text }
        var notes: [String] = []
        if input.captureTruncated {
            notes.append("retention truncated: only the retained prefix is available")
        }
        if input.executionReportedTruncation {
            notes.append("the tool reported truncating its own output")
        }
        if input.captureUnavailable {
            notes.append("the complete output was not retained for paging")
        }
        guard !notes.isEmpty else { return input.text }
        if let ref = input.ref {
            notes.append("retained output ref=\(ref)")
        }
        return input.text + "\n[" + notes.joined(separator: "; ") + "]"
    }

    /// Deterministic head/tail excerpt. The marker states the exact original
    /// length, how many bytes are shown, the stable capture ref and the exact
    /// paging call shape, so the model can recover the rest instead of
    /// pretending the excerpt was complete.
    static func excerptText(
        for input: ToolResultSelectionInput,
        allocation: Int,
        totalBytes: Int
    ) -> String {
        let usable = max(0, allocation - excerptMarkerOverheadBytes)
        guard usable >= minimumExcerptBytes else {
            return pointerText(for: input, totalBytes: totalBytes)
        }
        // 60% head keeps headers, ids and early structure; 40% tail keeps
        // final status lines and the newest entries for append-style output.
        let headBytes = usable * 60 / 100
        let tailBytes = usable - headBytes
        let head = ToolResultCaptureStore.utf8Prefix(input.text, maxBytes: headBytes)
        let tail = suffix(input.text, maxBytes: tailBytes)
        let shown = head.utf8.count + tail.utf8.count
        var marker = "\n[tool output truncated for this request: showing \(shown) of \(totalBytes) bytes"
        if input.captureTruncated {
            marker += "; the retained capture itself was truncated at \(totalBytes) bytes"
        }
        if input.executionReportedTruncation {
            marker += "; the tool reported truncating its own output"
        }
        if input.captureUnavailable {
            marker += "; the complete output was NOT retained, so paging cannot recover more without re-running the tool (only if safe)"
        } else if let ref = input.ref {
            // The tail is from the end of the capture, not the bytes after
            // the head. Counting it in the cursor would skip unseen middle bytes.
            marker += "; retained output ref=\(ref); read it with tools.readResult {\"ref\":\"\(ref)\",\"offset\":\(input.continuationOffset ?? head.utf8.count)}"
        } else {
            marker += "; no capture ref is available for paging"
        }
        marker += "]\n"
        return head + marker + tail
    }

    static func pointerText(for input: ToolResultSelectionInput, totalBytes: Int) -> String {
        if input.isPagingPage {
            return "[tools.readResult page not repeated in this request: \(totalBytes) bytes exceed the remaining budget. Request a smaller length or a later offset.]"
        }
        var text = "[tool result not repeated in this request: \(totalBytes) bytes"
        if input.captureTruncated {
            text += "; retained capture truncated"
        }
        if input.executionReportedTruncation {
            text += "; the tool reported its own truncation"
        }
        if input.captureUnavailable {
            text += "; the complete output was not retained and cannot be paged"
        } else if let ref = input.ref {
            text += "; complete retained output ref=\(ref); read it with tools.readResult {\"ref\":\"\(ref)\"}"
        } else {
            text += "; no capture ref is available"
        }
        return text + "]"
    }

    private static func suffix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0, text.utf8.count > maxBytes else {
            return maxBytes > 0 ? text : ""
        }
        let view = text.utf8
        let start = view.index(view.endIndex, offsetBy: -maxBytes)
        var bytes = Array(view[start...])
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeFirst()
        }
        return ""
    }
}

/// Exact-ish sizing of one outgoing provider request. The token estimates use
/// the same conservative mixed-script heuristic as `ContextTokenEstimator`
/// (CJK scalars count as one token, other bytes at three per token) and include
/// every section that shares the model window. Provider-reported usage remains
/// the authoritative post-hoc measurement; this value decides only what fits
/// BEFORE dispatch and is never presented as exact billing usage.
public struct ProviderRequestSize: Sendable, Equatable {
    public var contextWindowTokens: Int
    public var reservedOutputTokens: Int
    public var messageTokens: Int
    public var schemaTokens: Int
    public var imageTokens: Int
    public var replayTokens: Int
    public var safetyMarginTokens: Int
    /// Window left for the current pending tool results after output reserve
    /// and every fixed section.
    public var availableToolResultTokens: Int
    public var toolResultBudgetBytes: Int
    /// True when fixed sections alone leave no room for a result pointer.
    public var toolResultsCannotFit: Bool
}

public enum ProviderRequestSizer {
    public static func measure(
        messages: [ProviderMessage],
        schemas: [ToolSchemaDescriptor],
        replayedToolPairs: [ReplayedToolPair] = [],
        contextWindowTokens: Int,
        reservedOutputTokens: Int,
        safetyMarginTokens: Int = 256
    ) -> ProviderRequestSize {
        let messageTokens = messages.reduce(0) { partial, message in
            partial + message.content.reduce(0) { count, part in
                switch part {
                case .text(let text):
                    return count + tokenEstimate(text)
                case .imageData:
                    // Provider image accounting is per image, not per base64
                    // byte; a conservative per-image allowance prevents a
                    // silent overflow from an unaccounted photo.
                    return count + 1_600
                case .imageURL:
                    return count + 1_600
                }
            } + (message.reasoningContent.map(tokenEstimate) ?? 0) + 4
        }
        let schemaTokens = schemas.reduce(0) { partial, schema in
            partial + tokenEstimate(schema.name)
                + tokenEstimate(schema.description)
                + tokenEstimate(schema.parametersJSON) + 8
        }
        let replayTokens = replayedToolPairs.reduce(0) { partial, pair in
            partial
                + tokenEstimate(pair.call.argumentsJSONString)
                + tokenEstimate(pair.result.outputSummary)
                + (pair.assistantReasoning.map(tokenEstimate) ?? 0)
                + 16
        }
        let window = max(1, contextWindowTokens)
        let reserve = max(0, reservedOutputTokens)
        let margin = max(0, safetyMarginTokens)
        let fixed = messageTokens + schemaTokens + replayTokens + reserve + margin
        let available = max(0, window - fixed)
        // Estimator inverse: tokens = (bytes + 2) / 3, so 3 bytes/token is
        // the matching byte ceiling for the same heuristic.
        let budgetBytes = max(0, available * 3)
        return ProviderRequestSize(
            contextWindowTokens: window,
            reservedOutputTokens: reserve,
            messageTokens: messageTokens,
            schemaTokens: schemaTokens,
            imageTokens: 0,
            replayTokens: replayTokens,
            safetyMarginTokens: margin,
            availableToolResultTokens: available,
            toolResultBudgetBytes: budgetBytes,
            toolResultsCannotFit: available <= 0
        )
    }

    static func tokenEstimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, (text.utf8.count + 2) / 3)
    }
}

private extension ToolCall {
    var argumentsJSONString: String {
        String(decoding: argumentsJSON, as: UTF8.self)
    }
}
