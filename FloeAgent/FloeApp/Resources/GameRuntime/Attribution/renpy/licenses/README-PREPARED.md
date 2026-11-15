# Prepared Ren'Py 8.5.3 Web (Beta) — Floe distribution profile

- Official web support: `renpy-8.5.3-web.zip`, SHA-256
  `954db897e65f51ea63cb2fb7b203d02be0447f4e22069514020bbe6c6691fdfc`.
- Official arm64 SDK: `renpy-8.5.3-sdkarm.tar.bz2`, SHA-256
  `0579782517f203ba3535dcc2dab54e34bfc318f2f2a7510a5130b6f809f901f6`,
  version `8.5.3.26051504`.
- Build: `renpy.sh launcher web_build <project> --destination <out>`.
- Source pins: Ren'Py `8.5.3.26051504` /
  `39895c1e017f0b36ffea2447d97eccd69d76ee1c`; build repository
  `renpy-8.5.3.26051504` /
  `7bfab40c1174f622f644b24669afd5fb167fbb79`.
- The web glue (`renpy-pre.js`, `manifest.json`, `service-worker.js`) is
  byte-identical to the build tag. The WASM/data are official build outputs;
  a clean byte-identical rebuild was not performed.
- LGPL components actually linked/embedded: FFmpeg 4.3.1, FriBidi 1.0.7,
  chardet 5.2.0, SDL_gfxPrimitives and pygame LGPL portions. Complete
  corresponding source and relink instructions are in
  `licenses/RENPY-8.5.3-COMPONENT-ADDENDUM.md` and the distribution source
  package. The distributor must publish the sources with the binary or provide
  the LGPL §6 written offer.
- Runtime is single-threaded; networking, arbitrary requests and Python
  threading are unavailable. Save data is engine-internal and uses IDBFS at
  `/home/web_user/.renpy`; host persistence is required for durability.
- No tutorial, demo or premium Ren'Py asset is copied.
