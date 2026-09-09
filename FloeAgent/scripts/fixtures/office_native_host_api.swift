import UIKit
import FloeOfficeNative

@MainActor
func verifyOfficeHostAPI(file: URL, directory: URL) throws -> FloeOfficeNativeViewController {
    let runtime = FloeOfficeNativeRuntime.shared
    let _: Notification.Name = .FloeOfficeNativeRuntimeDidFail
    runtime.prepare { error in _ = error }
    let editor = try FloeOfficeNativeViewController(workingFileURL: file, sessionDirectory: directory, readOnly: true)
    editor.onWorkingCopyOpened = { opened in _ = opened }
    editor.onWorkingCopySaved = { saved in _ = saved }
    editor.onClosed = { closed in _ = closed }
    editor.saveWorkingCopy { error in _ = error }
    editor.cancelPendingSave()
    editor.insertAttachment(fromFileURL: file) { error in _ = error }
    editor.closeWorkingCopy { error in _ = error }
    return editor
}
