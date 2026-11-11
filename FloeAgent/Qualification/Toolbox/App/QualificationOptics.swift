// SPDX-License-Identifier: MPL-2.0
#if os(iOS) && !TOOLBOX_LOCATION_ONLY && !TOOLBOX_FIRST_BATCH_ONLY
import CoreImage
import SwiftUI
import UIKit
import FloeToolboxWorkbenches
import FloeToolboxUtilities

@MainActor
struct QualificationQR: View {
    let fixture: Bool
    var linkFixture = false
    @State private var exportedBytes = 0
    @State private var openedURL: String?

    var body: some View {
        ToolboxQRView(importImage: {
            guard fixture || linkFixture else { return nil }
            return try ToolboxQR.png(text: linkFixture ? "https://example.com/floe-toolbox?source=qr#result" : "FLOE-QR-IMPORT-2026")
        }, exportImage: { exportedBytes = $0.count })
        .environment(\.openURL, OpenURLAction { url in
            guard linkFixture else { return .systemAction }
            openedURL = url.absoluteString
            return .handled
        })
        .safeAreaInset(edge: .top, spacing: 0) {
            if fixture || linkFixture {
                VStack(spacing: 4) {
                    Text("合成二维码图片 · 非相机画面 / Synthetic QR image, not a camera capture")
                        .accessibilityIdentifier("qualification.qr.synthetic")
                    if exportedBytes > 0 {
                        Text("PNG callback received: \(exportedBytes) bytes")
                            .accessibilityIdentifier("qualification.qr.exported")
                    }
                    if linkFixture {
                        Text("链接打开请求记入回执 / Link open requests are recorded")
                            .foregroundStyle(.secondary)
                    }
                    if let openedURL {
                        Text(openedURL).accessibilityIdentifier("qualification.qr.openedURL")
                    }
                }
                .font(.caption).padding(8).frame(maxWidth: .infinity)
                .background(.yellow.opacity(0.15))
            }
        }
    }
}

/// Supplies actual pixels to the production import/recognition path. Host
/// callbacks produce receipts only; this host does not write Files or Notes.
@MainActor
struct QualificationScanner: View {
    let fixture: Bool

    @State private var importedBytes = 0
    @State private var fixtureFailure: String?
    @State private var exportReceipt: ExportReceipt?
    @State private var receivedNote: String?

    private struct ExportReceipt {
        let fileExtension: String
        let byteCount: Int
        let text: String?
    }

    var body: some View {
        ToolboxScannerView(
            importImage: {
                guard fixture else { return nil }
                do {
                    let data = try Self.fixturePNG()
                    importedBytes = data.count
                    fixtureFailure = nil
                    return data
                } catch {
                    fixtureFailure = String(describing: error)
                    throw error
                }
            },
            exportArtifact: { data, fileExtension in
                exportReceipt = ExportReceipt(
                    fileExtension: fileExtension,
                    byteCount: data.count,
                    text: fileExtension.lowercased() == "txt" ? String(data: data, encoding: .utf8) : nil)
            },
            saveNote: { text in receivedNote = text }
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                if fixture {
                    Text("合成扫码图片 · 非相机画面 / Synthetic image, not a camera capture")
                        .accessibilityIdentifier("qualification.scanner.synthetic")
                }
                Text("仅记录导出与手记回调，不写入文件或手记 / Callback receipts only")
                    .foregroundStyle(.secondary)
                if importedBytes > 0 {
                    Text("Fixture PNG imported: \(importedBytes) bytes")
                        .accessibilityIdentifier("qualification.scanner.imported")
                }
                if let fixtureFailure {
                    Text(fixtureFailure)
                        .accessibilityIdentifier("qualification.scanner.fixtureError")
                }
                if let exportReceipt {
                    Text("\(exportReceipt.fileExtension.uppercased()) callback received: \(exportReceipt.byteCount) bytes")
                        .accessibilityIdentifier("qualification.scanner.exported")
                    if let text = exportReceipt.text {
                        Text(text)
                            .lineLimit(3)
                            .accessibilityIdentifier("qualification.scanner.exportPayload")
                    }
                }
                if let receivedNote {
                    Text("Notes callback received: \(receivedNote.utf8.count) bytes")
                        .accessibilityIdentifier("qualification.scanner.noteReceived")
                    Text(receivedNote)
                        .lineLimit(3)
                        .accessibilityIdentifier("qualification.scanner.notePayload")
                }
            }
            .font(.caption)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.15))
        }
    }

    private enum FixtureError: Error {
        case qrGeneration
    }

    /// A 1.92 MP, opaque image with large independent English/CJK lines and a
    /// crisp QR. The QR payload is deliberately not printed elsewhere, so an
    /// OCR-only result cannot satisfy the QR UI assertion.
    private static func fixturePNG() throws -> Data {
        let qrPayload = "FLOE-SYNTHETIC-QR-2026"
        guard let generator = CIFilter(name: "CIQRCodeGenerator") else { throw FixtureError.qrGeneration }
        generator.setValue(Data(qrPayload.utf8), forKey: "inputMessage")
        generator.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = generator.outputImage else { throw FixtureError.qrGeneration }
        let moduleScale = max(1, floor(512 / output.extent.width))
        let qrImage = output.transformed(by: CGAffineTransform(scaleX: moduleScale, y: moduleScale))
        let imageContext = CIContext(options: [.cacheIntermediates: false])
        guard let qr = imageContext.createCGImage(qrImage, from: qrImage.extent) else {
            throw FixtureError.qrGeneration
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let size = CGSize(width: 1600, height: 1200)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("LOCAL SCAN 2026" as NSString).draw(
                in: CGRect(x: 120, y: 100, width: 1360, height: 110),
                withAttributes: [.font: UIFont.systemFont(ofSize: 76, weight: .semibold),
                                 .foregroundColor: UIColor.black])
            ("本地文字识别测试" as NSString).draw(
                in: CGRect(x: 120, y: 260, width: 1360, height: 110),
                withAttributes: [.font: UIFont.systemFont(ofSize: 76, weight: .medium),
                                 .foregroundColor: UIColor.black])
            context.cgContext.interpolationQuality = .none
            let side = CGFloat(qr.width)
            UIImage(cgImage: qr).draw(in: CGRect(x: (size.width - side) / 2, y: 530,
                                               width: side, height: side))
        }
    }
}
#endif
