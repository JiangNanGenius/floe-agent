# Pencil palette placement qualification

This small app compiles the **production** `NotesPalettePresentation.swift`
presenter, radial tool wheel and button style without the full Floe application. A PencilKit
viewport presents the production circular tool wheel at its top, center and bottom.
The UI case requires visible, hittable controls, 44-point targets (with half a
point of AX rounding tolerance), tool selection with immediate dismissal, retained selection highlighting, and cancel without changing tools on iPad and iPhone.

This qualifies the page overlay boundary only. It does not establish Notes
import, document persistence, full-App routing or physical Pencil gesture
delivery. The complete App Notes UI gate must still pass before distribution.

Generate with `xcodegen generate --spec project.yml`. Run the generated
`FloePencilPaletteQualification` scheme against a chosen simulator using
`xcodebuild test -parallel-testing-enabled NO`; use a fresh result-bundle path
and a task-owned DerivedData directory. Repeat on an iPad and an iPhone.
The test saves an original screenshot for each anchor.

The Feedback component UI workflow accepts `palette_only=true` for this small
iPad/iPhone gate on SDK 27 and the accepted SDK 26, without compiling the full
application. This gate does not replace the full-App release checks.

The wheel contains pen, highlighter, eraser, lasso and AI selection in fixed positions, with cancel in its center. Color and width remain in the main writing toolbar.

The circle is placed directly over the visible page and clamped at its edges; it does not use a system popover. Tests require the wheel to disappear after selection and cancellation, including selecting an already active tool. The component step allows cold simulator startup separately from its bounded test-case allowance.
