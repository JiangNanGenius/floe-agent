# Floe Ren'Py starter

Original Ren'Py 8.5.3 project. Build it through the official launcher CLI:

```
renpy.sh launcher web_build <project> --destination <out>
```

- Input: arrows focus; Enter/Space advance; Escape menu; Ctrl skip; Tab toggle
  skip; PageUp/PageDown rollback/rollforward.
- This original starter adds Save/F5, Load/F9 and Continue. These bindings are
  declared by this project; imported games retain their own input declarations.
- The official Web (Beta) runtime is single-threaded; networking and arbitrary
  requests are unavailable. Host snapshot is unavailable; Ren'Py's own saves
  remain inside the browser runtime.
