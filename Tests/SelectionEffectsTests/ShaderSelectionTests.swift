//
//  ShaderSelectionTests.swift
//  SelectionEffects
//

import RealityKit
import Testing

@testable import SelectionEffects

@MainActor
@Suite("Shader selection effect")
struct ShaderSelectionTests {

	@Test func fadeStepsLinearlyAndClamps() {
		#expect(ShaderSelectionDriver.step(0, towards: 1, duration: 0.5, deltaTime: 0.25) == 0.5)
		#expect(ShaderSelectionDriver.step(0.9, towards: 1, duration: 0.5, deltaTime: 0.25) == 1)
		#expect(ShaderSelectionDriver.step(0.5, towards: 0, duration: 1, deltaTime: 0.1) == 0.4)
		#expect(ShaderSelectionDriver.step(0.3, towards: 1, duration: 0, deltaTime: 0.01) == 1)
	}

	@Test func modelEntitiesFollowMeshSelection() {
		let parent = ModelEntity(mesh: .generateBox(size: 1), materials: [])
		let child = ModelEntity(mesh: .generateSphere(radius: 0.2), materials: [])
		parent.addChild(child)
		let group = Entity()
		group.addChild(parent)

		#expect(ShaderSelectionDriver.modelEntities(of: parent, meshSelection: .subtree).count == 2)
		#expect(ShaderSelectionDriver.modelEntities(of: parent, meshSelection: .nearestMeshes) == [parent])
		#expect(ShaderSelectionDriver.modelEntities(of: parent, meshSelection: .preferDescendants) == [child])
		#expect(ShaderSelectionDriver.modelEntities(of: group, meshSelection: .nearestMeshes) == [parent])
	}

	@available(macOS 15.0, iOS 18.0, *)
	@Test func driverForgetsEntitiesOnceFadedOut() {
		var driver = ShaderSelectionDriver()
		let entity = ModelEntity(mesh: .generateBox(size: 1), materials: [])
		entity.components.set(SelectionEffectComponent(.shader(.init(fadeInDuration: 0, fadeOutDuration: 0))))
		driver.update(selected: [entity], deltaTime: 0.016)
		#expect(!driver.isIdle)
		entity.components.remove(SelectionEffectComponent.self)
		driver.update(selected: [], deltaTime: 0.016)
		#expect(driver.isIdle)
	}

	@Test func shaderInputsMatchHoverDefaultsShape() {
		let inputs = SelectionEffectComponent.ShaderSelectionEffectInputs.default
		#expect(inputs.fadeInDuration == 0.2 && inputs.fadeOutDuration == 0.2)
		#expect(inputs.parameterName == "SelectionIntensity")
	}
}
