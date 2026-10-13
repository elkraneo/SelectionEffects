//
//  SelectionEffectTests.swift
//  SelectionEffects
//

import RealityKit
import Testing
import simd

@testable import SelectionEffects

#if !os(visionOS)

@MainActor
@Suite("Selection effects")
struct SelectionEffectTests {

	private func box() -> ModelEntity {
		ModelEntity(mesh: .generateBox(size: 1), materials: [])
	}

	private let red = RenderStyle(kind: .outline, color: [1, 0, 0, 1], width: 2, strength: 1, occludedOpacity: 1)
	private let blue = RenderStyle(kind: .outline, color: [0, 0, 1, 1], width: 5, strength: 1, occludedOpacity: 0.3)

	@Test func identicalStylesShareOneIndex() {
		let renderer = SelectionRenderer()
		let (a, b, c) = (box(), box(), box())
		renderer.setSelected([(a, red, .subtree), (b, red, .subtree), (c, blue, .subtree)])
		let state = renderer.selectionState
		#expect(state.styles == [red, blue])
		#expect(state.meshStyles == [1, 1, 2])
	}

	@Test func styleChangeRestylesWithoutRereadingGeometry() {
		let renderer = SelectionRenderer()
		let a = box()
		renderer.setSelected([(a, red, .subtree)])
		#expect(renderer.selectionState.awaitingUpload)
		renderer.discardPendingUpload()

		renderer.setSelected([(a, blue, .subtree)])
		let state = renderer.selectionState
		#expect(!state.awaitingUpload)
		#expect(state.styles == [blue])
		#expect(state.meshStyles == [1])
	}

	@Test func newMembersRereadGeometry() {
		let renderer = SelectionRenderer()
		let (a, b) = (box(), box())
		renderer.setSelected([(a, red, .subtree)])
		renderer.discardPendingUpload()
		renderer.setSelected([(a, red, .subtree), (b, red, .subtree)])
		#expect(renderer.selectionState.awaitingUpload)
	}

	@Test func meshSelectionChangeRereadsGeometry() {
		let renderer = SelectionRenderer()
		let a = box()
		renderer.setSelected([(a, red, .subtree)])
		renderer.discardPendingUpload()
		renderer.setSelected([(a, red, .nearestMeshes)])
		#expect(renderer.selectionState.awaitingUpload)
	}

	@Test func gpuStylesAreIndexedLinearAndClamped() {
		let wide = RenderStyle(kind: .highlight, color: [0, 1, 0, 0.5], width: 1_000, strength: 3, occludedOpacity: -1)
		let styles = SelectionRenderer.gpuStyles([red, wide])
		#expect(MemoryLayout<SelectionRenderer.GPUStyle>.stride == 32)
		#expect(styles.count == 3)
		#expect(styles[0].kind == 0 && styles[0].width == 0)
		#expect(styles[1].color == SelectionRenderer.linear(fromSRGB: red.color))
		#expect(styles[2].kind == 1)
		#expect(styles[2].width == Int32(SelectionRenderer.maxWidth))
		#expect(styles[2].strength == 1)
		#expect(styles[2].occludedOpacity == 0)
	}

	@Test func detectsReversedZ() {
		let standard = simd_float4x4(rows: [
			[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, -1.0002, -0.20002], [0, 0, -1, 0],
		])
		let reversed = simd_float4x4(rows: [
			[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 0, 0.1], [0, 0, -1, 0],
		])
		#expect(!SelectionRenderer.isReversedZ(standard))
		#expect(SelectionRenderer.isReversedZ(reversed))
	}

	@Test func componentMirrorsHoverEffectDefaults() {
		let component = SelectionEffectComponent()
		#expect(component.selectionEffect == .outline(.default))
		#expect(component.meshSelection == .subtree)
		let outline = SelectionEffectComponent.OutlineSelectionEffectStyle.default
		#expect(outline.color == SelectionEffectComponent.OutlineSelectionEffectStyle.accentColor)
		#expect(outline.width == 3 && outline.occludedOpacity == 1)
		let highlight = SelectionEffectComponent.HighlightSelectionEffectStyle.default
		#expect(highlight.strength == 1 && highlight.occludedOpacity == 0)
	}

	@Test func renderStyleResolvesNilColorToAccent() throws {
		let style = try #require(SelectionEffectComponent(.highlight(.init(strength: 0.5))).renderStyle)
		#expect(style.kind == .highlight)
		#expect(style.width == 0)
		#expect(style.strength == 0.5 * SelectionEffectComponent.highlightCoverage)
		#expect(style.color.w > 0)
	}
}

#endif
