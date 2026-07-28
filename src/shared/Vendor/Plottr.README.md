# Plottr

A GUI graph rendering library for Roblox. Client-side, no UI framework dependencies. Strictly typed (`--!strict` throughout), fully animated, and modular. Inspired by [boatbeaker/GraphModule](https://github.com/boatbeaker/GraphModule).

**[Documentation and API reference →](https://alternativelua.github.io/Plottr/)**

## Install

```toml
[dependencies]
Plottr = "alternativelua/plottr@0.2.0"
```

Or copy `src` into your project as `ReplicatedStorage.Plottr`.

## Quick start

```lua
local Plottr = require(ReplicatedStorage.Plottr)

local graph = Plottr.new(containerFrame, {
    theme = Plottr.Themes.Midnight,
    xLabels = { "Jan", "Feb", "Mar", "Apr", "May", "Jun" },
})

graph:setSeries({
    { name = "Revenue", values = { 4200, 5100, 4800, 6900, 8400, 9600 } },
    { name = "Costs", values = { 3100, 3300, 3600, 4100, 4400, 4900 }, kind = "bar" },
})
```

The graph animates in, re-renders whenever data or config changes, and redraws
on container resize. Line and bar series, gradient infill, curve smoothing,
hover and touch tooltips, a toggleable legend, axis titles, pinned axis ranges,
realtime streaming, and grid dashboards — all covered in the
[docs](https://alternativelua.github.io/Plottr/).

## Module layout

```
src/
├── init.luau            -- public entry point + exported types
├── Types.luau           -- all public type definitions
├── Themes.luau          -- theme presets + Themes.extend
├── Graph.luau           -- graph class: layout, scheduling, orchestration
├── GraphGroup.luau      -- grid layout for multi-graph dashboards
├── Internal/
│   ├── Constants.luau   -- layout metrics, text defaults, the None sentinel
│   ├── Layout.luau      -- data summaries, y range, plot rect, x placement
│   ├── Validate.luau    -- argument checking and config clamping
│   ├── Scale.luau       -- nice-tick math, range mapping, value formatting
│   ├── Smooth.luau      -- monotone cubic curve smoothing for line paths
│   ├── Pool.luau        -- recycles a render's instances for the next one
│   ├── Animator.luau    -- TweenService wrapper honouring AnimationConfig
│   └── Trove.luau       -- cleanup collector
└── Renderers/
    ├── Axes.luau        -- grid lines, baseline, tick labels, titles
    ├── LineRenderer.luau -- antialiased Path2D stroke + hoverable points
    ├── AreaRenderer.luau -- gradient infill between a line and the baseline
    └── BarRenderer.luau  -- rounded bars growing from the baseline
```

## Development

```sh
aftman install       # rojo, wally, stylua, luau-lsp
wally install        # dev dependencies (TestEZ)
rojo serve dev.project.json
```

Open the place in Studio and hit Play — `test/TestRunner.client.luau` runs the
TestEZ specs and `test/Demo.client.luau` shows a live animated demo.

Format with `stylua src test`; type-check with
`luau-lsp analyze --defs=<globalTypes.d.luau> --sourcemap=sourcemap.json src`.
CI runs both, plus Moonwave doc extraction and a Rojo build, on every push and
pull request. The specs need a Roblox runtime, so they run in Studio.

API documentation lives in [Moonwave](https://eryn.io/moonwave/) doc comments
in the source; `moonwave dev` previews the site locally.
