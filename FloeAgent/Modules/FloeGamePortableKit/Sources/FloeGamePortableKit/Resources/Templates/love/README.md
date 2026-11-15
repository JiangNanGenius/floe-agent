# Floe LÖVE starter

Original Lua game (`main.lua`, `conf.lua`) using only LÖVE 11.4 APIs. It must be
packaged by the pinned love.js 11.4.1 compatibility runtime; this folder is not
a Web artifact by itself.

- Input: arrows move; Z/Space pulse; X reset; S save; L load; Escape quit.
- The generated `floe_bridge.js` reports readiness only after the real
  love.js load finishes and defines typed keyboard/pointer forwarding.
- Host snapshot is unavailable; love.filesystem saves are in-engine only.
