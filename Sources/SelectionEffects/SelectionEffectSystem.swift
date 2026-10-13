//
//  SelectionEffectSystem.swift
//  SelectionEffects
//
//  Created by Cristian Díaz on 13.10.26.
//

import Combine
import RealityKit
import os
import simd

#if !os(visionOS)
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
			.compactMap { entity -> (entity: Entity, style: RenderStyle, meshes: SelectionEffectComponent.MeshSelection)? in
				guard
					let component = entity.components[SelectionEffectComponent.self],
					let style = component.renderStyle
				else { return nil }
				return (entity, style, component.meshSelection)
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

#endif

// MARK: - System

/// The system that draws selection effects. Every frame it fades `.shader`
/// effects and hands each view's renderer its camera and the selected entities
/// with their current transforms.
///
/// Registered by `installSelectionEffects()`. If your own systems move selected
/// entities, run them first so outlines line up with the rendered frame:
///
/// ```swift
/// struct MotionSystem: System {
///     static var dependencies: [SystemDependency] { [.before(SelectionEffectSystem.self)] }
///     …
/// }
/// ```
@available(iOS 15.0, macOS 12.0, tvOS 26.0, visionOS 1.0, *)
public struct SelectionEffectSystem: System {
	private static let selected = EntityQuery(where: .has(SelectionEffectComponent.self))
	#if !os(visionOS)
	private static let hosts = EntityQuery(where: .has(SelectionEffectsHostComponent.self))
	#endif

	private var shaders = ShaderSelectionDriver()
	private let tracked = TrackedSelection()
	private var updatesSinceScan = Int.max - 1
	/// Updates between hierarchy scans (about 100 ms at 60 fps).
	private static let scanInterval = 6
	private var subscriptions: [any Cancellable] = []

	public init(scene: RealityKit.Scene) {
		// Component events catch most owners between scans (see `update`).
		let tracked = tracked
		subscriptions = [
			scene.subscribe(to: ComponentEvents.DidAdd.self, componentType: SelectionEffectComponent.self) { event in
				tracked.insert(event.entity)
			},
			scene.subscribe(to: ComponentEvents.WillRemove.self, componentType: SelectionEffectComponent.self) { event in
				tracked.remove(event.entity)
			},
		]
	}

	public mutating func update(context: SceneUpdateContext) {
		// Entity queries don't return every entity: on macOS 27 the meshes that
		// USDKit's USDStageComponent generates are missing from performQuery (even
		// for ModelComponent) and send no component events, though they're in the
		// scene and reachable through `children`. So every few updates, walk the
		// hierarchy below the queried entities for owners the query missed.
		updatesSinceScan += 1
		if updatesSinceScan >= Self.scanInterval {
			updatesSinceScan = 0
			tracked.scan(context.scene)
		}
		let selected = tracked.merged(with: Array(context.scene.performQuery(Self.selected)))
		shaders.update(selected: selected, deltaTime: context.deltaTime)

		#if !os(visionOS)
		OutlineGeometryCache.shared.pruneReleasedEntities()
		for entity in context.scene.performQuery(Self.hosts) {
			entity.components[SelectionEffectsHostComponent.self]?.host.update(
				scene: context.scene,
				selected: selected
			)
		}
		#endif
	}

	@MainActor private static var registered = false

	/// Owners of `SelectionEffectComponent` seen through component events.
	@MainActor
	private final class TrackedSelection {
		private var entities: [ObjectIdentifier: WeakEntity] = [:]
		private struct WeakEntity { weak var entity: Entity? }

		func insert(_ entity: Entity) { entities[ObjectIdentifier(entity)] = WeakEntity(entity: entity) }
		func remove(_ entity: Entity) { entities[ObjectIdentifier(entity)] = nil }

		/// Walks the hierarchy from the scene's root entities and tracks every
		/// owner of the component, including entities queries don't return.
		func scan(_ scene: RealityKit.Scene) {
			// The topmost ancestors of the indexed entities: a root itself may not
			// be indexed (RealityView's content root isn't, on macOS 27).
			var roots: [ObjectIdentifier: Entity] = [:]
			for entity in scene.performQuery(EntityQuery()) {
				var top = entity
				while let parent = top.parent { top = parent }
				roots[ObjectIdentifier(top)] = top
			}
			for root in roots.values { visit(root) }
		}

		private func visit(_ entity: Entity) {
			if entity.components.has(SelectionEffectComponent.self) { insert(entity) }
			for child in entity.children { visit(child) }
		}

		/// `queried` plus tracked entities that still carry the component and
		/// are in a scene, without duplicates.
		func merged(with queried: [Entity]) -> [Entity] {
			var result = queried
			var seen = Set(queried.map(ObjectIdentifier.init))
			for (id, weak) in entities {
				guard let entity = weak.entity, entity.components.has(SelectionEffectComponent.self) else {
					entities[id] = nil
					continue
				}
				if entity.scene != nil, seen.insert(id).inserted { result.append(entity) }
			}
			return result
		}
	}

	@MainActor
	static func registerOnce() {
		guard !registered else { return }
		registered = true
		SelectionEffectComponent.registerComponent()
		#if !os(visionOS)
		SelectionEffectsHostComponent.registerComponent()
		#endif
		registerSystem()
	}
}
