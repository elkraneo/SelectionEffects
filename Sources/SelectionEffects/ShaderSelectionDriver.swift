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
///
/// Each frame it works out the value every (model, parameter) pair should have —
/// the strongest of all selections covering that model — and writes it only
/// where a material's current value differs. So overlapping selections, swapped
/// materials, renamed parameters and models that leave the hierarchy all
/// converge; pairs no longer covered are reset to 0.
@available(iOS 15.0, macOS 12.0, tvOS 26.0, visionOS 1.0, *)
@MainActor
struct ShaderSelectionDriver {
	/// A selected (or fading-out) entity.
	private struct Selection {
		weak var entity: Entity?
		var inputs: SelectionEffectComponent.ShaderSelectionEffectInputs
		var meshSelection: SelectionEffectComponent.MeshSelection
		var intensity: Float = 0
		var selected = true
	}

	/// One parameter on one model entity.
	struct Target: Hashable {
		let model: ObjectIdentifier
		let parameter: String
	}

	private var selections: [ObjectIdentifier: Selection] = [:]
	/// Targets driven last frame, with their entities, to reset them once uncovered.
	private var driven: [Target: WeakEntity] = [:]

	private struct WeakEntity {
		weak var entity: Entity?
	}

	/// Whether nothing is selected, fading or still driven (for tests).
	var isIdle: Bool { selections.isEmpty && driven.isEmpty }

	mutating func update(selected: [Entity], deltaTime: TimeInterval) {
		// 1. Which entities currently ask for a shader effect.
		var current = Set<ObjectIdentifier>()
		for entity in selected {
			guard
				let component = entity.components[SelectionEffectComponent.self],
				case .shader(let inputs) = component.selectionEffect.kind
			else { continue }
			let id = ObjectIdentifier(entity)
			current.insert(id)
			if selections[id]?.entity !== entity {
				selections[id] = Selection(entity: entity, inputs: inputs, meshSelection: component.meshSelection)
			}
			selections[id]?.inputs = inputs
			selections[id]?.meshSelection = component.meshSelection
			selections[id]?.selected = true
		}

		// 2. Advance each fade, and collect the value every target should have.
		var desired: [Target: (entity: Entity, value: Float)] = [:]
		for id in Array(selections.keys) {
			guard var selection = selections[id], let entity = selection.entity else {
				selections[id] = nil
				continue
			}
			if !current.contains(id) { selection.selected = false }
			selection.intensity = Self.step(
				selection.intensity,
				towards: selection.selected ? 1 : 0,
				duration: selection.selected ? selection.inputs.fadeInDuration : selection.inputs.fadeOutDuration,
				deltaTime: deltaTime
			)
			for model in Self.modelEntities(of: entity, meshSelection: selection.meshSelection) {
				let target = Target(model: ObjectIdentifier(model), parameter: selection.inputs.parameterName)
				desired[target] = (model, max(desired[target]?.value ?? 0, selection.intensity))
			}
			selections[id] = (!selection.selected && selection.intensity == 0) ? nil : selection
		}

		// 3. Targets driven before but no longer covered go back to 0.
		for (target, weak) in driven where desired[target] == nil {
			if let entity = weak.entity {
				Self.write(0, named: target.parameter, to: entity)
			}
		}

		// 4. Write the values that differ from what the materials hold.
		for (target, wanted) in desired {
			Self.write(wanted.value, named: target.parameter, to: wanted.entity)
		}
		driven = desired.compactMapValues { $0.value > 0 ? WeakEntity(entity: $0.entity) : nil }
	}

	/// Moves `value` linearly towards `target`, covering 0…1 in `duration` seconds.
	static func step(_ value: Float, towards target: Float, duration: TimeInterval, deltaTime: TimeInterval) -> Float {
		guard duration > 0 else { return target }
		let delta = Float(deltaTime / duration)
		return target > value ? min(value + delta, target) : max(value - delta, target)
	}

	/// Sets `name` to `value` on each of the model's `ShaderGraphMaterial`s that
	/// declares it and doesn't hold that value already.
	static func write(_ value: Float, named name: String, to model: Entity) {
		guard #available(iOS 18.0, macOS 15.0, tvOS 26.0, visionOS 1.0, *),
			var component = model.components[ModelComponent.self]
		else { return }
		var changed = false
		for index in component.materials.indices {
			guard var material = component.materials[index] as? ShaderGraphMaterial,
				material.parameterNames.contains(name)
			else { continue }
			if case .float(let current)? = material.getParameter(name: name), current == value { continue }
			guard (try? material.setParameter(name: name, value: .float(value))) != nil else { continue }
			component.materials[index] = material
			changed = true
		}
		if changed { model.components.set(component) }
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
