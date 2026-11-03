# Independent surface workflow qualification

M17 retains its original criterion: open-section native surface loft, trim,
patch and sew/closure checks, exact thickness, undo, rebuild and storage reopening.

Eight `CADLoftSurfaceWorkflowTests` passed in the actual App on the canonical iPad
Simulator at source `d2c6cbc331eeaca3018bb5533711892b52623fc1`. These cover native
geometry and D2 measurements, inner loops and section order, patch/sew/thicken,
undo, future-format preservation and atomic failure. The shared native301 batch
also contained two unrelated failures; it was not an all-green batch.

The original
`CADLoftSurfaceFormAcceptanceUITests/testRealSurfaceCreateTrimThickenUndoSaveReopenAndSameHistoryEdit`
then passed on the same canonical iPad Simulator at
`9444a20b2aec7482a6ddc9c99c5667ca49f4c9d1` (App329/UI311). The form reuses
`ExpressionValueField`; the original value, rebuild, undo and cold-reopen
assertions remain. Other UI311 cases failed and retain their original evidence.

Xcode 27.1 / 27A9275, Swift 6; actual App compilation preceded both runs.
Unchanged surface contracts were reused instead of repeated. This is Simulator
acceptance, not physical Pencil, complex-model performance or the separate M30
same-target real-model acceptance.
