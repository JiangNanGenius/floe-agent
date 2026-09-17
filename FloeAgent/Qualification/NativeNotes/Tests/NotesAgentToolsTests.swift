// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import FloeDocuments
import FloeNotes
import FloeTools
@testable import FloeNotesNativeQualification

/// Tool-level checks for `notes.read` pagination and `notes.edit` default
/// placement. These exercise the extracted pure helpers so multilingual byte
/// budgets, explicit continuation offsets, frame validation and slot selection
/// are verified without depending on the shared Application Support store.
final class NotesAgentToolsTests: XCTestCase {

    // MARK: - notes.read: multilingual byte bounds and recoverable text

    func testLargeMultilingualElementPreviewIsByteBoundedAndFullyRecoverable() throws {
        let text = String(repeating: "中文段落与 English 混合 text 🙂 ", count: 4_000)
        var document = NoteDocument(kind: .notebook, title: "长文")
        let element = NoteElement(frame: NoteRect(x: 40, y: 40, width: 600, height: 150), text: text, fontSize: 20)
        document.pages[0].elements = [element]
        let page = document.pages[0]

        let preview = NotesReadTool.pageDetail(document, page: page, index: 0, offset: 0, limit: 100,
                                               textOffset: 0, textLimit: 8_000, focusElement: nil)
        XCTAssertLessThanOrEqual(try encodedBytes(preview), NotesReadTool.maximumResponseBytes)
        let entry = try XCTUnwrap(preview.elements.first)
        XCTAssertEqual(entry.textCharacters, text.count)
        XCTAssertTrue(entry.textHasMore)
        XCTAssertEqual(entry.textOffset, 0)
        XCTAssertEqual(entry.textReturnedCharacters, entry.text.count)
        let nextOffset = try XCTUnwrap(entry.nextTextOffset)
        XCTAssertGreaterThan(nextOffset, 0)
        XCTAssertLessThanOrEqual(nextOffset, text.count)

        // The preview is not a dead end: continue with elementID + textOffset and
        // verify the whole text is recovered with no dropped or duplicated ranges.
        var collected = entry.text
        var offset = nextOffset
        var steps = 0
        while true {
            let next = NotesReadTool.pageDetail(document, page: page, index: 0, offset: 0, limit: 100,
                                                textOffset: offset, textLimit: 8_000, focusElement: element)
            XCTAssertLessThanOrEqual(try encodedBytes(next), NotesReadTool.maximumResponseBytes)
            let chunk = try XCTUnwrap(next.elements.first)
            XCTAssertEqual(chunk.textOffset, offset)
            collected += chunk.text
            guard let advance = chunk.nextTextOffset, advance > offset else { break }
            offset = advance
            steps += 1
            XCTAssertLessThan(steps, 10_000, "element pagination must make bounded progress")
        }
        XCTAssertEqual(collected, text)
    }

    func testElementPreviewsTruncateButReportContinuationOffsets() throws {
        // Many elements shrink the per-element byte pool; every truncated preview
        // still exposes the exact next character offset for that element.
        let payload = String(repeating: "语言片段🙂", count: 3_000)
        var document = NoteDocument(kind: .notebook, title: "多段")
        document.pages[0].elements = (0..<12).map { index in
            NoteElement(frame: NoteRect(x: 40, y: Double(40 + index * 70), width: 600, height: 60), text: payload)
        }
        let detail = NotesReadTool.pageDetail(document, page: document.pages[0], index: 0, offset: 0, limit: 100,
                                              textOffset: 0, textLimit: 20_000, focusElement: nil)
        XCTAssertLessThanOrEqual(try encodedBytes(detail), NotesReadTool.maximumResponseBytes)
        XCTAssertFalse(detail.elements.isEmpty)
        for element in detail.elements {
            XCTAssertEqual(element.textCharacters, payload.count)
            if element.textHasMore {
                XCTAssertGreaterThan(element.textReturnedCharacters, 0)
                XCTAssertEqual(element.nextTextOffset ?? -1, element.text.count)
            } else {
                XCTAssertNil(element.nextTextOffset)
                XCTAssertEqual(element.text, payload)
            }
        }
    }

    func testChinesePageTextChunksAreByteBoundedAndReconstructable() throws {
        // Reproduces the reported overflow: a large element pool plus extracted and
        // OCR chunks with textLimit 20,000 must still fit the byte transport.
        let extracted = String(repeating: "这是很长的中文提取文本🙂。\n", count: 3_000)
        let ocr = String(repeating: "这是中文 OCR 识别结果。\n", count: 4_000)
        var document = NoteDocument(kind: .notebook, title: "中文页")
        document.pages[0].elements = [
            NoteElement(frame: NoteRect(x: 40, y: 40, width: 600, height: 120),
                        text: String(repeating: "批注🙂", count: 4_000))
        ]
        document.pages[0].extractedText = extracted
        document.pages[0].ocrText = ocr
        let visualKey = document.pages[0].visualIndexKey
        document.pages[0].ocrSourceKey = visualKey
        let page = document.pages[0]

        let detail = NotesReadTool.pageDetail(document, page: page, index: 0, offset: 0, limit: 100,
                                              textOffset: 0, textLimit: 20_000, focusElement: nil)
        XCTAssertLessThanOrEqual(try encodedBytes(detail), NotesReadTool.maximumResponseBytes)
        let first = try XCTUnwrap(detail.extractedText)
        XCTAssertGreaterThan(first.returnedCharacters, 0)
        XCTAssertLessThanOrEqual(first.returnedCharacters, 20_000)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.nextOffset ?? -1, first.offset + first.returnedCharacters)

