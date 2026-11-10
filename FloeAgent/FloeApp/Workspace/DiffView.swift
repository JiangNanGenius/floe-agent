// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Native selectable, numbered diff evidence. Never applies file changes.
struct DiffView: View {
    let diffText: String
    private let document: NativeFileDiff?
    private let changesOnly: Bool
    private let omitsSingleFileHeader: Bool
    private let onContentHeightChange: ((Double) -> Void)?
    @ScaledMetric(relativeTo: .footnote) private var fontSize: CGFloat = 13

    init(diffText: String) {
        self.diffText = diffText
        document = try? NativeFileDiff(unifiedDiff: diffText)
        changesOnly = false; omitsSingleFileHeader = false; onContentHeightChange = nil
    }
    init(document: NativeFileDiff, changesOnly: Bool = false, omitsSingleFileHeader: Bool = false,
         onContentHeightChange: ((Double) -> Void)? = nil) {
        diffText = ""; self.document = document; self.changesOnly = changesOnly
        self.omitsSingleFileHeader = omitsSingleFileHeader
        self.onContentHeightChange = onContentHeightChange
    }
    var body: some View {
        Group {
            if let document {
                let lines = changesOnly ? document.compactLines : document.lines.filter {
                    !(omitsSingleFileHeader && document.paths.count == 1 && $0.kind == .file)
                }
                NativeDiffCodeView(lines: lines, fontSize: fontSize, heightChanged: onContentHeightChange)
            } else {
                // Preserve unsupported original evidence without invented totals.
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: diffText).font(FloeTheme.Typography.evidence)
                        .textSelection(.enabled).fixedSize(horizontal: true, vertical: false).padding(10)
                }
            }
        }
        .background(FloeTheme.readingSurface)
    }
}

private struct NativeDiffCodeView: UIViewRepresentable {
    let lines: [NativeFileDiff.Line]
    let fontSize: CGFloat
    let heightChanged: ((Double) -> Void)?
    func makeUIView(context: Context) -> NativeDiffCodeViewport { NativeDiffCodeViewport() }
    func updateUIView(_ view: NativeDiffCodeViewport, context: Context) {
        view.heightChanged = heightChanged
        view.configure(lines: lines, fontSize: fontSize)
    }
}

/// UIKit owns the complete extent and virtualizes large patches. The vertical
/// table retains real UITextView selection inside a horizontal code viewport.
@MainActor private final class NativeDiffCodeViewport: UIView, UITableViewDataSource {
    private let horizontal = UIScrollView()
    private let table = UITableView(frame: .zero, style: .plain)
    private var lines: [NativeFileDiff.Line] = []
    private var font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var codeWidth: CGFloat = 0
    private var generation = 0
    private var reportedHeight: CGFloat = -1
    var heightChanged: ((Double) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        horizontal.backgroundColor = .clear
        horizontal.contentInsetAdjustmentBehavior = .never
        horizontal.showsVerticalScrollIndicator = false
        horizontal.isDirectionalLockEnabled = true
        addSubview(horizontal)
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never
        table.sectionHeaderTopPadding = 0
        table.estimatedRowHeight = 0
        table.estimatedSectionHeaderHeight = 0
        table.estimatedSectionFooterHeight = 0
        table.showsHorizontalScrollIndicator = false
        table.allowsSelection = false
        table.dataSource = self
        table.register(NativeDiffCodeCell.self, forCellReuseIdentifier: "line")
        table.accessibilityLabel = NativeFileDiffCopy.t("修改明细", "Changed lines")
        table.accessibilityIdentifier = "fileDiff.lines"
        horizontal.addSubview(table)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(lines: [NativeFileDiff.Line], fontSize: CGFloat) {
        let next = UIFont.monospacedSystemFont(ofSize: max(1, fontSize), weight: .regular)
        guard self.lines != lines || font.pointSize != next.pointSize else { return }
        generation += 1; self.lines = lines; font = next
        table.rowHeight = ceil(font.lineHeight) + 6
        codeWidth = lines.reduce(CGFloat.zero) { width, line in
            let text = displayedContent(line) as NSString
            let gutter: CGFloat = isHeading(line) ? 16 : 100
            return max(width, ceil(text.size(withAttributes: [.font: font]).width) + gutter)
        }
        table.reloadData()
        table.setContentOffset(.zero, animated: false)
        horizontal.setContentOffset(.zero, animated: false)
        reportedHeight = -1
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        horizontal.frame = bounds
        let width = max(bounds.width, codeWidth)
        horizontal.contentSize = CGSize(width: width, height: bounds.height)
        table.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        table.layoutIfNeeded()
        let height = table.contentSize.height
        guard height.isFinite, height > 0, height != reportedHeight else { return }
        reportedHeight = height
        let current = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == current, self.reportedHeight == height else { return }
            self.heightChanged?(Double(height))
        }
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { lines.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "line", for: indexPath) as! NativeDiffCodeCell
        cell.configure(line: lines[indexPath.row], font: font)
        return cell
    }
    private func isHeading(_ line: NativeFileDiff.Line) -> Bool {
        line.kind == .file || line.kind == .hunk || line.kind == .noNewline
    }
    private func displayedContent(_ line: NativeFileDiff.Line) -> String {
        line.kind == .noNewline ? NativeFileDiffCopy.t("文件末尾没有换行", "No newline at end of file") : line.content
    }
}

