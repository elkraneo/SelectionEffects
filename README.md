# SelectionEffects

Selection effects for RealityKit entities, shaped like RealityKit's `HoverEffectComponent`: add a component to select an entity, remove it to deselect. The outline and highlight are drawn as a Metal post-process: they keep a constant pixel width, follow moving entities, and leave your entities' meshes and materials untouched. The `.shader` effect drives an input of your own materials instead.

## Install

```swift
.package(url: "https://github.com/elkraneo/SelectionEffects.git", from: "0.2.1")
```

| | `RealityView` (SwiftUI) | `ARView` (UIKit / AppKit) |
|---|---|---|
| iOS | 26+ | 15+ |
| macOS | 26+ | 12+ |
| tvOS | 26+ | 26+ |
| visionOS | 1+, `.shader` only | — |

RealityKit has no post-processing on visionOS, so the outline and highlight aren't available there; `.shader` effects are. `.shader` needs iOS 18, macOS 15 or tvOS 26 (Shader Graph materials).

## Overview

Add a `SelectionEffectComponent` to an entity to show that it's selected; remove it to deselect. Unlike `HoverEffectComponent`, which reacts to the person's gaze or pointer, selection is your app's state, so the entity needs no `InputTargetComponent` or `CollisionComponent`.

```swift
entity.components.set(SelectionEffectComponent())   // default: outline in the system accent color
entity.components.remove(SelectionEffectComponent.self)
```

### Hierarchical behavior

The effect applies to the entity's entire hierarchy: its descendants are drawn with it. For USD stages where a parent prim carries an aggregate mesh, `meshSelection:` can draw only the nearest meshes (`.nearestMeshes`) or the descendants first (`.preferDescendants`).

### Styles

`.outline` draws a pixel-exact ring around the silhouette. `width` is in pixels; `occludedOpacity` sets how visible the hidden parts are behind other geometry (`1` X-ray, `0` hidden, `0.3` Reality Composer Pro's look).

```swift
SelectionEffectComponent(.outline(.init(color: .systemYellow, width: 3, occludedOpacity: 0.3)))
```

`.highlight` fills the silhouette with a translucent color. As with `HoverEffectComponent.HighlightHoverEffectStyle`, `strength` defaults to `1`; higher values are stronger.

```swift
SelectionEffectComponent(.highlight(.init(color: .systemOrange, strength: 1.5)))
```

A `nil` color uses the system accent color. Each entity can have its own effect, with a width of at most 32 pixels.

### Shader inputs

`.shader` is for your own look, like `HoverEffectComponent`'s `.shader`. While the entity is selected, the float input `SelectionIntensity` of its `ShaderGraphMaterial`s fades from 0 to 1, and back to 0 after you remove the component. Add that input to your material in Reality Composer Pro's Shader Graph and build any look from it.

```swift
let material = try await ShaderGraphMaterial(named: "/Root/SelectionMaterial", from: "Scene.usda", in: bundle)
entity.model?.materials = [material]
entity.components.set(SelectionEffectComponent(.shader(.init(fadeInDuration: 0.2, fadeOutDuration: 0.2))))
```

[Docs/SelectionShaderTemplate.usda](Docs/SelectionShaderTemplate.usda) is a minimal material that blends gray to orange. Set `parameterName:` to use a different input. Apple's `.shader` drives a built-in Hover State node; third-party code can't add Shader Graph nodes, so this effect writes the material input instead. Materials without the input are left unchanged.

### Differences from HoverEffectComponent

- No `spotlight`: it follows where the person looks, which has no meaning for selection.
- No `GroupID`: your code decides what's selected, so you choose the group when you add the components.
- No `OpacityFunction`: the outline and highlight are drawn after rendering and can't see material opacity, so on transparent materials they draw as if the material were opaque.

## Draw the effects

Install them once per view. On visionOS, `content.installSelectionEffects()` only starts the system that drives `.shader` effects.

**RealityView**, in the make closure. The scene needs a camera entity with `PerspectiveCameraComponent`; pass it as `camera:` if the scene can contain other cameras:

```swift
RealityView { content in
    content.installSelectionEffects()
    // add your camera and content
}
```

This sets the view's custom post-processing effect, replacing any other one. To capture the frame or add your own effect, pass a `frameHandler`: it runs on the render thread with each frame, after the selection effects are encoded. Encode your work into `frame.commandBuffer` before the handler returns, and don't keep the frame afterwards.

```swift
content.installSelectionEffects(frameHandler: { frame in
    // frame.commandBuffer, frame.texture (read or draw), frame.depthTexture
})
```

**ARView**:

```swift
arView.installSelectionEffects()
arView.removeSelectionEffects()
```

Render callbacks you've already set are kept and run before the effects.

## Notes

- Call `SelectionEffectComponent.preloadGeometry(of:)` after loading selectable entities. The first read of a mesh is slow (~100 ms for 46k vertices); later frames reuse it.
- Mesh swaps and hierarchy changes are picked up automatically. After editing a mesh in place (`MeshResource.replace(with:)`, a `LowLevelMesh` buffer update), call `SelectionEffectComponent.reloadGeometry(of:)`.
- Cached geometry of released entities is dropped while any view draws selection effects. `SelectionEffectComponent.clearGeometryCache()` frees it all, for example after closing the last view.
- If your own systems move selected entities, run them before `SelectionEffectSystem` (`static var dependencies: [SystemDependency] { [.before(SelectionEffectSystem.self)] }`), or outlines lag a frame behind.
- `installSelectionEffects()` attaches the post-process on the first frame. On macOS 27, setting a `RealityView`'s `customPostProcessing` before the view has rendered crashes inside RealityKit, even with a pass-through effect. Details and a standalone reproduction: [Docs/PostProcessTiming.md](Docs/PostProcessTiming.md).
- `installSelectionEffects()` adds one hidden entity named `SelectionEffects` to the view's content (it carries the view's renderer).
- Run-tested on macOS 27, with RealityView and ARView, including `.shader`. iOS, tvOS and visionOS are build-tested.