        var collected = first.text
        var offset = try XCTUnwrap(first.nextOffset)
        var steps = 0
        while true {
            let next = NotesReadTool.pageDetail(document, page: page, index: 0, offset: 0, limit: 100,
                                                textOffset: offset, textLimit: 20_000, focusElement: nil)
            XCTAssertLessThanOrEqual(try encodedBytes(next), NotesReadTool.maximumResponseBytes)
            let chunk = try XCTUnwrap(next.extractedText)
            XCTAssertEqual(chunk.offset, offset)
            collected += chunk.text
            guard let advance = chunk.nextOffset, advance > offset else { break }
            offset = advance
            steps += 1
            XCTAssertLessThan(steps, 10_000, "page text pagination must make bounded progress")
        }
        XCTAssertEqual(collected, extracted)
    }

    func testJSONEscapedCharactersStayWithinBudgetAndRemainRecoverable() throws {
        // Slash, quote, backslash and newline each encode to two JSON bytes, so a
        // raw UTF-8 byte count would under-estimate the transport payload.
        let text = String(repeating: "\n\"\\/", count: 30_000)
        var document = NoteDocument(kind: .notebook, title: "转义")
        let element = NoteElement(frame: NoteRect(x: 40, y: 40, width: 600, height: 120), text: text)
        document.pages[0].elements = [element]
        let page = document.pages[0]

        let preview = NotesReadTool.pageDetail(document, page: page, index: 0, offset: 0, limit: 100,
                                               textOffset: 0, textLimit: 20_000, focusElement: nil)
        XCTAssertLessThanOrEqual(try encodedBytes(preview), NotesReadTool.maximumResponseBytes)
        let entry = try XCTUnwrap(preview.elements.first)
        XCTAssertTrue(entry.textHasMore)
        XCTAssertGreaterThan(entry.textReturnedCharacters, 0)

        var collected = entry.text
        var offset = try XCTUnwrap(entry.nextTextOffset)
        var steps = 0
        while true {
            let next = NotesReadTool.pageDetail(document, page: page, index: 0, offset: 0, limit: 100,
                                                textOffset: offset, textLimit: 20_000, focusElement: element)
            XCTAssertLessThanOrEqual(try encodedBytes(next), NotesReadTool.maximumResponseBytes)
            let chunk = try XCTUnwrap(next.elements.first)
            XCTAssertEqual(chunk.textOffset, offset)
            collected += chunk.text
            guard let advance = chunk.nextTextOffset, advance > offset else { break }
            offset = advance
            steps += 1
            XCTAssertLessThan(steps, 10_000)
        }
        XCTAssertEqual(collected, text)
    }

    // MARK: - notes.edit: explicit frames and default slot placement

    func testExplicitFrameValidationIsBoundedAndAllowsPDFOverlay() throws {
        var page = NotePage(width: 768, height: 1024)
        page.backgroundResourceID = UUID() // an explicit frame may deliberately overlay the PDF background
        let inside = NotesEditTool.Frame(x: 10, y: 10, width: 200, height: 100)
        XCTAssertEqual(try NotesEditTool.validatedFrame(inside, page: page).x, 10)
        XCTAssertThrowsError(try NotesEditTool.validatedFrame(NotesEditTool.Frame(x: -1, y: 0, width: 100, height: 100), page: page))
        XCTAssertThrowsError(try NotesEditTool.validatedFrame(NotesEditTool.Frame(x: 0, y: 0, width: 0, height: 100), page: page))
        XCTAssertThrowsError(try NotesEditTool.validatedFrame(NotesEditTool.Frame(x: 0, y: 0, width: 100, height: .nan), page: page))
        XCTAssertThrowsError(try NotesEditTool.validatedFrame(NotesEditTool.Frame(x: 700, y: 10, width: 100, height: 100), page: page))
        XCTAssertThrowsError(try NotesEditTool.validatedFrame(NotesEditTool.Frame(x: 10, y: 950, width: 100, height: 100), page: page))
    }

    func testSequentialDefaultAdditionsFillDistinctSlots() throws {
        var page = NotePage(width: 768, height: 1024)
        var placed: [NoteRect] = []
        for _ in 0..<4 {
            let frame = try NotesEditTool.resolveTextFrame(page, explicit: nil)
            for existing in placed {
                XCTAssertFalse(existing.intersects(frame), "default slots must not overlap")
            }
            placed.append(frame)
            page.elements.append(NoteElement(frame: frame, text: "笔记"))
        }
        XCTAssertEqual(placed.count, 4)
        XCTAssertTrue(placed.allSatisfy { $0.x == placed[0].x }, "one column on a portrait page")
        XCTAssertGreaterThan(placed[1].y, placed[0].y)
        XCTAssertLessThanOrEqual(placed[3].y + placed[3].height, page.height)
    }

    func testDefaultAdditionFailsWithActionableHintWhenPageIsFull() throws {
        var page = NotePage(width: 400, height: 300)
        let occupied = NoteRect(x: 40, y: 40, width: 320, height: 160)
        page.elements.append(NoteElement(frame: occupied, text: "已占用"))
        XCTAssertNil(NotesEditTool.defaultTextFrame(page, existing: page.elements.map(\.frame)))
        XCTAssertThrowsError(try NotesEditTool.resolveTextFrame(page, explicit: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("addPage"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("frame"), error.localizedDescription)
        }
        // A caller-supplied frame is still honored even when the default slot is unavailable.
        let explicit = try NotesEditTool.resolveTextFrame(page, explicit: NotesEditTool.Frame(x: 10, y: 10, width: 80, height: 40))
        XCTAssertEqual(explicit.x, 10)
        XCTAssertEqual(explicit.y, 10)
    }

    // MARK: - notes.search: grant scope and paging

    func testSearchReadsOnlyTheSuppliedScopedDocument() throws {
        var granted = NoteDocument(kind: .notebook, title: "已授权")
        granted.pages[0].elements = [NoteElement(frame: NoteRect(), text: "机会成本 opportunity cost", isAIGenerated: false)]
        var other = NoteDocument(kind: .notebook, title: "未授权")
        other.pages[0].elements = [NoteElement(frame: NoteRect(), text: "机会成本 opportunity cost in another document", isAIGenerated: false)]

        let hits = NotesSearchTool.hits(in: granted, query: "opportunity", limit: 50)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { $0.documentID == granted.id })
        XCTAssertFalse(hits.contains { $0.documentID == other.id })
        XCTAssertTrue(hits.contains { $0.sourceKind == "annotation" })
        XCTAssertLessThanOrEqual(hits.count, 50)
        // Each call is isolated to the document the caller supplied; the tool only
        // ever passes the conversation's granted scope.
        let otherHits = NotesSearchTool.hits(in: other, query: "opportunity", limit: 50)
        XCTAssertTrue(otherHits.allSatisfy { $0.documentID == other.id })
        XCTAssertTrue(NotesSearchTool.hits(in: granted, query: "opportunity", limit: 0).isEmpty)
    }

    func testSearchPagingAdvancesWithoutGapsOrDuplicates() {
        let hits = (0..<7).map { index in
            NotesSearchTool.Hit(documentID: UUID(), title: "t", revision: 1, pageID: nil, nodeID: nil,
                                sourceKind: "source", snippet: "hit \(index)")
        }
        let first = NotesSearchTool.pagedHits(hits, offset: 0, limit: 3)
        XCTAssertEqual(first.hits.count, 3)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.nextOffset, 3)
        let second = NotesSearchTool.pagedHits(hits, offset: first.nextOffset ?? -1, limit: 3)
        XCTAssertEqual(second.hits.count, 3)
        let last = NotesSearchTool.pagedHits(hits, offset: second.nextOffset ?? -1, limit: 3)
        XCTAssertEqual(last.hits.count, 1)
        XCTAssertFalse(last.hasMore)
        XCTAssertNil(last.nextOffset)
        XCTAssertEqual(Set((first.hits + second.hits + last.hits).map(\.snippet)).count, 7)
        XCTAssertTrue(NotesSearchTool.pagedHits(hits, offset: 7, limit: 3).hits.isEmpty)
    }

    func testSearchValidateRejectsOutOfRangePaging() throws {
        let tool = NotesSearchTool()
        XCTAssertThrowsError(try tool.validate(.init(query: "x", limit: 51, offset: 0, documentID: UUID())))
        XCTAssertThrowsError(try tool.validate(.init(query: "x", limit: 10, offset: 10_001, documentID: UUID())))
        XCTAssertThrowsError(try tool.validate(.init(query: "   ", limit: 10, offset: 0, documentID: nil)))
        // Paging without a documentID is allowed: product semantics page across
        // the conversation's already-granted scope, and execute sorts that scope
        // by UUID so offset/limit stay deterministic between calls.
        XCTAssertNoThrow(try tool.validate(.init(query: "x", limit: 10, offset: 0, documentID: nil)))
        XCTAssertThrowsError(try tool.validate(.init(query: "x", limit: 10, offset: -1, documentID: nil)))
        XCTAssertNoThrow(try tool.validate(.init(query: "机会成本", limit: 50, offset: 10_000, documentID: UUID())))
    }

    func testSearchScopeOrderIsStableByUUID() {
        let first = NoteDocument(kind: .notebook, title: "A")
        let second = NoteDocument(kind: .notebook, title: "B")
        let expected = [first, second].map(\.id).sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(NotesSearchTool.orderedScope([first, second]).map(\.id), expected)
        XCTAssertEqual(NotesSearchTool.orderedScope([second, first]).map(\.id), expected,
                       "same scope must page in a stable order regardless of store result order")
    }

    // MARK: - notes.read: mind-map node and structural pagination

    func testLongChineseNodeTitleAndNoteAreBytePagedAndReconstructable() throws {
        let title = String(repeating: "这是一个很长的中文主题标题🙂", count: 2_000)
        let note = String(repeating: "这是很长很长的中文备注内容，必须完整恢复。\n", count: 2_000)
        var node = MindMapNode(title: title)
        node.note = note
        var document = NoteDocument(kind: .mindMap, title: "长文导图")
        document.nodes = [node]

        let first = NotesReadTool.nodeDetail(document, node: node, offset: 0, limit: 100,
                                             textOffset: 0, textLimit: 8_000)
        XCTAssertLessThanOrEqual(try encodedBytes(first), NotesReadTool.maximumResponseBytes)
        XCTAssertEqual(first.documentID, document.id)
        XCTAssertEqual(first.revision, document.revision)
        XCTAssertEqual(first.nodeID, node.id)
        XCTAssertEqual(first.title.totalCharacters, title.count)
        XCTAssertTrue(first.title.hasMore)
        XCTAssertTrue(first.note.hasMore)

        XCTAssertEqual(try collectNodeText(\.title, document: document, node: node), title)
        XCTAssertEqual(try collectNodeText(\.note, document: document, node: node), note)
    }

    func testNodeAttachmentsPageAndEveryCaptionReconstructsFromOffsets() throws {
        let caption = String(repeating: "附件说明文字🙂", count: 1_500)
        var node = MindMapNode(title: "多附件主题")
        node.attachments = (0..<3).map { index in
            MindMapAttachment(resourceID: UUID(), fileName: "file-\(index).pdf", mediaType: "application/pdf",
                              kind: .document, caption: "\(index):\(caption)")
        }
        var document = NoteDocument(kind: .mindMap, title: "导图")
        document.nodes = [node]

        let page = NotesReadTool.nodeDetail(document, node: node, offset: 1, limit: 2, textOffset: 0, textLimit: 8_000)
        XCTAssertLessThanOrEqual(try encodedBytes(page), NotesReadTool.maximumResponseBytes)
        XCTAssertEqual(page.attachmentTotal, 3)
        XCTAssertEqual(page.attachmentOffset, 1)
        XCTAssertEqual(page.attachmentsReturned, 2)
        // This window is terminal: offset 1 + 2 reaches attachmentTotal. Every
        // continuation field in this tool (nextPageOffset, nextElementOffset,
        // nextOffset, nextTextOffset, nextAttachmentOffset) is nil once its
        // window reaches the end, and the tool description promises
        // nextAttachmentOffset only "when more content exists"; a terminal page
        // must not advertise a non-existent continuation at offset 3.
        XCTAssertEqual(page.attachmentOffset + page.attachmentsReturned, page.attachmentTotal)
        XCTAssertNil(page.nextAttachmentOffset)
        XCTAssertEqual(page.attachments.map(\.attachmentID), Array(node.attachments!.dropFirst(1)).map(\.id))

        // A window that stops before the end must advertise the exact
        // continuation offset, and an offset-1 walk must return every attachment
        // exactly once (no omission, no duplicate).
        let continued = NotesReadTool.nodeDetail(document, node: node, offset: 1, limit: 1, textOffset: 0, textLimit: 8_000)
        XCTAssertLessThanOrEqual(try encodedBytes(continued), NotesReadTool.maximumResponseBytes)
        XCTAssertEqual(continued.attachmentsReturned, 1)
        XCTAssertEqual(continued.nextAttachmentOffset, 2)
        XCTAssertEqual(continued.attachments.map(\.attachmentID), [node.attachments![1].id])

        var walkedAttachmentIDs: [UUID] = []
        var walkOffset = 0
        var walkSteps = 0
        while true {
            let slice = NotesReadTool.nodeDetail(document, node: node, offset: walkOffset, limit: 1,
                                                 textOffset: 0, textLimit: 8_000)
            XCTAssertLessThanOrEqual(try encodedBytes(slice), NotesReadTool.maximumResponseBytes)
            XCTAssertEqual(slice.attachmentOffset, walkOffset)
            walkedAttachmentIDs.append(contentsOf: slice.attachments.map(\.attachmentID))
            guard let advance = slice.nextAttachmentOffset, advance > walkOffset else { break }
            walkOffset = advance
            walkSteps += 1
            XCTAssertLessThan(walkSteps, 100, "attachment pagination must make bounded progress")
        }
        XCTAssertEqual(walkedAttachmentIDs, node.attachments!.map(\.id),
                       "attachment pages must not drop or repeat an attachment")

        // Every attachment caption is independently recoverable with its own
        // nextOffset; identity and resource IDs are never replaced by a summary.
        for (index, attachment) in node.attachments!.enumerated() {
            var collected = ""
            var textOffset = 0
            var steps = 0
            while true {
                let detail = NotesReadTool.nodeDetail(document, node: node, offset: index, limit: 1,
                                                      textOffset: textOffset, textLimit: 8_000)
                XCTAssertLessThanOrEqual(try encodedBytes(detail), NotesReadTool.maximumResponseBytes)
                let entry = try XCTUnwrap(detail.attachments.first)
                XCTAssertEqual(entry.attachmentID, attachment.id)
                XCTAssertEqual(entry.resourceID, attachment.resourceID)
                XCTAssertEqual(entry.fileName, attachment.fileName)
                XCTAssertEqual(entry.mediaType, attachment.mediaType)
                collected += try XCTUnwrap(entry.caption).text
                guard let advance = entry.caption?.nextOffset, advance > textOffset else { break }
                textOffset = advance
                steps += 1
                XCTAssertLessThan(steps, 10_000, "attachment caption pagination must make bounded progress")
            }
            XCTAssertEqual(collected, attachment.caption)
        }
    }

    func testNodeSectionReturnsBoundedSummariesWithResumableIDs() throws {
        var document = NoteDocument(kind: .mindMap, title: "大图")
        let rootID = UUID()
        document.nodes = (0..<400).map { index in
            MindMapNode(id: index == 0 ? rootID : UUID(), parentID: index == 0 ? nil : rootID,
                        title: "节点\(index)：" + String(repeating: "内容", count: 400))
        }

        let first = NotesReadTool.mapSlice(document, section: "nodes", offset: 0, limit: 200,
                                           textOffset: 0, textLimit: 8_000)
        XCTAssertLessThanOrEqual(try encodedBytes(first), NotesReadTool.maximumResponseBytes)
        XCTAssertGreaterThan(first.returned, 0)
        XCTAssertLessThanOrEqual(first.returned, 200)
        XCTAssertEqual(first.nextOffset ?? -1, first.offset + first.returned)
        XCTAssertTrue((first.nodes ?? []).allSatisfy { $0.titleCharacters > 200 && $0.titleTruncated },
                      "summary keeps the full title length so nodeID is clearly resumable")

        var seen = Set<UUID>()
        var offset = 0
        var steps = 0
        while true {
            let page = NotesReadTool.mapSlice(document, section: "nodes", offset: offset, limit: 200,
                                              textOffset: 0, textLimit: 8_000)
            XCTAssertLessThanOrEqual(try encodedBytes(page), NotesReadTool.maximumResponseBytes)
            for entry in page.nodes ?? [] {
                XCTAssertTrue(seen.insert(entry.nodeID).inserted, "node pages must not repeat or drop a node")
            }
            guard let next = page.nextOffset, next > offset else { break }
            offset = next
            steps += 1
            XCTAssertLessThan(steps, 100)
        }
        XCTAssertEqual(seen.count, 400)
    }

    func testLongConnectionTitleAndSummaryLabelAreResumable() throws {
        let label = String(repeating: "关联线标题🙂", count: 10_000)
        var document = NoteDocument(kind: .mindMap, title: "导图")
        let root = document.nodes[0]
        let child = MindMapNode(parentID: root.id, title: "子主题")
        document.nodes.append(child)
        let edge = MindMapConnection(from: root.id, to: child.id, title: label)
        document.connections = [edge]
        let summary = MindMapSummary(label: label, parent: root.id, start: 0, end: 0)
        document.summaries = [summary]

        let connectionPage = NotesReadTool.mapSlice(document, section: "connections", offset: 0, limit: 100,
                                                    textOffset: 0, textLimit: 8_000)
        XCTAssertLessThanOrEqual(try encodedBytes(connectionPage), NotesReadTool.maximumResponseBytes)
        let firstEdge = try XCTUnwrap(connectionPage.connections?.first)
        XCTAssertEqual(firstEdge.connectionID, edge.id)
        XCTAssertEqual(firstEdge.from, root.id)
        XCTAssertEqual(firstEdge.to, child.id)
        XCTAssertTrue(firstEdge.title.hasMore)
        XCTAssertEqual(try collectConnectionTitle(document: document, edge: edge, textLimit: 8_000), label)

        let summaryPage = NotesReadTool.mapSlice(document, section: "summaries", offset: 0, limit: 100,
                                                 textOffset: 0, textLimit: 8_000)
        XCTAssertLessThanOrEqual(try encodedBytes(summaryPage), NotesReadTool.maximumResponseBytes)
        let firstSummary = try XCTUnwrap(summaryPage.summaries?.first)
        XCTAssertEqual(firstSummary.summaryID, summary.id)
        XCTAssertTrue(firstSummary.label.hasMore)
        XCTAssertEqual(try collectSummaryLabel(document: document, summary: summary, textLimit: 8_000), label)
    }

    func testBoundaryGraphemeAlwaysAdvancesAndNeverStalls() throws {
        // One extended grapheme cluster with several scalars still counts as one
        // character; a byte budget smaller than the cluster must emit it whole and
        // advance, never loop forever or silently drop it.
        let grapheme = "👨‍👩‍👧‍👦"
        XCTAssertEqual(grapheme.count, 1)
        XCTAssertGreaterThan(NotesReadTool.jsonEscapedByteCount(Character(grapheme)), 1)
        XCTAssertEqual(NotesReadTool.boundedCharacterEnd(grapheme + "尾", from: 0, characterLimit: 5, byteLimit: 1), 1)
        XCTAssertEqual(NotesReadTool.boundedCharacterEnd("中", from: 0, characterLimit: 1, byteLimit: 1), 1)
    }

    // MARK: - notes.read officeFields / notes.edit updateOfficeText

    /// Real generated .docx: read stable field IDs, rewrite one field through
    /// the immutable Notes CAS, reopen the committed revision and match text.
    func testOfficeFieldsReadAndUpdateRoundTripsThroughCAS() async throws {
        var store: NotesStore! = nil
        var root: URL!
        (store, root) = try makeOfficeStore()
        // A scratch store owns GRDB's open SQLite connection. Release the store
        // reference first, then unlink the directory: removing the file while the
        // connection is open makes SQLite log "vnode unlinked while in use". This
        // only reorders test teardown; the product storage API is unchanged.
        defer {
            store = nil
            try? FileManager.default.removeItem(at: root)
        }
        let source = try makeOfficeFixture(root: root, name: "contract.docx", title: "合同",
                                           paragraphs: ["甲方：Floe", "乙方：用户"])
        let document = try await importOfficeDocument(source, fileName: "合同.docx", title: "合同", store: store)
        let conversation = UUID()
        try await store.grantAccess(conversationID: conversation, documentID: document.id, canEdit: true)

        let page = try await NotesReadTool.readOfficeFields(document, store: store, offset: 0, limit: 100,
                                                            textOffset: 0, textLimit: 8_000, fieldID: nil)
        XCTAssertEqual(page.documentID, document.id)
        XCTAssertEqual(page.revision, document.revision)
        XCTAssertEqual(page.sha256.count, 64)
        XCTAssertGreaterThanOrEqual(page.fieldCount, 3)
        XCTAssertEqual(page.fieldsReturned, page.fieldCount)
        XCTAssertEqual(page.fields.map(\.fieldIndex), Array(0..<page.fieldsReturned))
        XCTAssertEqual(page.fields.map(\.fieldID).count, Set(page.fields.map(\.fieldID)).count)
        XCTAssertTrue(page.fields.allSatisfy { $0.fieldID.contains("|p|") })
        XCTAssertTrue(page.fields.contains { $0.text == "乙方：用户" })

        let target = try XCTUnwrap(page.fields.first { $0.text == "乙方：用户" })
        let originalResourceID = try XCTUnwrap(document.officeResourceID)
        let updated = try await NotesEditTool.applyOfficeTextUpdates(
            store: store, document: document, updates: [target.fieldID: "乙方：已修改"],
            expectedSHA256: page.sha256, expectedRevision: document.revision,
            title: "Agent 修改", requestID: "run:office", authorizedConversationID: conversation)
        XCTAssertEqual(updated.revision, document.revision + 1)
        XCTAssertNotEqual(updated.officeResourceID, originalResourceID)
        let newResourceID = try XCTUnwrap(updated.officeResourceID)

        // Reopen the committed CAS revision and confirm the content survived.
        let reopened = try await store.document(document.id)
        XCTAssertEqual(reopened.revision, updated.revision)
        XCTAssertEqual(reopened.officeResourceID, newResourceID)
        let reopenedField = try await NotesReadTool.readOfficeFields(
            reopened, store: store, offset: 0, limit: 100, textOffset: 0, textLimit: 8_000,
            fieldID: target.fieldID)
        XCTAssertEqual(reopenedField.fields.first?.text, "乙方：已修改")
        XCTAssertEqual(reopenedField.fields.first?.textCharacters, 6)
        // The old immutable resource and its registration are preserved.
        let originalURL = try await store.resourceURL(originalResourceID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
    }

    /// A stale expectedRevision or a stale sha256 fails closed and never
    /// overwrites the current document or its resource pointer.
    func testStaleOfficeRevisionAndSHA256NeverOverwrite() async throws {
        var store: NotesStore! = nil
        var root: URL!
        (store, root) = try makeOfficeStore()
        // A scratch store owns GRDB's open SQLite connection. Release the store
        // reference first, then unlink the directory: removing the file while the
        // connection is open makes SQLite log "vnode unlinked while in use". This
        // only reorders test teardown; the product storage API is unchanged.
        defer {
            store = nil
            try? FileManager.default.removeItem(at: root)
        }
        let source = try makeOfficeFixture(root: root, name: "note.docx", title: "笔记", paragraphs: ["第一版"])
        let document = try await importOfficeDocument(source, fileName: "note.docx", title: "笔记", store: store)
        let conversation = UUID()
        try await store.grantAccess(conversationID: conversation, documentID: document.id, canEdit: true)

        let firstPage = try await NotesReadTool.readOfficeFields(document, store: store, offset: 0, limit: 100,
                                                                 textOffset: 0, textLimit: 8_000, fieldID: nil)
        let field = try XCTUnwrap(firstPage.fields.first { $0.text == "第一版" })
        let revised = try await NotesEditTool.applyOfficeTextUpdates(
            store: store, document: document, updates: [field.fieldID: "第二版"],
            expectedSHA256: firstPage.sha256, expectedRevision: document.revision,
            title: "第一次修改", requestID: "run:first", authorizedConversationID: conversation)
        XCTAssertEqual(revised.revision, document.revision + 1)
        let revisedResourceID = try XCTUnwrap(revised.officeResourceID)

        let currentPage = try await NotesReadTool.readOfficeFields(revised, store: store, offset: 0, limit: 100,
                                                                   textOffset: 0, textLimit: 8_000, fieldID: nil)
        // Matching sha256 but an old expectedRevision conflicts at commit.
        await assertConflict {
            _ = try await NotesEditTool.applyOfficeTextUpdates(
                store: store, document: revised, updates: [field.fieldID: "过期版本"],
                expectedSHA256: currentPage.sha256, expectedRevision: document.revision,
                title: "过期版本", requestID: "run:stale-revision", authorizedConversationID: conversation)
        }
        // Current package but a sha256 read from the previous revision conflicts.
        await assertConflict {
            _ = try await NotesEditTool.applyOfficeTextUpdates(
                store: store, document: revised, updates: [field.fieldID: "过期校验"],
                expectedSHA256: firstPage.sha256, expectedRevision: revised.revision,
                title: "过期校验", requestID: "run:stale-sha", authorizedConversationID: conversation)
        }

        let after = try await store.document(document.id)
        XCTAssertEqual(after.revision, revised.revision)
        XCTAssertEqual(after.officeResourceID, revisedResourceID)
        let afterField = try await NotesReadTool.readOfficeFields(after, store: store, offset: 0, limit: 100,
                                                                  textOffset: 0, textLimit: 8_000, fieldID: field.fieldID)
        XCTAssertEqual(afterField.fields.first?.text, "第二版")
    }

    /// Reading and rewriting another document requires its own explicit grant;
    /// the CAS replacement cannot bypass the transaction's scope check.
    func testOfficeTextEditRejectsUnauthorizedDocument() async throws {
        var store: NotesStore! = nil
        var root: URL!
        (store, root) = try makeOfficeStore()
        // A scratch store owns GRDB's open SQLite connection. Release the store
        // reference first, then unlink the directory: removing the file while the
        // connection is open makes SQLite log "vnode unlinked while in use". This
        // only reorders test teardown; the product storage API is unchanged.
        defer {
            store = nil
            try? FileManager.default.removeItem(at: root)
        }
        let sourceA = try makeOfficeFixture(root: root, name: "a.docx", title: "甲", paragraphs: ["甲文"])
        let sourceB = try makeOfficeFixture(root: root, name: "b.docx", title: "乙", paragraphs: ["乙文"])
        let documentA = try await importOfficeDocument(sourceA, fileName: "a.docx", title: "甲", store: store)
        let documentB = try await importOfficeDocument(sourceB, fileName: "b.docx", title: "乙", store: store)
        let conversation = UUID()
        try await store.grantAccess(conversationID: conversation, documentID: documentA.id, canEdit: true)

        // The conversation has no grant for B, for read or edit.
        await assertThrows { try await store.authorize(conversationID: conversation, documentID: documentB.id, editing: false) }
        let grants = try await store.accessGrants(conversationID: conversation)
        XCTAssertFalse(grants[documentB.id] ?? false)

        let pageB = try await NotesReadTool.readOfficeFields(documentB, store: store, offset: 0, limit: 100,
                                                             textOffset: 0, textLimit: 8_000, fieldID: nil)
        let fieldB = try XCTUnwrap(pageB.fields.first { $0.text == "乙文" })
        await assertThrows {
            _ = try await NotesEditTool.applyOfficeTextUpdates(
                store: store, document: documentB, updates: [fieldB.fieldID: "越权修改"],
                expectedSHA256: pageB.sha256, expectedRevision: documentB.revision,
                title: "越权", requestID: "run:unauthorized", authorizedConversationID: conversation)
        }

        let after = try await store.document(documentB.id)
        XCTAssertEqual(after.revision, documentB.revision)
        XCTAssertEqual(after.officeResourceID, documentB.officeResourceID)
    }

    /// A very long Office field stays inside the 196608-byte transport, parses
    /// as JSON and reconstructs exactly through fieldID + textOffset.
    func testLongOfficeFieldIsByteBoundedParseableAndFullyRecoverable() async throws {
        var store: NotesStore! = nil
        var root: URL!
        (store, root) = try makeOfficeStore()
        // A scratch store owns GRDB's open SQLite connection. Release the store
        // reference first, then unlink the directory: removing the file while the
        // connection is open makes SQLite log "vnode unlinked while in use". This
        // only reorders test teardown; the product storage API is unchanged.
        defer {
            store = nil
            try? FileManager.default.removeItem(at: root)
        }
        let longText = String(repeating: "长字段中文内容🙂", count: 8_000)
        let source = try makeOfficeFixture(root: root, name: "long.docx", title: "长文档", paragraphs: [longText])
        let document = try await importOfficeDocument(source, fileName: "long.docx", title: "长文档", store: store)

        let first = try await NotesReadTool.readOfficeFields(document, store: store, offset: 0, limit: 100,
                                                             textOffset: 0, textLimit: 8_000, fieldID: nil)
        XCTAssertLessThanOrEqual(try encodedBytes(first), NotesReadTool.maximumResponseBytes)
        let longField = try XCTUnwrap(first.fields.first { $0.textCharacters == longText.count })
        XCTAssertTrue(longField.textHasMore)
        XCTAssertGreaterThan(longField.textReturnedCharacters, 0)
        XCTAssertEqual(longField.textOffset, 0)

        // The serialized tool response is valid JSON inside the byte budget.
        let output = try NotesReadTool.output(first)
        let outputBytes = Data(output.summary.utf8)
        XCTAssertLessThanOrEqual(outputBytes.count, NotesReadTool.maximumResponseBytes)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: outputBytes))

        var collected = longField.text
        var offset = try XCTUnwrap(longField.nextTextOffset)
        var steps = 0
        while true {
            let next = try await NotesReadTool.readOfficeFields(
                document, store: store, offset: 0, limit: 100, textOffset: offset, textLimit: 8_000,
                fieldID: longField.fieldID)
            XCTAssertLessThanOrEqual(try encodedBytes(next), NotesReadTool.maximumResponseBytes)
            let chunk = try XCTUnwrap(next.fields.first)
            XCTAssertEqual(chunk.fieldID, longField.fieldID)
            XCTAssertEqual(chunk.textOffset, offset)
            collected += chunk.text
            guard let advance = chunk.nextTextOffset, advance > offset else { break }
            offset = advance
            steps += 1
            XCTAssertLessThan(steps, 10_000, "Office field pagination must make bounded progress")
        }
        XCTAssertEqual(collected.count, longText.count)
        XCTAssertEqual(collected, longText)
    }

    /// `updateOfficeText` must distinguish an omitted `text` from an explicit
    /// clear, reject an empty field ID, and reject the same field ID twice in one
    /// batch (a duplicate dictionary key would otherwise silently drop an update).
    func testOfficeUpdateValidateRejectsMissingTextEmptyAndDuplicateFieldIDs() throws {
        let tool = NotesEditTool()
        func arguments(_ operations: String,
                       sha: String = String(repeating: "a", count: 64)) throws -> NotesEditTool.Arguments {
            let json = #"{"documentID":"\#(UUID().uuidString)","expectedRevision":1,"title":"t","expectedSHA256":"\#(sha)","operations":\#(operations)}"#
            return try JSONDecoder().decode(NotesEditTool.Arguments.self, from: Data(json.utf8))
        }
        let field = "word/document.xml|p|1"
        // An explicitly supplied empty string is a real clear and stays valid.
        XCTAssertNoThrow(try tool.validate(try arguments(#"[{"action":"updateOfficeText","fieldID":"\#(field)","text":""}]"#)))
        // A missing or null text is an incomplete update, not an empty clear.
        XCTAssertThrowsError(try tool.validate(try arguments(#"[{"action":"updateOfficeText","fieldID":"\#(field)"}]"#)))
        XCTAssertThrowsError(try tool.validate(try arguments(#"[{"action":"updateOfficeText","fieldID":"\#(field)","text":null}]"#)))
        // An empty field ID is refused before it can become a dictionary key.
        XCTAssertThrowsError(try tool.validate(try arguments(#"[{"action":"updateOfficeText","fieldID":"","text":"x"}]"#)))
        // The same field ID twice would collapse into one dictionary entry.
        XCTAssertThrowsError(try tool.validate(try arguments(#"[{"action":"updateOfficeText","fieldID":"\#(field)","text":"a"},{"action":"updateOfficeText","fieldID":"\#(field)","text":"b"}]"#)))
        // The sha256 gate still fails before any field check.
        XCTAssertThrowsError(try tool.validate(try arguments(#"[{"action":"updateOfficeText","fieldID":"\#(field)","text":"x"}]"#, sha: "nothex")))
    }

    // MARK: - helpers

    /// `XCTAssertThrowsError` cannot wrap an `async` call, so await inside a
    /// plain throwing closure and assert its error here.
    private func assertThrows(_ body: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected an error", file: file, line: line)
        } catch {}
    }

    private func assertConflict(_ body: () async throws -> Void,
                                file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected a conflict", file: file, line: line)
        } catch {
            guard case NoteError.conflict = error else {
                return XCTFail("expected a conflict, got \(error)", file: file, line: line)
            }
        }
    }

    private func makeOfficeStore() throws -> (store: NotesStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-office-tools-\(UUID().uuidString)", isDirectory: true)
        return (try NotesStore(root: root), root)
    }

    private func makeOfficeFixture(root: URL, name: String, title: String, paragraphs: [String]) throws -> URL {
        let directory = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent(name)
        try OfficeDocumentBuilder.createWord(at: source, title: title, paragraphs: paragraphs)
        return source
    }

    private func importOfficeDocument(_ source: URL, fileName: String, title: String,
                                      store: NotesStore) async throws -> NoteDocument {
        let resource = try await store.importResource(
            from: source, mediaType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        var document = NoteDocument(kind: .office, title: title)
        document.officeResourceID = resource
        document.officeFileName = fileName
        return try await store.create(document)
    }

    private func collectNodeText(_ field: KeyPath<NotesReadTool.NodeDetail, NotesReadTool.TextChunk>,
                                 document: NoteDocument, node: MindMapNode) throws -> String {
        let first = NotesReadTool.nodeDetail(document, node: node, offset: 0, limit: 100,
                                             textOffset: 0, textLimit: 8_000)
        XCTAssertLessThanOrEqual(try encodedBytes(first), NotesReadTool.maximumResponseBytes)
        var collected = first[keyPath: field].text
        var offset = try XCTUnwrap(first[keyPath: field].nextOffset)
        var steps = 0
        while true {
            let next = NotesReadTool.nodeDetail(document, node: node, offset: 0, limit: 100,
                                                textOffset: offset, textLimit: 8_000)
            XCTAssertLessThanOrEqual(try encodedBytes(next), NotesReadTool.maximumResponseBytes)
            let chunk = next[keyPath: field]
            XCTAssertEqual(chunk.offset, offset)
            collected += chunk.text
            guard let advance = chunk.nextOffset, advance > offset else { break }
            offset = advance
            steps += 1
            XCTAssertLessThan(steps, 10_000, "node text pagination must make bounded progress")
        }
        return collected
    }

    private func collectConnectionTitle(document: NoteDocument, edge: MindMapConnection, textLimit: Int) throws -> String {
        var collected = ""
        var offset = 0
        var steps = 0
        while true {
            let page = NotesReadTool.mapSlice(document, section: "connections", offset: 0, limit: 100,
                                              textOffset: offset, textLimit: textLimit)
            XCTAssertLessThanOrEqual(try encodedBytes(page), NotesReadTool.maximumResponseBytes)
            let entry = try XCTUnwrap(page.connections?.first)
            XCTAssertEqual(entry.connectionID, edge.id)
            XCTAssertEqual(entry.title.offset, offset)
            collected += entry.title.text
            guard let advance = entry.title.nextOffset, advance > offset else { break }
            offset = advance
            steps += 1
            XCTAssertLessThan(steps, 2_000)
        }
        return collected
    }

    private func collectSummaryLabel(document: NoteDocument, summary: MindMapSummary, textLimit: Int) throws -> String {
        var collected = ""
        var offset = 0
        var steps = 0
        while true {
            let page = NotesReadTool.mapSlice(document, section: "summaries", offset: 0, limit: 100,
                                              textOffset: offset, textLimit: textLimit)
            XCTAssertLessThanOrEqual(try encodedBytes(page), NotesReadTool.maximumResponseBytes)
            let entry = try XCTUnwrap(page.summaries?.first)
            XCTAssertEqual(entry.summaryID, summary.id)
            XCTAssertEqual(entry.label.offset, offset)
            collected += entry.label.text
            guard let advance = entry.label.nextOffset, advance > offset else { break }
            offset = advance
            steps += 1
            XCTAssertLessThan(steps, 2_000)
        }
        return collected
    }

    private func encodedBytes<T: Encodable>(_ value: T) throws -> Int {
        try NotesReadTool.output(value).summary.utf8.count
    }
}
