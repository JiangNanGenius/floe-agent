import UIKit
import FloeOfficeNative

@MainActor
func verifyOfficeHostAPI(file: URL, directory: URL) throws -> FloeOfficeNativeViewController {
    let runtime = FloeOfficeNativeRuntime.shared
    let _: Notification.Name = .FloeOfficeNativeRuntimeDidFail
    runtime.prepare { error in _ = error }
    let editor = try FloeOfficeNativeViewController(workingFileURL: file, sessionDirectory: directory, readOnly: true)
    editor.onWorkingCopyOpened = { opened in _ = opened }
    editor.onWorkingCopyOpenedWithPermission = { opened, readOnly in _ = (opened, readOnly) }
    editor.onEnginePermissionChanged = { readOnly in _ = readOnly }
    editor.onWorkingCopySaved = { saved in _ = saved }
    editor.onClosed = { closed in _ = closed }
    // Visible-render readiness: the UIDocument open and the engine permission
    // are not render evidence, so the App needs a real painted-surface signal
    // and a bounded failure path.
    editor.onVisibleRenderReady = { docType, elapsed in _ = (docType, elapsed) }
    editor.onVisibleRenderFailed = { error in _ = error }
    // The header declares NSDictionary<NSString *, id> * _Nullable, which Swift
    // imports as [String: Any]? — annotating NSDictionary? fails the gate.
    let _: [String: Any]? = editor.renderDiagnostics
    let diagnostics = editor.renderDiagnostics ?? [:]
    let _ = diagnostics
    editor.saveWorkingCopy { error in _ = error }
    editor.cancelPendingSave()
    editor.enterEditMode { readOnly, error in _ = (readOnly, error) }
    editor.insertAttachment(fromFileURL: file) { error in _ = error }
    editor.closeWorkingCopy { error in _ = error }
    return editor
}
