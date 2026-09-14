# Pencil palette placement qualification

This small app compiles the **production** `NotesPalettePresentation.swift`
presenter and button style without the full Floe application. A PencilKit
viewport presents a deliberately tall palette at its top, center and bottom.
The UI case requires visible, hittable controls, 44-point targets (with half a
point of AX rounding tolerance), selection and dismissal on iPad and iPhone.

This qualifies the presentation boundary only. It does not establish Notes
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
