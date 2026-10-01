# TestFlight App Review notes — Floe Agent (Build 241)

> Status: **draft, not submitted.** This is internal preparation text, not the final product review notes. The `public-testflight` helper refuses this file for `submit` while this banner is present, so it cannot be submitted accidentally. After the main thread freezes the source, replace the banner with the frozen version/build and tag/SHA line and remove the draft marker.

App: Floe Agent, `org.floeagent.ios`. Platform: iPadOS with iPhone support (iPad first).

## Navigation

The sidebar opens on New Task and Task Center. Notes, Creative Mode and Plugins are the other primary areas; Settings is at the bottom. Notes is a separate document workspace; model configuration is shared with the rest of the app.

## Review access and model use

- Cloud AI is optional and bring-your-own-key (BYOK). The app ships no provider key and no credit; connecting your own provider may incur third-party charges.
- Notes, PDF annotation, document organization and Canvas work without connecting any AI service.
- On-device inference uses open MLX local models that the user downloads from Settings. These downloaded models are Beta, optional and not recommended as a daily default; download size and memory depend on the model. A text answer does not imply vision or the full tool inventory.
- Apple's system model, when available on the device, is a separate path and is not labeled Beta.

## Suggested walkthrough

1. Notes and PDF: open Notes, create a blank note or import a sample document, enter full-screen editing, write an annotation, close and reopen it, and confirm the annotation persisted. Switch document tabs and search library text.
2. Documents: open a prepared Word, Excel or PowerPoint sample. When an original-layout preview is unavailable the card shows a labelled summary; that fallback is not an original-layout preview.
3. Canvas: create and arrange a canvas, then verify the content after relaunch.
4. Task execution (optional, BYOK): with a provider you configure yourself, run a short multi-turn task, watch tool progress and stop execution; confirm settings persist after relaunch.

## Data and feedback

Cloud AI sends conversation context and relevant attachments to the provider the user configured. Credentials stay in the app's approved credential storage and are not placed in public descriptions, What to Test or default settings. Feedback is sent from inside the app after Submit, with optional diagnostics or images; ask testers to redact keys and private content before sharing screenshots.
