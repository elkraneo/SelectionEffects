//
//  SelectionEffectSystem.swift
//  SelectionEffects
//
//  Created by Cristian Díaz on 13.10.26.
//

import RealityKit
import os
import simd

// MARK: - Host

/// The per-view side of the selection effects: the renderer that draws them, how
/// to read that view's camera, and a one-time hook that attaches the renderer to
/// the view. Carried into the scene by `SelectionEffectsHostComponent`.
@available(iOS 15.0, macOS 12.0, tvOS 26.0, *)
@available(visionOS, unavailable)
@MainActor
final class SelectionEffectsHost {
	let renderer: SelectionRenderer
	private let viewMatrix: @MainActor (RealityKit.Scene) -> simd_float4x4?
	private var attach: (@MainActor () -> Void)?
	private var warnedAboutCamera = false

	/// - Parameters:
	///   - viewMatrix: The view's camera view matrix (inverse world transform).
	///   - attach: Hooks the renderer into the view. It runs on the first scene
	///     update, when the view is rendering: setting a post-process effect
	///     earlier can trap inside RealityKit.
	init(
		renderer: SelectionRenderer,
		viewMatrix: @escaping @MainActor (RealityKit.Scene) -> simd_float4x4?,
		attach: @escaping @MainActor () -> Void
	) {
		self.renderer = renderer
		self.viewMatrix = viewMatrix
		self.attach = attach
	}

	/// An entity that carries this host into the scene. Removing it from the
	/// scene stops the effects from updating.
	func makeEntity() -> Entity {
		SelectionEffectSystem.registerOnce()
		let entity = Entity()
		entity.name = "SelectionEffects"
		entity.components.set(SelectionEffectsHostComponent(host: self))
		return entity
	}

	/// Called every frame by `SelectionEffectSystem`.
	func update(scene: RealityKit.Scene, selected: [Entity]) {
		if let attach {
			self.attach = nil
			attach()
		}

		if let matrix = viewMatrix(scene) {
			renderer.setViewMatrix(matrix)
		} else if !warnedAboutCamera {
			warnedAboutCamera = true
			Self.logger.warning("Selection effects need a camera entity with PerspectiveCameraComponent in the scene; outlines won't line up without one.")
		}

		// Sorted, so the selection only counts as changed when its members change.
		let items = selected
			.compactMap { entity -> (entity: Entity, style: OutlineStyle)? in
				guard let component = entity.components[SelectionEffectComponent.self] else { return nil }
				switch component.effect.kind {
				case .outline(let style): return (entity, style)
				}
			}
			.sorted { ObjectIdentifier($0.entity) < ObjectIdentifier($1.entity) }
		renderer.setSelected(items)
		renderer.updateTransforms()
	}

	/// View matrix of the scene's first active perspective camera.
	static func sceneCameraViewMatrix(_ scene: RealityKit.Scene) -> simd_float4x4? {
		let cameras = scene.performQuery(EntityQuery(where: .has(PerspectiveCameraComponent.self)))
		guard let camera = cameras.first(where: { $0.isActive }) else { return nil }
		let noRef: Entity? = nil
		return camera.transformMatrix(relativeTo: noRef).inverse
	}

	private static let logger = Logger(subsystem: "SelectionEffects", category: "SelectionEffects")
}

@available(iOS 15.0, macOS 12.0, tvOS 26.0, *)
@available(visionOS, unavailable)
struct SelectionEffectsHostComponent: Component {
	let host: SelectionEffectsHost
}

// MARK: - System

/// Every frame, hands each view's renderer its camera and the entities that
/// carry a `SelectionEffectComponent`, with their current transforms.
@available(iOS 15.0, macOS 12.0, tvOS 26.0, *)
@available(visionOS, unavailable)
struct SelectionEffectSystem: System {
	private static let hosts = EntityQuery(where: .has(SelectionEffectsHostComponent.self))
	private static let selected = EntityQuery(where: .has(SelectionEffectComponent.self))

	init(scene: RealityKit.Scene) {}

	func update(context: SceneUpdateContext) {
		let hosts = context.scene.performQuery(Self.hosts)
		guard hosts.contains(where: { _ in true }) else { return }
		let selected = Array(context.scene.performQuery(Self.selected))
		for entity in hosts {
			entity.components[SelectionEffectsHostComponent.self]?.host.update(
				scene: context.scene,
				selected: selected
			)
		}
	}

	@MainActor private static var registered = false

	@MainActor
	static func registerOnce() {
		guard !registered else { return }
		registered = true
		SelectionEffectComponent.registerComponent()
		SelectionEffectsHostComponent.registerComponent()
		registerSystem()
	}
}
