# Whole-screen capture follow-up

Run 34730814101, source 298576e81ac119a7f694dfe78d7574e8244b1777. The transparent PencilKit fix made actual PDF text visible. SDK 26 iPad passed 9 component tests and 1 UI test; iPhone passed 9 component tests but failed the UI OCR assertion because the landscape application screenshot clipped the upper PDF text. These captures are retained as evidence, not final product illustrations. Capture now uses XCUIScreen from the authorized UI test runner; OCR and actual viewport assertions remain enabled. Initial/resized map viewports also fit their content.
