import UIKit
import FloeOfficeNative

@MainActor
func verifyOfficeHostAPI(file: URL, directory: URL) throws -> FloeOfficeNativeViewController {
    let runtime = FloeOfficeNativeRuntime.shared
    runtime.prepare { error in _ = error }
    let editor = try FloeOfficeNativeViewController(workingFileURL: file, sessionDirectory: directory, readOnly: true)
    editor.onWorkingCopyOpened = { opened in _ = opened }
    editor.onWorkingCopySaved = { saved in _ = saved }
    editor.onClosed = { closed in _ = closed }
    return editor
}
