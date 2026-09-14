# TestFlight App Review notes — next-build draft

Do not submit this draft until the actual build and review access have been confirmed. Replace the bracketed fields; no developer-funded cloud credentials are authorized.

App: Floe Agent, `org.floeagent.ios`.
Submitted version/build: [FINAL VERSION / BUILD].
Contact and model access: [CONFIRMED REVIEW CONTACT AND VERIFIED LOCAL-MODEL / BYOK WALKTHROUGH].

Floe is an iPad-first productivity application with iPhone support. Its primary areas are New Task, Task Center, Notes, Creative Mode and Plugins. Settings is at the bottom of the sidebar. Notes is a separate document workspace; cloud-model configuration is shared with the rest of the app.

Suggested walkthrough:

1. Open Notes. Create a blank note or import the attached sample PDF. Open it for full-screen editing, write an annotation, close and reopen it. Switch document tabs and search text from the library.
2. Tap the current pen or color control to choose a brush and adjust width and opacity. The writing toolbar remains available when the title/header is collapsed. The visible tool-menu button allows testing without Pencil Pro hardware.
3. Follow the verified on-device model instructions attached to this submission [MODEL, HARDWARE, DOWNLOAD AND SUPPORTED CAPABILITIES TO BE VERIFIED]. Return to New Task and ask a short question. Only demonstrate document/tool actions if the selected local model actually supports them. Cloud-provider connections use user-supplied credentials; configuration instructions and a genuine recording are supplementary evidence, not a claim of live reviewer access.
4. Open Creative Mode to create and organize a canvas. Access to remote computers, personal accounts and system permissions is optional; review does not require access to a reviewer's private machine or data.

Cloud AI requests send the selected prompt/context and requested attachments to the configured provider. The submitted privacy information must name the actual data flows and optional services. Local Whisper speech recognition uses an optional downloaded model; when unavailable, the app can fall back to Apple's speech service according to device settings and permissions. Do not interpret all speech paths as offline.

The app includes local shell, Python, JavaScript/Node and supported WASM execution paths. It can process user- or model-created scripts and compatible packages under task/tool permissions. This is not a general Linux virtual machine and environment layering is not native-code process isolation. The submitted build's runtime, package-download behavior and code visibility must be disclosed accurately; no claim is made that the app never executes generated code.

Skills and model resources do not grant their own native permissions. File, network and remote operations use the application's permission mechanisms. Package/model catalogs include unavailable or unqualified entries; only the functionality present and usable in this submitted build is being offered for review.

Before submission, attach the verified local-model and actual review-access steps and synthetic sample files, verify each walkthrough on the selected build, and replace any navigation wording changed in that build. If Apple requires additional access to cloud functionality, explain the BYOK arrangement and resolve the request before claiming review readiness. These review-access requirements follow [Apple's submission guidance](https://developer.apple.com/app-store/review/guidelines/#before-you-submit).

Image generation is an optional integration that requires the user to configure a compatible service. No funded cloud credential of any kind is included in this proposed review setup. The core walkthrough uses Notes and documents plus only the genuinely verified local-model capabilities. Confirm the final access arrangement before submission; if review requests additional access, respond explicitly rather than claiming this draft establishes review completeness.
