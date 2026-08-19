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

/// OCR tool: recognizes text in an image.
public struct OCRTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var imageBase64: String
        public var language: String?

        public init(imageBase64: String, language: String? = nil) {
            self.imageBase64 = imageBase64
            self.language = language
        }
    }

    public static let name = "image.ocr"
    public static let toolDescription =
        "Recognize text in an image using on-device Vision OCR. Returns the recognized text with bounding boxes. Supports Chinese and English."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "imageBase64": {"type": "string", "description": "Base64-encoded image data (PNG/JPEG)"},
        "language": {"type": "string", "description": "Recognition language: zh-Hans, zh-Hant, en-US, etc. (default: auto-detect)"}
      },
      "required": ["imageBase64"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard let data = Data(base64Encoded: args.imageBase64), !data.isEmpty else {
            throw FloeError.validationFailed("imageBase64 must be valid base64 image data")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()

        guard let imageData = Data(base64Encoded: args.imageBase64) else {
            return Self.output("status=error error=invalid base64 image data", exitStatus: 2)
        }

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
        public var imageBase64: String

        public init(imageBase64: String) {
            self.imageBase64 = imageBase64
        }
    }

    public static let name = "image.scanBarcode"
    public static let toolDescription =
        "Scan barcodes and QR codes in an image using on-device Vision. Returns the decoded content and type for each code found."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "imageBase64": {"type": "string", "description": "Base64-encoded image data (PNG/JPEG)"}
      },
      "required": ["imageBase64"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard let data = Data(base64Encoded: args.imageBase64), !data.isEmpty else {
            throw FloeError.validationFailed("imageBase64 must be valid base64 image data")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()

        guard let imageData = Data(base64Encoded: args.imageBase64) else {
            return Self.output("status=error error=invalid base64 image data", exitStatus: 2)
        }

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
