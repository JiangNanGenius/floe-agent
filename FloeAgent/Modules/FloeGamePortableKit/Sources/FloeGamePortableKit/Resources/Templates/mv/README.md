# Floe RPG Maker MV starter

Original, RTP-free content authored for the portable Floe runtime. The project
uses the official MIT RPG Maker MV CoreScript at commit
`182e31449707ba7e406db0485c44c2a9d11e2dcd`; the core and its reviewed web
libraries are merged from an on-demand prepared resource, not stored here.

- Entry after assembly: `index.html`
- Keyboard declaration: `floe-inputs.json` (arrows; Z/Enter/Space confirm,
  X/Escape cancel, Shift dash, Q/W page up/down)
- Adapter: `js/floe_bridge.js` reports ready after the original runtime reaches
  `Scene_Map` and implements snapshot/restore with `DataManager.makeSaveContents`.
- No RTP, editor assets, MZ runtime, native plugin or proprietary sample is included.
