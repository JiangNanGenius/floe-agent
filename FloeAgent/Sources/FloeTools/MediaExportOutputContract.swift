// FloeTools — the shared media-project export output contract.
//
// ONE derivation of the media.project export destination, consumed by the
// real tool host (`MediaProjectTool`, FloeWorkbench) and the typed
// mutable-target contract (`TypedMutationTargets`) so the approval/authority
// target can never drift from the bytes an export actually writes:
//
//   Workbench/Exports/<file_name>.<extension>
//
// - `file_name` keeps the tool schema's exact validation (a plain basename:
//   no dots, no path separators, 1...200 characters);
// - video exports always land in `.mp4`; image exports use the requested
//   `png`/`jpeg`/`heic` format and an unknown/unsupported format fails closed
//   (no target is claimed);
// - the caller resolves the returned workspace-relative path against the
//   frozen workspace root (the media project host freezes the project's
//   recorded workspace, which the app's `authorizeAccess` requires to equal
//   the run workspace).

import Foundation

public enum MediaExportOutputContract {
    /// Directory every media-project export is written into, relative to the
    /// frozen workspace root.
    public static let directory = "Workbench/Exports"

    /// The only video-container extension the exporter writes.
    public static let videoExtension = "mp4"

    /// Supported image formats and their exact file extensions (must mirror
    /// the renderer's `ImageExportFormat.fileExtension`; a parity test pins
    /// the agreement).
    public static let imageExtensions: [String: String] = [
        "png": "png",
        "jpeg": "jpeg",
        "heic": "heic"
    ]

    /// The tool schema's exact file-name rule: one plain basename, no dots or
    /// punctuation that could name a directory or a second extension.
    public static func isValidFileName(_ raw: String) -> Bool {
        raw.range(of: #"^[A-Za-z0-9][A-Za-z0-9 _-]{0,199}$"#,
                  options: .regularExpression) != nil
    }

    /// The workspace-relative output path for one export specification, or
    /// nil when the specification cannot name a real output (invalid file
    /// name, unknown kind, missing/unsupported image format). A nil result
    /// must leave the write extent unresolved (fail closed), never fall back
    /// to a guessed path.
    public static func relativeOutput(kind: String, fileName: String, format: String?) -> String? {
        guard isValidFileName(fileName) else { return nil }
        switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "video":
            return "\(directory)/\(fileName).\(videoExtension)"
        case "image":
            guard let format = format?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                let ext = imageExtensions[format] else { return nil }
            return "\(directory)/\(fileName).\(ext)"
        default:
            return nil
        }
    }
}
