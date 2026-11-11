<!-- docs-updated: 2026-11-12 -->
# Models, tasks and files

These workflows apply to both editions of Floe. Installation, menu locations, device access, local models and editors are covered by each platform's own guide. A shared workflow does not mean every platform has the same tools.

<!-- doc-anchor: section-1 -->
## 1. Connect a cloud model

Bring your own model provider account and API key. Floe is a client; the selected provider handles cloud requests, pricing and its own data policies. Do not enter a website password in the API key field.

1. Add a provider in model settings. Select the service and protocol, then enter its documented base URL and API key.
2. Add or refresh the model list and select a model for the task. When the task needs to read pictures, choose a model that accepts image input. Image generation and video generation require a service that supports that purpose.
3. Test a short text conversation before attaching files or starting a long task.

For authentication failures, check the endpoint, key, account access and the actual provider error. For an unsupported model or input type, select an appropriate model. A successful connection test does not verify every tool or media capability.

<!-- doc-anchor: section-2 -->
## 2. Ask for a useful result

1. Create a task and select its workspace. Add a non-sensitive test file through the file picker.
2. State the intended result, the input and where to save it. For example: “Read this document, turn it into a checklist and save it in the current workspace.”
3. Review requests for access to files or tools. Give access to the material needed for this task.
4. Open the output, check its content and location, then close and reopen it to confirm it was saved.

When correcting a result, describe the specific change and refer to the existing file. Keep the task and workspace consistent so the assistant can continue the same work. A tool's success message is a cue to check the result, not a substitute for opening it.

<!-- doc-anchor: section-3 -->
## 3. Keep files and changes safe

Import only files you want the task to use. If an external location becomes unavailable, select and authorize the original location again rather than silently moving the work to another folder.

Confirm saving in the editor you used. Export and Save As create a separate result and do not automatically replace the original. If another editor has changed a file, preserve unsaved drafts and review the conflict before overwriting either copy. Keep independent backups of important work.

Commands and software installation use the task's selected execution environment. Check the current directory and output before assuming a command changed the intended file. Available environments, installation steps and background behavior depend on the platform and installed version.

<!-- doc-anchor: section-4 -->
## 4. Use tools with context

Documents, web pages and tool results are input material; their text does not grant permission to execute commands, access other files or send information. Review the actual action and destination before approving an external operation.

Read progress and failures in the task's run record. Hiding a panel does not necessarily stop the job or service it displays. Use the task or service's stop control when work should end; the operating system still controls background execution.

<!-- doc-anchor: section-5 -->
## 5. Report an issue

Use [GitHub Issues](https://github.com/JiangNanGenius/floe-agent/issues) for bug reports and feature requests. Include the installed version, device and OS, steps, expected result and actual result. State which file or task was affected without publishing private content.

Diagnostics and screenshots are optional. Submit only the necessary material and remove keys, passwords, personal data and private files. In-app diagnostic uploads provide troubleshooting material and do not guarantee an individual response. For cloud-service errors, include a redacted provider error rather than your API key.
