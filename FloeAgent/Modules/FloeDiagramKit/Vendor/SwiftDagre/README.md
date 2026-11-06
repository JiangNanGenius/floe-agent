<div align="center">

# SwiftDagre

**Directed acyclic graph layout algorithm for Swift**

A pure Swift port of [dagrejs/dagre](https://github.com/dagrejs/dagre) for laying out directed graphs.

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20|%20macOS-blue.svg)](https://developer.apple.com)
[![SPM Compatible](https://img.shields.io/badge/SPM-Compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>

## Overview

SwiftDagre provides algorithms for laying out directed graphs on a plane. Given a set of nodes and edges, it calculates optimal positions for each node to minimize edge crossings and create readable graph visualizations.

This is a faithful port of the JavaScript [dagre](https://github.com/dagrejs/dagre) library, preserving the same algorithms and behavior.

## Features

- **Network simplex** ranking algorithm
- **Barycenter** ordering heuristic for minimizing edge crossings
- **Brandes-Köpf** coordinate assignment for balanced layouts
- **Compound graphs** with subgraph support
- **Edge labels** with automatic positioning
- **Multiple layout directions** (TB, BT, LR, RL)

## Installation

### Swift Package Manager

Add SwiftDagre to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/lukilabs/dagre-swift", from: "0.1.0")
]
```

Then add it to your target dependencies:

```swift
.target(
    name: "YourTarget",
    dependencies: [.product(name: "SwiftDagre", package: "dagre-swift")]
)
```

## Quick Start

```swift
import SwiftDagre

// Create a graph
let graph = Graph<String, DagreNodeLabel, DagreEdgeLabel>(
    isDirected: true,
    isCompound: false,
    isMultigraph: false
)

// Set graph options
graph.setGraph(DagreGraphLabel(
    rankdir: .TB,
    nodesep: 50,
    ranksep: 50
))

// Add nodes
graph.setNode("a", DagreNodeLabel(width: 100, height: 50))
graph.setNode("b", DagreNodeLabel(width: 100, height: 50))
graph.setNode("c", DagreNodeLabel(width: 100, height: 50))

// Add edges
graph.setEdge("a", "b", DagreEdgeLabel())
graph.setEdge("b", "c", DagreEdgeLabel())

// Run layout
Layout.layout(graph)

// Access computed positions
for node in graph.nodes() {
    if let label = graph.node(node) {
        print("\(node): x=\(label.x ?? 0), y=\(label.y ?? 0)")
    }
}
```

## Important: Mutable Labels

`DagreNodeLabel` and `DagreEdgeLabel` are **reference types** (classes), not value types. This means:

- Calling `Layout.layout(graph)` **mutates your original labels in-place**
- The `x`, `y`, and `points` properties are written directly to your label objects
- If you need a "before" snapshot, copy your labels before calling `layout()`

```swift
// Labels are mutated in-place
let label = DagreNodeLabel(width: 100, height: 50)
graph.setNode("a", label)

Layout.layout(graph)

// label.x and label.y are now set
print(label.x!)  // Computed X position
```

## Layout Options

Configure the graph layout with `DagreGraphLabel`:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `rankdir` | `Rankdir` | `.TB` | Direction: `.TB`, `.BT`, `.LR`, `.RL` |
| `nodesep` | `Double` | `50` | Horizontal spacing between nodes |
| `ranksep` | `Double` | `50` | Vertical spacing between ranks |
| `edgesep` | `Double` | `10` | Spacing between edges |
| `marginx` | `Double` | `0` | Horizontal margin |
| `marginy` | `Double` | `0` | Vertical margin |
| `acyclicer` | `Acyclicer` | `.greedy` | Cycle removal algorithm |
| `ranker` | `Ranker` | `.networkSimplex` | Ranking algorithm |

## Node Labels

Configure individual nodes with `DagreNodeLabel`:

```swift
DagreNodeLabel(
    width: 100,    // Required: node width
    height: 50     // Required: node height
)
```

After layout, the label will have computed `x` and `y` coordinates.

## Edge Labels

Configure edges with `DagreEdgeLabel`:

```swift
DagreEdgeLabel(
    minlen: 1,           // Minimum edge length (in ranks)
    weight: 1,           // Edge weight for layout
    width: 0,            // Label width (if any)
    height: 0,           // Label height (if any)
    labelpos: .center,   // Label position: .left, .center, .right
    labeloffset: 10      // Label offset from edge
)
```

After layout, the label will have computed `x`, `y`, and `points` for edge routing.

## Compound Graphs

SwiftDagre supports compound graphs where nodes can contain other nodes:

```swift
let graph = Graph<String, DagreNodeLabel, DagreEdgeLabel>(
    isDirected: true,
    isCompound: true,
    isMultigraph: false
)

// Create parent-child relationships
graph.setNode("group1", DagreNodeLabel(width: 0, height: 0))
graph.setNode("a", DagreNodeLabel(width: 100, height: 50))
graph.setNode("b", DagreNodeLabel(width: 100, height: 50))

graph.setParent("a", "group1")
graph.setParent("b", "group1")
```

## Algorithm Details

SwiftDagre uses a multi-phase layout algorithm:

1. **Cycle Removal** - Temporarily reverses edges to create a DAG (O(V + E))
2. **Rank Assignment** - Uses network simplex to assign vertical ranks (O(V × E))
3. **Ordering** - Minimizes edge crossings using barycenter heuristic (O(V × E × iterations))
4. **Coordinate Assignment** - Brandes-Köpf algorithm for horizontal positions (O(V + E))

For typical graphs (< 1000 nodes), layout completes in milliseconds. Very large or dense graphs may take longer.

## Limitations

- **Thread Safety**: The library uses internal mutable state. Do not call `layout()` concurrently from multiple threads on the same graph.
- **Cyclic Graphs**: Cycles are handled by temporarily reversing edges, which may produce suboptimal layouts for highly cyclic graphs.
- **Disconnected Components**: Disconnected subgraphs are laid out independently and may overlap. Pre-process to separate components if needed.

## Requirements

- Swift 5.9+
- iOS 15+ / macOS 12+ / Mac Catalyst 15+

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [dagrejs/dagre](https://github.com/dagrejs/dagre) - Original JavaScript implementation
- [graphlib](https://github.com/dagrejs/graphlib) - Graph data structure
