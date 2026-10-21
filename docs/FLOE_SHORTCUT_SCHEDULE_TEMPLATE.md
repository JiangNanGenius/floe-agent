# Scheduled-task Shortcut template

`FloeAgent/FloeApp/Resources/Shortcuts/FloeScheduledTask.shortcut` is an Apple-signed template containing one `RunScheduledTaskIntent` action. Its required schedule entity starts unset. The native import question asks the recipient to choose a Floe plan; the saved entity carries the plan's stable ID. No title-based execution fallback, real plan, task prompt or account data is embedded.

The adjacent `FloeScheduledTask.source.plist` is the unsigned source. Only the signed file is bundled, explicitly through `project.yml`. To update it, author the action and its Schedule import question in system Shortcuts, preserve the native `ParameterKey`, and sign the source with Apple's `shortcuts sign --mode anyone --input <absolute-input> --output <absolute-output>`. Use task-owned internal build-cache paths for signing, then copy the verified result into the resource directory. The signing operation validates sharing with Apple; it does not prove the recipient's plan binding or execution.

Floe hands the file to the system, with a share-sheet fallback. System confirmation remains required. An opened page or completed share is recorded as a possible setup, never as a detected installation. Creating a time automation is a separate step. When a monitored plan is deleted or a one-shot run terminates, a durable reminder asks the user to remove its Shortcut and automation. Pausing a plan and finishing one occurrence of a recurring plan do not retire the plan. The user's removal or dismissal marks record their own choice; Floe does not claim it can inspect or delete system Shortcuts.

The source preserves the system-authored required-entity route. A stale trigger cannot select a newly created plan with the same title, skip the due check, or bypass occurrence claims and permissions.

Apple references: [sharing signed Shortcut files](https://support.apple.com/guide/shortcuts/share-shortcuts-apdf01f8c054/ios), [import questions](https://support.apple.com/guide/shortcuts/add-import-questions-to-shared-shortcuts-apdf330fd3a0/ios), [supported URL routes](https://support.apple.com/guide/shortcuts/open-create-and-run-a-shortcut-apda283236d7/ios), and [deleting Shortcuts in the system app](https://support.apple.com/guide/shortcuts/delete-shortcuts-apd096cd65c6/ios).

## Acceptance boundary

The initial real import accepted the signed action but lost its configuration question because an incorrectly renamed field was ignored. That candidate is not bundled. The corrected signed template displays the native setup page and its bilingual plan question. Full-App import handoff, selected-entity persistence, terminal cleanup and stale-trigger behavior require their own recorded checks; successful signing alone does not complete them. Physical-device background timing is separately qualified.
