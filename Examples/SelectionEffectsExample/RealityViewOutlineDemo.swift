//
//  RealityViewOutlineDemo.swift
//  SelectionEffectsExample
//
//  Created by Cristian Díaz on 29.03.26.
//

import SelectionEffects
import RealityKit
import SwiftUI

/// iOS 26 / macOS 26: selection effects in a `RealityView`.
///
/// Tap a model to select it: the tap handler adds a `SelectionEffectComponent`,
/// and removing the component deselects. The gramophone spins and the box
/// orbits, so the outline is shown following moving entities.
@available(macOS 26.0, iOS 26.0, *)
struct RealityViewOutlineDemo: View {
	@State private var selectable: [Entity] = []
	@State private var selected: Entity?

	var body: some View {
		RealityView { content in
			content.installSelectionEffects()
			DemoMotionSystem.register()

			let camera = Entity()
			camera.components.set(PerspectiveCameraComponent())
			camera.position = [0, 0.5, 1.5]
			content.add(camera)

			let box = ModelEntity(
				mesh: .generateBox(size: 0.15, cornerRadius: 0.02),
				materials: [SimpleMaterial(color: .systemBlue, isMetallic: false)]
			)
			box.components.set(DemoMotionComponent(spin: 1, spinAxis: [1, 1, 0], orbitRadius: 0.6, orbitSpeed: 0.8, orbitHeight: 0.35))
			content.add(box)
			var models: [Entity] = [box]

			if let gramophone = try? await Entity(named: "gramophone") {
				gramophone.components.set(DemoMotionComponent(spin: 0.3))
				content.add(gramophone)
				models.append(gramophone)
			}

			for model in models {
				model.generateCollisionShapes(recursive: true)
				model.components.set(InputTargetComponent(allowedInputTypes: .all))
			}
			// Read the outline geometry now so the first tap doesn't hitch.
			SelectionEffectComponent.preloadGeometry(of: models)
			selectable = models
		}
		.gesture(
			TapGesture()
				.targetedToAnyEntity()
				.onEnded { select($0.entity) }
		)
		.overlay(alignment: .bottom) {
			Button("Clear Selection") { select(nil) }
				.buttonStyle(.borderedProminent)
				.disabled(selected == nil)
				.padding()
		}
	}

	/// Selects the whole model containing `entity` (taps hit the gramophone's
	/// individual collision parts). Tapping the selected model again deselects it.
	private func select(_ entity: Entity?) {
		var model = entity
		while let candidate = model, !selectable.contains(where: { $0 === candidate }) {
			model = candidate.parent
		}
		selected?.components.remove(SelectionEffectComponent.self)
		selected = (model === selected) ? nil : model
		// Outline in yellow; the parts hidden behind other geometry at 30%, like
		// Reality Composer Pro.
		selected?.components.set(SelectionEffectComponent(.outline(.init(color: .systemYellow, width: 3, occludedOpacity: 0.3))))
	}
}
