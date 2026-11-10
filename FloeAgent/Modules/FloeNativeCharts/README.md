# Floe Native Charts

Two dependency-free Swift 6 products provide native charts inside answers:
`FloeNativeChartsCore` (Foundation data, validation and six layout families) and
`FloeNativeChartsUI` (SwiftUI viewer, CoreGraphics rendering, hit testing and
PNG/PDF export). No tool registration, artifact authorization, storage service
or manual chart editor is included. The App integration owner connects these
products to the existing receipt-bound inline-artifact path.

```swift
import FloeNativeChartsCore
import FloeNativeChartsUI

let source = ChartDocument(type: .scatter, data: .cartesian([
    .init(id: "first", x: .number(1), y: 2),
    .init(id: "second", x: .number(100), y: 3)
]))
let prepared = try ChartValidator.prepare(source)
let view = NativeChartViewer(chart: prepared) // read, filter, zoom, full screen
let scene = try NativeChartSceneBuilder.build(prepared)
let png = try NativeChartExporter.png(scene)
let pdf = try NativeChartExporter.pdf([scene])
let json = try NativeChartExporter.json(prepared) // original, never filtered
```

`ChartCatalog.descriptors` explicitly maps all 40 `ChartKind` cases to their
CH01–CH40 identities and permitted data kinds. The v2 wire format is
`data: {"kind":"cartesian","records":[...]}`. Structured payloads such as
`graph`, `dimensions` and `flowMatrix` use an object in `records`. Coordinates
are `{"kind":"number","value":1}` (or category, instant, localDate).
`ChartDocumentCodec.decode` returns `.v2(PreparedChart)` or
`.legacy(LegacyChartDocument)`. Unknown v2 fields and mismatched payloads fail
with `ChartIssue.path/problem`; the five historical types retain original
categorical labels and values and should use the host's existing legacy view.

Creation and v2 decoding are bounded to 1 MiB, 16 series and 2000 total input
records/scalars/samples, including facets. Legacy decoding retains its 2 MiB
read allowance. Geometry is bounded to 20,000 primitives/vertices and 40,000
source references; graphs have at most 256 nodes and 1024 edges. These limits
are enforced, not silently downsampled. Sankey accepts DAGs; ordinary networks
retain cycles, self edges and signed relationships. Zero-total percentages are
explicit gaps, and flow imbalances remain visible facts.

Numeric/time spacing is continuous, with timezone-aware civil dates and DST.
The independent axis uses ID `x`; a series' `axisID` or ID `y` selects its numeric
value axis. Price-volume charts optionally use a separate `volume` axis. Explicit
domains must enclose supplied/derived values and bar baselines. Multiple value
axes belong to combo charts. Shared small multiples require identical explicit
`x`/`y` domains, units, orientation and timezones; categorical grids must have the
same order. Shared Cartesian axes apply to Cartesian/interval facets; other
families use independent axes. Numeric/time bounds are mandatory for shared
axes, so independently inferred ranges are never presented as a common scale.

Statistics use linear R7 quartiles, Tukey 1.5 IQR sample whiskers, Gaussian KDE
(128 points, explicit bandwidth or recorded Scott bandwidth), and actual bin
edges/counts. Histogram y may be count, probability or density; density accounts
for unequal bin width. Supplied summaries/densities/intervals remain supplied
and are not recomputed or normalized. SMA/EMA periods, seeds and warmup are
explicit. Pie/donut, OHLC/candles, treemap/sunburst/tree, weighted Sankey/chord,
real-time timelines/Gantt and timezone-aware calendar cells use distinct native
geometry. Rare kinds are not substituted with a generic line/bar chart.

`ChartDisplayFilter` derives an ephemeral view from a validated source. It never
replaces the stored document. Percentage/hierarchy views explicitly recompute
visible proportions; price-volume preserves moving-average history and waterfall
preserves cumulative context. `NativeChartHitTester` refines curved/ribbon
bounds against actual paths. `NativeChartViewer` supplies Values, local filters,
zoom/pan, full-screen viewing, PNG/PDF of the current filtered figure and JSON of
the original source. English/Simplified Chinese controls are aligned. The host
still owns artifact UUID/digest, run/conversation receipts, authorization and
cancellation when navigating away from an artifact.

PNG exports are bounded to 8192 pixels per edge, 24 megapixels and 12 MiB; PDFs
are bounded to 16 pages and 16 MiB. Export returns complete bytes or throws;
the viewer uses the native file exporter. No background file writes or external
renderer/service is needed. The App root Package/project are intentionally not
changed by this component package.

Run focused checks with an explicit task-owned cache and the shared native lock:

```sh
python3 Local/Private/shared-native-window/with_native_window.py \
  --label native-charts-tests -- env \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test \
  --package-path FloeAgent/Modules/FloeNativeCharts \
  --scratch-path /absolute/owned/cache/path --jobs 6 -Xswiftc -j6
```