@MainActor private final class NativeDiffCodeCell: UITableViewCell {
    private let gutter = UIView()
    private let oldNumber = UILabel()
    private let newNumber = UILabel()
    private let sign = UILabel()
    private let code = NativeDiffCodeTextView()
    private var heading = false
    private var rawLine = ""

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none; backgroundColor = .clear
        isAccessibilityElement = false; contentView.clipsToBounds = true
        contentView.addSubview(gutter)
        for label in [oldNumber, newNumber, sign] {
            label.textAlignment = .right; label.isAccessibilityElement = false
            contentView.addSubview(label)
        }
        code.backgroundColor = .clear
        code.isEditable = false; code.isSelectable = true; code.isScrollEnabled = false
        code.textContainerInset = .zero
        code.textContainer.lineFragmentPadding = 0
        code.textContainer.maximumNumberOfLines = 1
        code.textContainer.lineBreakMode = .byClipping
        code.contentInset = .zero; code.contentInsetAdjustmentBehavior = .never
        code.isAccessibilityElement = true
        code.accessibilityCustomActions = [UIAccessibilityCustomAction(
            name: NativeFileDiffCopy.t("复制这一行", "Copy line"), target: self, selector: #selector(copyLine))]
        contentView.addSubview(code)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(line: NativeFileDiff.Line, font: UIFont) {
        heading = line.kind == .file || line.kind == .hunk || line.kind == .noNewline
        rawLine = line.content
        let content = line.kind == .noNewline
            ? NativeFileDiffCopy.t("文件末尾没有换行", "No newline at end of file") : line.content
        if code.text != content { code.text = content }
        code.font = font; oldNumber.font = font; newNumber.font = font; sign.font = font
        oldNumber.text = line.oldNumber.map(String.init) ?? ""
        newNumber.text = line.newNumber.map(String.init) ?? ""
        sign.text = line.kind == .addition ? "+" : line.kind == .removal ? "−" : ""
        let tint: UIColor
        switch line.kind {
        case .addition: tint = .systemGreen
        case .removal: tint = .systemRed
        case .hunk: tint = .systemBlue
        default: tint = .secondaryLabel
        }
        contentView.backgroundColor = line.isChange ? tint.withAlphaComponent(0.11)
            : line.kind == .hunk ? tint.withAlphaComponent(0.05) : .clear
        gutter.backgroundColor = tint.withAlphaComponent(line.isChange ? 0.06 : 0.025)
        code.textColor = heading ? tint : .label
        oldNumber.textColor = .secondaryLabel; newNumber.textColor = .secondaryLabel; sign.textColor = tint
        gutter.isHidden = heading; oldNumber.isHidden = heading; newNumber.isHidden = heading; sign.isHidden = heading
        code.accessibilityIdentifier = "fileDiff.line.\(line.id)"
        if heading { code.accessibilityLabel = content }
        else {
            let operation = line.kind == .addition ? NativeFileDiffCopy.t("新增", "Added")
                : line.kind == .removal ? NativeFileDiffCopy.t("删除", "Removed") : NativeFileDiffCopy.t("原有", "Context")
            let number = line.newNumber ?? line.oldNumber ?? 0
            code.accessibilityLabel = operation + " " + NativeFileDiffCopy.t("第\(number)行", "line \(number)")
        }
        code.accessibilityValue = content
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let height = contentView.bounds.height
        gutter.frame = CGRect(x: 0, y: 0, width: 68, height: height)
        oldNumber.frame = CGRect(x: 0, y: 3, width: 28, height: height - 6)
        newNumber.frame = CGRect(x: 34, y: 3, width: 28, height: height - 6)
        sign.frame = CGRect(x: 68, y: 3, width: 16, height: height - 6)
        let x: CGFloat = heading ? 8 : 90
        code.frame = CGRect(x: x, y: 3, width: max(1, contentView.bounds.width - x - 10), height: max(1, height - 6))
    }
    @objc private func copyLine() -> Bool { UIPasteboard.general.string = rawLine; return true }
}

/// Read-only selectable text can report an invalid default AX activation
/// point inside nested scroll containers. Resolve it from this real view's
/// currently visible text geometry, including after either axis scrolls.
@MainActor private final class NativeDiffCodeTextView: UITextView {
    override var accessibilityActivationPoint: CGPoint {
        get {
            guard window != nil, !isHidden else { return super.accessibilityActivationPoint }
            var visible = bounds
            var ancestor = superview
            while let parent = ancestor {
                if parent.clipsToBounds { visible = visible.intersection(convert(parent.bounds, from: parent)) }
                ancestor = parent.superview
            }
            guard !visible.isNull, visible.width > 2, visible.height > 2 else {
                return super.accessibilityActivationPoint
            }
            let caret = caretRect(for: beginningOfDocument)
            let point = CGPoint(x: min(max(caret.midX, visible.minX + 1), visible.maxX - 1),
                                y: min(max(caret.midY, visible.minY + 1), visible.maxY - 1))
            return UIAccessibility.convertToScreenCoordinates(
                CGRect(origin: point, size: CGSize(width: 1, height: 1)), in: self).origin
        }
        set { super.accessibilityActivationPoint = newValue }
    }
}
#endif

