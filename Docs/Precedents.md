# Precedents for the API

Why the API looks the way it does, and what Apple's own stacks do. Each claim is labeled with how it was established. "Static" means read from shipped files (SDK interfaces, exported symbols, shader sources), without running or decompiling anything. Checked on macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Reality Composer Pro 3.0.

## RealityKit: `HoverEffectComponent` (SDK interface)

This component is the model for SelectionEffects. It holds one `HoverEffect`, built from a static factory that takes a style:

| `HoverEffectComponent` | `SelectionEffectComponent` |
|---|---|
| `init()`, `init(_ hoverEffect:)` | `init()`, `init(_ selectionEffect:meshSelection:)` |
| `var hoverEffect: HoverEffect` | `var selectionEffect: SelectionEffect` |
| `.highlight(HighlightHoverEffectStyle)` | `.highlight(HighlightSelectionEffectStyle)` |
| `.spotlight(SpotlightHoverEffectStyle)` | none: a spotlight follows where the user looks, which has no meaning for selection |
| `.shader(ShaderHoverEffectInputs)` | planned |
| — | `.outline(OutlineSelectionEffectStyle)` |
| styles: `static let default`, `init(color: NSColor? = nil, strength: Float = 1)` | styles: `static var default`, `init(color: Color? = nil, …)` with the platform color |

Hover and selection differ in who decides. Hover is input state owned by the system; on visionOS the system draws hover effects without telling the app where the user is looking, so apps can't build them themselves. Selection is app state, so the app decides what's selected and when.

## OpenUSD Hydra: one machinery, two modes (static, exported symbols)

Apple's `/usr/lib/usd/libusd_ms.dylib` exports `HdSelection::HighlightMode` with exactly two cases: `HighlightModeSelect` and `HighlightModeLocate`. In Hydra, "locate" means rollover, i.e. hover. Pixar's renderer treats selection and hover as two modes of the same highlighting machinery. Hydra's shaders also name the case of selected geometry hidden behind other geometry "occluded selection" (`renderPassColorWithOccludedSelectionShader`). That's where `occludedOpacity` gets its name.

## Reality Composer Pro 3.0's outline (static, shader source)

The viewport outline is drawn by `selection_composite.omsl` in RCP's tool layer, which uses The Machinery engine (`libtm-*` libraries). According to its comments:

- The outline comes from comparing entity IDs between each pixel and its neighbors.
- It has a single parameter, `tm_selection_outline_color`.
- It samples the selection depth in a neighborhood and keeps the closest value, "to combat TAA jittering artifacts".
- Where the outline is behind other geometry, it "reduce[s] its alpha value to 30%".

SelectionEffects borrows the last two: `occludedOpacity: 0.3` reproduces RCP's look, and the occlusion test uses the same neighborhood idea.

## RealityKit's engine: a private selection render graph (static; purpose inferred)

CoreRE, the engine under RealityKit, ships `BuiltinRenderGraphResources/Common/selection.rerendergraph` and exports `RERenderGraphSelectionEmitterSetFilteredEntityIDs` and `…SetParams`. The graph writes eight color targets in four render groups (`SelectionRenderGroup01` … `67`). That layout looks like GPU picking (an entity-ID buffer used to find what's under the cursor) rather than an outline. This is an inference and hasn't been run. None of it is public API.
