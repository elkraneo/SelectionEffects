//
//  DemoMotion.swift
//  SelectionEffectsExample
//
//  Created by Cristian Díaz on 13.10.26.
//

import RealityKit
import simd

/// Spins an entity in place and, optionally, orbits it around the origin, so the
/// demos show outlines following moving entities. Not part of the package.
struct DemoMotionComponent: Component {
	/// Spin speed in radians per second.
	var spin: Float = 0
	/// Spin axis.
	var spinAxis: SIMD3<Float> = [0, 1, 0]
	/// Orbit radius in meters; 0 keeps the entity in place.
	var orbitRadius: Float = 0
	/// Orbit speed in radians per second.
	var orbitSpeed: Float = 0
	/// Orbit height in meters.
	var orbitHeight: Float = 0
}

struct DemoMotionSystem: System {
	private static let query = EntityQuery(where: .has(DemoMotionComponent.self))
	private var elapsed: Float = 0

	init(scene: RealityKit.Scene) {}

	mutating func update(context: SceneUpdateContext) {
		elapsed += Float(context.deltaTime)
		for entity in context.scene.performQuery(Self.query) {
			guard let motion = entity.components[DemoMotionComponent.self] else { continue }
			entity.orientation = simd_quatf(angle: elapsed * motion.spin, axis: normalize(motion.spinAxis))
			if motion.orbitRadius > 0 {
				let angle = elapsed * motion.orbitSpeed
				entity.position = [cos(angle) * motion.orbitRadius, motion.orbitHeight, sin(angle) * motion.orbitRadius]
			}
		}
	}

	/// Registers the component and system once.
	@MainActor
	static func register() {
		guard !registered else { return }
		registered = true
		DemoMotionComponent.registerComponent()
		registerSystem()
	}

	@MainActor private static var registered = false
}
