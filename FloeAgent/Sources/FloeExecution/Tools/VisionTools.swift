// FloeExecution — OCR and barcode tools using Apple Vision.
//
// Provides text recognition (OCR) and barcode/QR code scanning from images.
// Uses the Vision framework for on-device, private, fast recognition.

import Foundation
import Crypto
import FloeCore
import FloeTools

#if canImport(Vision)
import Vision
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Resolves the two supported vision inputs without exposing arbitrary file
/// URLs. Workspace paths stay inside the task root and respect its file
/// ceiling; inline data is bounded before image decoding.
private enum WorkspaceVisionInput {
    static let maximumBytes = 10 * 1_024 * 1_024

    static func load(base64: String?, path: String?, context: ToolContext) throws -> Data {
        if let base64, !base64.isEmpty {
            guard let data = Data(base64Encoded: base64), !data.isEmpty else {
                throw FloeError.validationFailed("imageBase64 must be valid base64 image data")
            }
            guard data.count <= maximumBytes else {
                throw FloeError.validationFailed("Image exceeds the 10 MiB OCR limit")
            }
            return data
        }

        guard let path else {
            throw FloeError.validationFailed("No image input was supplied")
        }
        try context.authorizeWorkspacePath(path)
        guard let root = context.workspaceRootURL else {
            throw FloeError.validationFailed("No task workspace is available")
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            throw FloeError.validationFailed("path must be relative to the task workspace")
        }
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let normalized = (trimmed as NSString).standardizingPath
        let imageURL = rootURL.appendingPathComponent(normalized).resolvingSymlinksInPath()
        guard imageURL.path == rootURL.path || imageURL.path.hasPrefix(rootURL.path + "/") else {
            throw FloeError.validationFailed("Image path escapes the task workspace")
        }
        let values = try imageURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw FloeError.validationFailed("Image path is not a regular file")
        }
        guard (values.fileSize ?? 0) <= maximumBytes else {
            throw FloeError.validationFailed("Image exceeds the 10 MiB OCR limit")
        }
        return try Data(floeContentsOf: imageURL, options: [.mappedIfSafe])
    }
}

/// OCR tool: recognizes text in an image.
public struct OCRTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var imageBase64: String?
        public var path: String?
        public var language: String?

        public init(imageBase64: String? = nil, path: String? = nil, language: String? = nil) {
            self.imageBase64 = imageBase64
            self.path = path
            self.language = language
        }
    }

    public static let name = "image.ocr"
    public static let toolDescription =
        "Recognize text in a PNG/JPEG image using on-device Apple Vision OCR. Pass either a workspace-relative path (preferred for uploaded files) or base64 bytes. Returns recognized Chinese/English text with bounding boxes."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path to an uploaded PNG/JPEG image, for example Attachments/.../photo.jpg"},
        "imageBase64": {"type": "string", "description": "Base64-encoded PNG/JPEG bytes; omit when path is supplied"},
        "language": {"type": "string", "description": "Recognition language: zh-Hans, zh-Hant, en-US, etc. (default: auto-detect)"}
      },
      "required": [],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    public init() {}

    public func validate(_ args: Arguments) throws {
        let hasBase64 = !(args.imageBase64?.isEmpty ?? true)
        let hasPath = !(args.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard hasBase64 != hasPath else {
            throw FloeError.validationFailed("Supply exactly one of path or imageBase64")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()

        let imageData: Data
        do { imageData = try WorkspaceVisionInput.load(base64: args.imageBase64, path: args.path, context: context) }
        catch { return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2) }

        #if canImport(Vision) && canImport(UIKit)
        guard let cgImage = UIImage(data: imageData)?.cgImage else {
            return Self.output("status=error error=not a readable image", exitStatus: 2)
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        if let language = args.language {
            request.recognitionLanguages = [language]
        } else {
            request.recognitionLanguages = ["zh-Hans", "en-US"]
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            if observations.isEmpty {
                return Self.output("未识别到文字", exitStatus: 0)
            }
            var lines: [String] = []
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let box = observation.boundingBox
                lines.append("\(candidate.string) [\(Int(box.origin.x * 100)),\(Int(box.origin.y * 100)) \(Int(box.width * 100))x\(Int(box.height * 100))]")
            }
            return Self.output("识别到 \(observations.count) 行文字：\n" + lines.joined(separator: "\n"), exitStatus: 0)
        } catch {
            return Self.output("OCR 失败：\(error.localizedDescription)", exitStatus: 2)
        }
        #else
        return Self.output("status=error error=Vision framework not available", exitStatus: 2)
        #endif
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}

/// Barcode/QR code scanner tool.
public struct BarcodeScanTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var imageBase64: String?
        public var path: String?

        public init(imageBase64: String? = nil, path: String? = nil) {
            self.imageBase64 = imageBase64
            self.path = path
        }
    }

    public static let name = "image.scanBarcode"
    public static let toolDescription =
        "Scan barcodes and QR codes in a PNG/JPEG image using on-device Apple Vision. Pass a workspace-relative path (preferred) or base64 bytes."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path to an uploaded PNG/JPEG image"},
        "imageBase64": {"type": "string", "description": "Base64-encoded PNG/JPEG bytes; omit when path is supplied"}
      },
      "required": [],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    public init() {}

    public func validate(_ args: Arguments) throws {
        let hasBase64 = !(args.imageBase64?.isEmpty ?? true)
        let hasPath = !(args.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard hasBase64 != hasPath else {
            throw FloeError.validationFailed("Supply exactly one of path or imageBase64")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()

        let imageData: Data
        do { imageData = try WorkspaceVisionInput.load(base64: args.imageBase64, path: args.path, context: context) }
        catch { return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2) }

        #if canImport(Vision) && canImport(UIKit)
        guard let cgImage = UIImage(data: imageData)?.cgImage else {
            return Self.output("status=error error=not a readable image", exitStatus: 2)
        }

        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            if observations.isEmpty {
                return Self.output("未识别到条码/二维码", exitStatus: 0)
            }
            var lines: [String] = []
            for observation in observations {
                let content = observation.payloadStringValue ?? "(无法解码)"
                let type = observation.symbology.rawValue
                lines.append("- [\(type)] \(content)")
            }
            return Self.output("识别到 \(observations.count) 个条码/二维码：\n" + lines.joined(separator: "\n"), exitStatus: 0)
        } catch {
            return Self.output("扫描失败：\(error.localizedDescription)", exitStatus: 2)
        }
        #else
        return Self.output("status=error error=Vision framework not available", exitStatus: 2)
        #endif
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}
