# Setting `customPostProcessing` before the first frame crashes

**Status:** Observed on macOS 27.0.1. Not yet reported to Apple (FB number to be added).
**Workaround in this package:** `installSelectionEffects()` attaches the effect on the first `SceneEvents.Update`. See `Sources/SelectionEffects/RealityView+SelectionEffects.swift`.

## Summary

The crash happens when a `RealityView`'s `content.renderingEffects.customPostProcessing` is set before the view has rendered a frame. Apple's documentation says to apply a `PostProcessEffect` to your `RealityViewCameraContent`, and gives no timing rule. Yet setting it in the make closure always traps inside RealityKit, and setting it in `update:` often does.

## Environment

- macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), MacBook Pro M1 (MacBookPro17,1)
- The `RealityView` is hosted in an `NSHostingView` inside an `NSWindow`

## Reproduction

[`PostProcessTimingRepro/`](PostProcessTimingRepro) is a standalone Swift package that uses Apple frameworks only. Its effect does nothing but copy the frame through unchanged.

```sh
cd Docs/PostProcessTimingRepro
swift run PostProcessTimingRepro make       # or: update, deferred
```

Results, 5 runs per mode (exit code 133 = SIGTRAP):

| Where the effect is set | Crashes |
|---|---|
| make closure | 5 of 5 |
| `update:` closure | 2 of 5 |
| first `SceneEvents.Update`, through a copy of `content` | 0 of 5 |

An earlier probe that used this package's renderer gave the same picture: make 3 of 3, `update:` 5 of 8, first update 0 of 8.

## Where it traps

```
* thread #17, queue = 'com.apple.main-thread', stop reason = EXC_BREAKPOINT (code=1)
  frame #0: RealityKit`ARView.renderCallbacks.setter + 1188
  frame #1: RealityKit`ARView.renderCallbacks.modify
  frame #2: _RealityKit_SwiftUI`RealityViewCameraContent.renderingEffects.didset
  frame #3: _RealityKit_SwiftUI`RealityViewCameraContent.renderingEffects.modify
  frame #4: <make closure>
```

On macOS, `RealityView` is backed by an `ARView`, and `renderingEffects.didSet` writes `ARView.renderCallbacks`. Just before the trap, the setter does this (from lldb, resolving the stubs it calls):

```
Entity.coreEntity.getter                    → the view's camera entity
RECameraViewDescriptorsComponentGetComponentType
REEntityGetComponentByClass(entity, type)   → nil
cbz x0, <brk #1>                            → force-unwrap fails
```

So the setter force-unwraps the camera's `RECameraViewDescriptorsComponent`, which RealityKit creates only once the view starts rendering. This is a static reading of the disassembly at the trap; the conclusion about when the component is created is inferred from the timing results above, not observed directly.

## Why it's likely a bug

- Apple's documentation for `PostProcessEffect` and `customPostProcessing` sets no precondition on when the property may be written.
- The make closure is where RealityView content is configured in Apple's documentation and WWDC samples (camera, environment, anchors, tracking sessions).
- Writing a property shouldn't trap. Even when the view isn't ready, the effect could be stored and applied once it is.

## Feedback text (draft)

> **RealityView: setting `renderingEffects.customPostProcessing` in the make closure crashes (EXC_BREAKPOINT in `ARView.renderCallbacks.setter`)**
>
> On macOS 27.0.1 (26A434), setting `content.renderingEffects.customPostProcessing = .effect(…)` in a RealityView's make closure traps every time (5/5) inside `ARView.renderCallbacks.setter`. Setting it in `update:` traps intermittently (2/5). Setting it after the first `SceneEvents.Update` works (0/5). The attached package reproduces it with a pass-through effect and Apple frameworks only: `swift run PostProcessTimingRepro make`.
>
> The setter appears to force-unwrap the camera entity's `RECameraViewDescriptorsComponent`, which doesn't exist before the first frame. The documentation doesn't say when the property may be set.
>
> Expected: the effect is stored and applied once the view renders, or the documentation states when it's safe to set.
