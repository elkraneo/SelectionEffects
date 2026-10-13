//
//  SelectionEffectTests.swift
//  SelectionEffects
//

import RealityKit
import Testing

@testable import SelectionEffects

#if !os(visionOS)

@MainActor
@Suite("Selection effects")
struct SelectionEffectTests {

	private func box() -> ModelEntity {
		ModelEntity(mesh: .generateBox(size: 1), materials: [])
	}

	private let red = OutlineStyle(color: [1, 0, 0, 1], width: 2)
	private let blue = OutlineStyle(color: [0, 0, 1, 1], width: 5)

	@Test func identicalStylesShareOneIndex() {
		let renderer = SelectionRenderer()
		let (a, b, c) = (box(), box(), box())
		renderer.setSelected([(a, red), (b, red), (c, blue)])
		let state = renderer.selectionState
		#expect(state.styles == [red, blue])
		#expect(state.meshStyles == [1, 1, 2])
	}

	@Test func styleChangeRestylesWithoutRereadingGeometry() {
		let renderer = SelectionRenderer()
		let a = box()
		renderer.setSelected([(a, red)])
		#expect(renderer.selectionState.awaitingUpload)
		renderer.discardPendingUpload()

		renderer.setSelected([(a, blue)])
		let state = renderer.selectionState
		#expect(!state.awaitingUpload)
		#expect(state.styles == [blue])
		#expect(state.meshStyles == [1])
	}

	@Test func newMembersRereadGeometry() {
		let renderer = SelectionRenderer()
		let (a, b) = (box(), box())
		renderer.setSelected([(a, red)])
		renderer.discardPendingUpload()
		renderer.setSelected([(a, red), (b, red)])
		#expect(renderer.selectionState.awaitingUpload)
	}


	@Test func paletteIsIndexedByStyleAndClampsWidths() {
		let wide = OutlineStyle(color: [0, 1, 0, 0.5], width: 1_000)
		let palette = SelectionRenderer.palette([red, wide])
		#expect(palette.colors.count == 3)
		#expect(palette.colors[0] == .zero)
		#expect(palette.colors[1] == SelectionRenderer.linear(fromSRGB: red.color))
		#expect(palette.colors[2].w == 0.5)
		#expect(palette.widths == [0, 2, Int32(OutlineStyle.maxWidth)])
	}

	@Test func meshSelectionChangeRereadsGeometry() {
		let renderer = SelectionRenderer()
		let a = box()
		renderer.setSelected([(a, red)])
		renderer.discardPendingUpload()
		var nearest = red
		nearest.meshes = .nearestMeshes
		renderer.setSelected([(a, nearest)])
		#expect(renderer.selectionState.awaitingUpload)
	}

	@Test func componentDefaultsToYellowOutline() {
		let component = SelectionEffectComponent()
		#expect(component.effect == .outline(OutlineStyle(color: [1, 1, 0, 1], width: 3)))
	}
}

#endif
