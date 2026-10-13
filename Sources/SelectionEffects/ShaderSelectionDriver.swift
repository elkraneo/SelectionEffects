//
//  ShaderSelectionDriver.swift
//  SelectionEffects
//
//  Created by Cristian Díaz on 13.10.26.
//

import Foundation
import RealityKit

/// Drives `.shader` selection effects: fades a float parameter of the selected
/// entities' `ShaderGraphMaterial`s towards 1, and back towards 0 after the
/// component is removed or switches to another effect.
@available(iOS 15.0, macOS 12.0, tvOS 26.0, visionOS 1.0, *)
@MainActor
struct ShaderSelectionDriver {
	private struct Tracked {
		weak var entity: Entity?
		var inputs: SelectionEffectComponent.ShaderSelectionEffectInputs
		var meshSelection: SelectionEffectComponent.MeshSelection
		var intensity: Float = 0
		var applied: Float? = nil
		var selected = true
	}

	private var tracked: [ObjectIdentifier: Tracked] = [:]

	/// Whether any effect is still fading (for tests).
	var isIdle: Bool { tracked.isEmpty }

	mutating func update(selected: [Entity], deltaTime: TimeInterval) {
		var current = Set<ObjectIdentifier>()
		for entity in selected {
			guard
				let component = entity.components[SelectionEffectComponent.self],
				case .shader(let inputs) = component.selectionEffect.kind
			else { continue }
			let id = ObjectIdentifier(entity)
			current.insert(id)
			if tracked[id]?.entity !== entity {
				tracked[id] = Tracked(entity: entity, inputs: inputs, meshSelection: component.meshSelection)
			}
			tracked[id]?.inputs = inputs
			tracked[id]?.meshSelection = component.meshSelection
			tracked[id]?.selected = true
		}

		for id in Array(tracked.keys) {
			guard var item = tracked[id], let entity = item.entity else {
				tracked[id] = nil
				continue
			}
			if !current.contains(id) { item.selected = false }

			item.intensity = Self.step(
				item.intensity,
				towards: item.selected ? 1 : 0,
				duration: item.selected ? item.inputs.fadeInDuration : item.inputs.fadeOutDuration,
				deltaTime: deltaTime
			)
			if item.applied != item.intensity {
				Self.apply(item.intensity, named: item.inputs.parameterName, to: entity, meshSelection: item.meshSelection)
				item.applied = item.intensity
			}
			// Fully faded out: stop tracking.
			tracked[id] = (!item.selected && item.intensity == 0) ? nil : item
		}
	}

	/// Moves `value` linearly towards `target`, covering 0…1 in `duration` seconds.
	static func step(_ value: Float, towards target: Float, duration: TimeInterval, deltaTime: TimeInterval) -> Float {
		guard duration > 0 else { return target }
		let delta = Float(deltaTime / duration)
		return target > value ? min(value + delta, target) : max(value - delta, target)
	}

	/// Sets `name` on every `ShaderGraphMaterial` of the entity's models that
	/// declares it. Materials without the parameter are left alone.
	private static func apply(
		_ intensity: Float,
		named name: String,
		to entity: Entity,
		meshSelection: SelectionEffectComponent.MeshSelection
	) {
		guard #available(iOS 18.0, macOS 15.0, tvOS 26.0, visionOS 1.0, *) else { return }
		for model in modelEntities(of: entity, meshSelection: meshSelection) {
			guard var component = model.components[ModelComponent.self] else { continue }
			var changed = false
			for index in component.materials.indices {
				guard var material = component.materials[index] as? ShaderGraphMaterial,
					material.parameterNames.contains(name),
					(try? material.setParameter(name: name, value: .float(intensity))) != nil
				else { continue }
				component.materials[index] = material
				changed = true
			}
			if changed { model.components.set(component) }
		}
	}

	/// The entities whose models `meshSelection` picks, mirroring the outline's
	/// mesh collection.
	static func modelEntities(
		of entity: Entity,
		meshSelection: SelectionEffectComponent.MeshSelection
	) -> [Entity] {
		let hasModel = entity.components.has(ModelComponent.self)
		switch meshSelection {
		case .subtree:
			return (hasModel ? [entity] : []) + entity.children.flatMap { modelEntities(of: $0, meshSelection: .subtree) }
		case .nearestMeshes:
			return hasModel ? [entity] : entity.children.flatMap { modelEntities(of: $0, meshSelection: .nearestMeshes) }
		case .preferDescendants:
			let below = entity.children.flatMap { modelEntities(of: $0, meshSelection: .preferDescendants) }
			return below.isEmpty && hasModel ? [entity] : below
		}
	}
}
