# Display regressions despite passing UI assertions

Source f5ec5bc97173a4169879bb041e380283a8a8326a; run 34730076905; iPad Air 13 M3 simulator, iPadOS 26.2, SDK 26.5/Xcode 26.6.

The 9 component tests and 1 UI test passed, but manual review found a blank PDF backdrop and an incorrectly captured landscape viewport. These images are failure evidence, not product illustrations. The PencilKit backdrop and qualification orientation configuration were corrected; the UI test now checks actual landscape dimensions and OCR of PDF text in the captured screen. Await the new run before accepting those fixes.