### Known limitations

- RealityKit's entity queries don't return the meshes USDKit's `USDStageComponent` generates (on macOS 27, USDKit marks them hidden through SPI). The system finds selected ones by walking the subtrees of `USDStageComponent` entities every few frames, so their selection can appear up to ~100 ms late. Deselecting is immediate. To find those entities in your own code, use `entity.descendants(where:)` on the stage entity. Details and a standalone reproduction: [Docs/USDKitHiddenEntities.md](Docs/USDKitHiddenEntities.md).
- A USDKit-generated entity that your code moves out of its stage before the next scan isn't found. (Removing `USDStageComponent` removes the generated entities, so this only happens when you reparent them yourself.)
- Instanced meshes (`MeshInstancesComponent`) are outlined once, at the entity's transform, not at each instance.
- Skinned and blend-shape meshes are outlined in their rest pose: the outline doesn't follow skeletal or vertex deformation.
- All selections share one silhouette mask. Where a selected entity is in front of another selected one, the rear entity's ring isn't drawn inside the front one's silhouette, even with `occludedOpacity: 1`.
- At most 127 distinct styles can be drawn at once; extra styles reuse the 127th (a warning is logged).
- Outline cost grows with the square of the width: each frame scans a (2w+1)² neighborhood per pixel. Widths are capped at 32 pixels.
- Every frame, the system walks each selected entity's hierarchy (to pick up mesh, material and hierarchy changes). Very large or deeply nested selections cost main-thread time in proportion.
- `.shader` effects are driven in every scene once the system is registered, like hover effects; `removeSelectionEffects()` stops only the post-process. Remove the component to stop a shader effect.

How the API relates to hover effects, Hydra and Reality Composer Pro: [Docs/Precedents.md](Docs/Precedents.md). The outline technique is explained in [RealityKit Outline Selection](https://elkraneo.com/realitykit-outline-selection/). It began as [PostProcessOutline](https://github.com/elkraneo/PostProcessOutline), which remains available as a standalone renderer.

See [`Examples/`](Examples) for a working app with both views.

## License

This project is available under the MIT license.
See the LICENSE file for more info.
