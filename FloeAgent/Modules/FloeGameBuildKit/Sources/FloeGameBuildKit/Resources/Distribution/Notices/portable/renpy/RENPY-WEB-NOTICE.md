# Ren'Py 8.5.3 Web (Beta) — Floe distribution notice

This notice travels with the official Ren'Py Web runtime prepared by Floe.
It is not a substitute for `RENPY-LICENSE.txt` or the component addendum.

- Runtime: official `renpy-8.5.3-web.zip`, SHA-256
  `954db897e65f51ea63cb2fb7b203d02be0447f4e22069514020bbe6c6691fdfc`.
- Build: official SDK `8.5.3.26051504`
  (`renpy-8.5.3-sdkarm.tar.bz2`, SHA-256
  `0579782517f203ba3535dcc2dab54e34bfc318f2f2a7510a5130b6f809f901f6`),
  `renpy.sh launcher web_build <project> --destination <out>`.
- Source pins: Ren'Py `8.5.3.26051504` /
  `39895c1e017f0b36ffea2447d97eccd69d76ee1c`; build repository
  `renpy-8.5.3.26051504` /
  `7bfab40c1174f622f644b24669afd5fb167fbb79`.
- The Web runtime is single-threaded; networking, arbitrary requests and
  Python threading are unavailable. Safari/iOS support is claimed by Ren'Py,
  not re-verified by this package.
- LGPL components actually linked/embedded: FFmpeg 4.3.1, FriBidi 1.0.7,
  chardet 5.2.0, SDL_gfxPrimitives and pygame LGPL portions. The complete
  corresponding source and relink route are in
  `RENPY-8.5.3-COMPONENT-ADDENDUM.md` and the `source-packages/renpy/`
  directory. The distributor must publish those sources with the binary or
  provide the LGPL §6 written offer.
- Saves use the engine's own IDBFS-mounted save directory. A persistent
  WKWebsiteDataStore and stable per-project origin are required for durability;
  the host's Core storage work owns that, and this notice does not claim it.
- Imported user game assets are user-supplied data. They are not relicensed by
  Floe and are not covered by this notice's MIT/MPL statements.
