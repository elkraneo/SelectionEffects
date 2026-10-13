# SelectionEffects

Selection effects for RealityKit entities, modeled on `HoverEffectComponent`: add a component to select an entity, remove it to deselect. The first effect is a pixel-exact outline drawn as a Metal post-process. It keeps a constant pixel width, follows moving entities, and never modifies your scene.

## Install

```swift
.package(url: "https://github.com/elkraneo/SelectionEffects.git", from: "0.1.0")
```

| | `RealityView` (SwiftUI) | `ARView` (UIKit / AppKit) |
|---|---|---|
| iOS | 26+ | 15+ |
| macOS | 26+ | 12+ |
| tvOS | 26+ | 26+ |

visionOS isn't supported yet: RealityKit has no post-processing there.

## Select an entity

```swift
entity.components.set(SelectionEffectComponent(.outline(.init(color: .yellow, width: 3))))
entity.components.remove(SelectionEffectComponent.self)
```

Each entity can have its own color and width (in pixels). `meshes:` chooses which meshes in the entity's hierarchy are drawn: all of them (the default), the nearest ones, or descendants first (for USD prims that carry an aggregate mesh).

## Draw the effects

Install them once per view.

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
- Outlines are X-ray style: they stay visible behind other geometry.
- On macOS 27, setting a `RealityView`'s `customPostProcessing` before the view has rendered crashes inside RealityKit, even with a pass-through effect. `installSelectionEffects()` works around it by attaching on the first frame. Details and a standalone reproduction: [Docs/PostProcessTiming.md](Docs/PostProcessTiming.md).
- Run-tested on macOS 27, with RealityView and ARView. iOS and tvOS are build-tested.

The outline technique is explained in [RealityKit Outline Selection](https://elkraneo.com/realitykit-outline-selection/). It began as [PostProcessOutline](https://github.com/elkraneo/PostProcessOutline), which remains available as a standalone renderer.

See [`Examples/`](Examples) for a working app with both views.

## License

This project is available under the MIT license.
See the LICENSE file for more info.
