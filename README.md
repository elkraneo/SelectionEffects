# SelectionEffects

Selection effects for RealityKit entities, shaped like RealityKit's `HoverEffectComponent`: add a component to select an entity, remove it to deselect. Effects are drawn as a Metal post-process, so they keep a constant pixel width, follow moving entities, and never modify your scene.

## Install

```swift
.package(url: "https://github.com/elkraneo/SelectionEffects.git", from: "0.1.0")
```

| | `RealityView` (SwiftUI) | `ARView` (UIKit / AppKit) |
|---|---|---|
| iOS | 26+ | 15+ |
| macOS | 26+ | 12+ |
| tvOS | 26+ | 26+ |
| visionOS | 1+, `.shader` only | — |

RealityKit has no post-processing on visionOS, so the outline and highlight aren't available there; `.shader` effects are. `.shader` needs iOS 18, macOS 15 or tvOS 26 (Shader Graph materials).

## Select an entity

```swift
entity.components.set(SelectionEffectComponent())   // outline in the system accent color
entity.components.remove(SelectionEffectComponent.self)
```

Three effects, as with `HoverEffectComponent`'s spotlight, highlight and shader:

```swift
// Outline: color, width in pixels, and how visible it is behind other geometry
// (1 = X-ray, 0 = hidden, 0.3 = Reality Composer Pro's look).
SelectionEffectComponent(.outline(.init(color: .systemYellow, width: 3, occludedOpacity: 0.3)))

// Highlight: a translucent fill over the entity.
SelectionEffectComponent(.highlight(.init(color: .systemOrange, strength: 0.4)))

// Shader: your own look, built in a Shader Graph material.
SelectionEffectComponent(.shader(.init(fadeInDuration: 0.2, fadeOutDuration: 0.2)))
```

### Your own look

`.shader` works like `HoverEffectComponent`'s `.shader`. While the entity is selected, the float input `SelectionIntensity` of its Shader Graph materials fades from 0 to 1, and back to 0 after you remove the component. Add that input to your material in Reality Composer Pro and build any look from it: a glow, a tint, a pulse, a dissolve. [Docs/SelectionShaderTemplate.usda](Docs/SelectionShaderTemplate.usda) is a minimal material that blends gray to orange. Set `parameterName:` to use a different input name.

Unlike the outline and highlight, this effect writes to the entity's materials. Materials without the input are left unchanged.

A `nil` color uses the system accent color. Each entity can have its own effect. `meshSelection:` chooses which meshes in the entity's hierarchy are drawn: all of them (the default), the nearest ones, or descendants first (for USD prims that carry an aggregate mesh).

## Draw the effects

Install them once per view. On visionOS, `content.installSelectionEffects()` only starts the system that drives `.shader` effects.

**RealityView**, in the make closure. The scene needs a camera entity with `PerspectiveCameraComponent`:

```swift
RealityView { content in
    content.installSelectionEffects()
    // add your camera and content
}
```

This sets the view's custom post-processing effect, replacing any other one.

**ARView**:

```swift
arView.installSelectionEffects()
arView.removeSelectionEffects()
```

Render callbacks you've already set are kept and run before the effects.

## Notes

- Call `SelectionEffectComponent.preloadGeometry(of:)` after loading selectable entities. The first read of a mesh is slow (~100 ms for 46k vertices); selecting is ~1 ms after that.
- For content edited in place (e.g. a live USD stage), install with `cachesGeometry: false`.
- On macOS 27, setting a `RealityView`'s `customPostProcessing` before the view has rendered crashes inside RealityKit, even with a pass-through effect. `installSelectionEffects()` works around it by attaching on the first frame. Details and a standalone reproduction: [Docs/PostProcessTiming.md](Docs/PostProcessTiming.md).
- Run-tested on macOS 27, with RealityView and ARView, including `.shader`. iOS, tvOS and visionOS are build-tested.

How the API relates to hover effects, Hydra and Reality Composer Pro: [Docs/Precedents.md](Docs/Precedents.md). The outline technique is explained in [RealityKit Outline Selection](https://elkraneo.com/realitykit-outline-selection/). It began as [PostProcessOutline](https://github.com/elkraneo/PostProcessOutline), which remains available as a standalone renderer.

See [`Examples/`](Examples) for a working app with both views.

## License

This project is available under the MIT license.
See the LICENSE file for more info.
