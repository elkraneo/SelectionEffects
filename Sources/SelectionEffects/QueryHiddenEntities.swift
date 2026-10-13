//
//  QueryHiddenEntities.swift
//  SelectionEffects
//
//  Created by Cristian Díaz on 13.10.26.
//

import RealityKit

#if canImport(USDKit)
import USDKit  // with RealityKit, brings in USDStageComponent
#endif

// RealityKit's entity queries skip entities that RealityFoundation marks as
// hidden through SPI (`Entity.isHidden`, not in the SDK). On macOS 27, USDKit
// marks every entity its `USDStageComponent` generates, so those meshes are
// missing from `Scene.performQuery` and send no component events, though they
// render and are reachable through `children` (FB25173225). The stage entity
// itself is queryable, which is where the walk below starts.

@available(iOS 15.0, macOS 12.0, tvOS 26.0, visionOS 1.0, *)
extension Entity {
	/// The descendants of this entity that satisfy `isIncluded`, in depth-first
	/// order, including entities RealityKit's entity queries don't return.
	///
	/// On macOS 27, `Scene.performQuery` skips the entities that USDKit's
	/// `USDStageComponent` generates. Use this on the stage entity to find them:
	///
	/// ```swift
	/// let meshes = stageEntity.descendants { $0.components.has(ModelComponent.self) }
	/// ```
	///
	/// Walks the whole subtree: call it when the hierarchy changes, not every frame.
	public func descendants(where isIncluded: (Entity) -> Bool) -> [Entity] {
		var result: [Entity] = []
		func visit(_ entity: Entity) {
			for child in entity.children {
				if isIncluded(child) { result.append(child) }
				visit(child)
			}
		}
		visit(self)
		return result
	}
}

@available(iOS 15.0, macOS 12.0, tvOS 26.0, visionOS 1.0, *)
@MainActor
enum QueryHiddenContent {
	/// The queryable entities whose subtrees can hold entities queries skip:
	/// those that carry `USDStageComponent`. Empty where USDKit isn't available.
	static func roots(in scene: RealityKit.Scene) -> [Entity] {
		#if canImport(USDKit)
		if #available(iOS 27.0, macOS 27.0, tvOS 27.0, visionOS 27.0, *) {
			return Array(scene.performQuery(stages))
		}
		#endif
		return []
	}

	#if canImport(USDKit)
	@available(iOS 27.0, macOS 27.0, tvOS 27.0, visionOS 27.0, *)
	private static var stages: EntityQuery { EntityQuery(where: .has(USDStageComponent.self)) }
	#endif
}
