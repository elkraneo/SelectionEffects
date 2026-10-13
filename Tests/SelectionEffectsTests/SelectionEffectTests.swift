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

	@Test func descendantsWalkDepthFirstWithoutTheRoot() {
		let root = Entity(), a = box(), a1 = box(), b = Entity(), b1 = box()
		root.addChild(a); a.addChild(a1); root.addChild(b); b.addChild(b1)
		root.components.set(ModelComponent(mesh: .generateBox(size: 1), materials: []))
		let found = root.descendants { $0.components.has(ModelComponent.self) }
		#expect(found.map(ObjectIdentifier.init) == [a, a1, b1].map(ObjectIdentifier.init))
	}

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
		a.addChild(box())
		renderer.setSelected([(a, red, .subtree)])
		renderer.discardPendingUpload()
		renderer.setSelected([(a, red, .nearestMeshes)])   // drops the child's mesh
		#expect(renderer.selectionState.awaitingUpload)
	}

	@Test func swappedMeshIsReuploadedWithoutReselecting() {
		let renderer = SelectionRenderer()
		let a = box()
		renderer.setSelected([(a, red, .subtree)])
		renderer.discardPendingUpload()
		a.model?.mesh = .generateSphere(radius: 0.5)
		renderer.setSelected([(a, red, .subtree)])
		#expect(renderer.selectionState.awaitingUpload)
	}

	@Test func addedChildIsPickedUpWithoutReselecting() {
		let renderer = SelectionRenderer()
		let a = box()
		renderer.setSelected([(a, red, .subtree)])
		renderer.discardPendingUpload()
		a.addChild(box())
		renderer.setSelected([(a, red, .subtree)])
		#expect(renderer.selectionState.awaitingUpload)
	}

	@Test func reloadGeometryForcesReupload() {
		let renderer = SelectionRenderer()
		let a = box()
		renderer.setSelected([(a, red, .subtree)])
		renderer.discardPendingUpload()
		renderer.setSelected([(a, red, .subtree)])
		#expect(!renderer.selectionState.awaitingUpload)
		SelectionEffectComponent.reloadGeometry(of: [a])
		renderer.setSelected([(a, red, .subtree)])
		#expect(renderer.selectionState.awaitingUpload)
	}

	@Test func stylesBeyondTheLimitReuseTheLastSlot() {
		let renderer = SelectionRenderer()
		let items = (0...SelectionRenderer.maxStyles).map { i in
			(entity: box() as Entity,
			 style: RenderStyle(kind: .outline, color: [Float(i) / 255, 0, 0, 1], width: 1, strength: 1, occludedOpacity: 1),
			 meshes: SelectionEffectComponent.MeshSelection.subtree)
		}
		renderer.setSelected(items)
		let state = renderer.selectionState
		#expect(state.styles.count == SelectionRenderer.maxStyles)
		#expect(state.meshStyles.max() == UInt32(SelectionRenderer.maxStyles))
	}

	@Test func nonFiniteAndOutOfRangeWidthsAreSanitized() {
		#expect(SelectionEffectComponent.pixelWidth(.infinity) == 0)
		#expect(SelectionEffectComponent.pixelWidth(.nan) == 0)
		#expect(SelectionEffectComponent.pixelWidth(-3) == 0)
		#expect(SelectionEffectComponent.pixelWidth(.greatestFiniteMagnitude) == SelectionRenderer.maxWidth)
		#expect(SelectionEffectComponent.pixelWidth(2.6) == 3)
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
