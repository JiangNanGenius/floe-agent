# Notes full-App simulator evidence

Source: `9e4434ca5bc3440a113b6a3a87fc12d5df9ba2e2`. [Cloud run](https://github.com/JiangNanGenius/floe-agent/actions/runs/34935599831), 15 September 2026. Original screenshots use synthetic documents. They demonstrate the candidate UI, not an uploaded TestFlight build or a real cloud-model conversation.

iPad mini (A17 Pro) and iPhone 17 Pro, SDK 27: workspace import, full-screen PDF, assistant opening, tool palette, tabs and body-search case passed on both devices. Native Office was explicitly skipped because its framework is linked only for iphoneos. Device Office acceptance remains pending.

The dedicated Notes conversation ownership/migration regression passed. Overall App regressions were **170 passed / 1 failed / 0 skipped**: the service test checked its first progress snapshot before asynchronous stdout arrived. HTTP readback, cancellation and preview permission revocation passed. The original failure remains in the retained xcresult; the follow-up keeps the log assertion and waits for log delivery.

See [source, results and image digests](evidence.json).

| View | iPad | iPhone |
| --- | --- | --- |
| Library | [Open](ipad-library.png) | [Open](iphone-library.png) |
| Document assistant | [Open](ipad-document-assistant.png) | [Open](iphone-document-assistant.png) |
| Document tabs | [Open](ipad-document-tabs.png) | [Open](iphone-document-tabs.png) |
| Body search | [Open](ipad-document-body-search.png) | [Open](iphone-document-body-search.png) |
| Brush settings | [Open](ipad-native-brushes.png) | [Open](iphone-native-brushes.png) |
| Pencil quick menu | [Open](ipad-pencil-quick-menu.png) | [Open](iphone-pencil-quick-menu.png) |

These images do not establish physical Pencil squeeze behavior, real inference, native Office editing or final Build 173 acceptance. Original recordings and xcresults are retained privately.
