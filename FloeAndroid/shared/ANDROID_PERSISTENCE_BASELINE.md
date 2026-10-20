# Android persistence baseline

Android currently uses the verified v46 DatabaseManager body as a platform-owned
mirror at Sources/FloePersistence/DatabaseManager.swift. Its contents match the
first Android alpha's compiled source. The iOS source has advanced to the v47
Shortcuts inbox migration and remains unchanged by Android integration.

Port the v47 migration, ShortcutInbox models and store together with focused
migration checks when Android adopts that inbox. Do not repoint this file at a
new upstream manager without its registered migration dependencies. Other shared
sources continue to use their existing reviewed links and mirrors.
