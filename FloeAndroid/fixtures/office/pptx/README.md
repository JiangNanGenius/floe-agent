# PPTX fixtures

`two-slides.pptx` is the unchanged G01 parser fixture. Its placeholders have no explicit or inherited geometry; it is not a visible-content render sample.

`two-slides-preview.pptx` is a self-authored render fixture with explicit geometry, text, colors and line markers on two slides. Reproduce or read-only check it with `python3 generate_two_slides_preview.py [--check] two-slides-preview.pptx`. The generator uses only the Python standard library.

The native Android candidate displayed both pages offline. This representative observation does not establish editing, save, export or complete OOXML compatibility.
