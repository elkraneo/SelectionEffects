# Changelog

## 0.3.0

### Added
- `SelectionCompositor`: the outline and highlight passes as a renderer-agnostic Metal API. Give it a selection mask of style indices (`r8Uint`), an optional mask depth and scene depth, and a list of styles (color, width in pixels, highlight strength, occluded opacity); it composites the effects over your frame into a target texture. Use it from any Metal renderer, such as a ray marcher.
- Depth inputs can be depth textures (`depth32Float`, `depth32Float_stencil8`) or float color textures (`r32Float`, `r16Float`), compared as standard depth, reversed depth or ray distance (`SelectionCompositor.DepthComparison`). The scene depth can have a different size from the mask.
- `SelectionCompositor.srgbComponents(of:)` converts a `CGColor` for a style.

### Changed
- The RealityKit path (`installSelectionEffects()` on `RealityView` and `ARView`) draws its mask and hands it to `SelectionCompositor`. Its output is unchanged.
- The shaders decide whether a pixel is selected from the mask instead of the mask depth's clear value, so a mask depth needs no particular clear value.
- Mask indices with no style draw nothing (the styles buffer is padded to every index the mask can hold).

Earlier releases are described in their annotated tags (`git tag -n20`).
