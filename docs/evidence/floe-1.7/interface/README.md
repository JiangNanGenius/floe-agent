# Native interface evidence — 2026-09-13

Two XCTest UI tests pass on the owned iPhone 17 Pro / iOS 27 Simulator fixture.
They tap all appearance choices, open reasoning, fold two completed tool calls,
append a third running call, and verify that only the active call remains visible
until the batch is reopened. The default automatic choice was also observed
following a simulator light-to-dark system change without relaunching.

The screenshots compile production components using synthetic conversations and
workspace rows. The surrounding fixture rows are not the full Settings navigation.
Actual appearance settings are under Settings → General. App-level event routing,
real approvals, rich attachments, full navigation, iPad and physical devices require
separate acceptance. The toolbar plus button is a fixture event injector.

- [Light appearance](appearance-light.png)
- [Dark appearance](appearance-dark.png)
- [Automatic appearance](appearance-automatic.png)
- [Expanded tool batch](thread-expanded.png)
- [Folded history with a visible running tool](thread-folded-active.png)
- [Test summary](test-summary.txt) and [source hashes](qualification.json)

The first batch test used a moving fixture button and its synthesized tap missed
that button after the preceding collapse; it was replaced with a fixed toolbar
injector. Custom appearance buttons exposed unstable hit/accessibility behavior;
the production selector now uses the native segmented picker (inline at
accessibility text sizes). The retained passing evidence follows those fixes.
