//
//  ShaderSelectionTests.swift
//  SelectionEffects
//

import Foundation
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

	@Test func shaderInputsDefaults() {
		let inputs = SelectionEffectComponent.ShaderSelectionEffectInputs.default
		#expect(inputs.fadeInDuration == 0.2 && inputs.fadeOutDuration == 0.2)
		#expect(inputs.parameterName == "SelectionIntensity")
	}
}

// MARK: - With real Shader Graph materials

@MainActor
@Suite("Shader selection effect, materials")
struct ShaderSelectionMaterialTests {

	@available(macOS 15.0, iOS 18.0, *)
	private func material(_ name: String) async throws -> ShaderGraphMaterial {
		let url = try #require(Bundle.module.url(forResource: name, withExtension: "usda", subdirectory: "Resources"))
		return try await ShaderGraphMaterial(named: "/Root/\(name)", from: url)
	}

	@available(macOS 15.0, iOS 18.0, *)
	private func value(_ entity: ModelEntity, _ name: String = "SelectionIntensity") -> Float? {
		guard let m = entity.model?.materials.first as? ShaderGraphMaterial,
			case .float(let v)? = m.getParameter(name: name) else { return nil }
		return v
	}

	@available(macOS 15.0, iOS 18.0, *)
	private func select(_ entity: Entity, parameter: String = "SelectionIntensity") {
		entity.components.set(SelectionEffectComponent(.shader(.init(fadeInDuration: 0, fadeOutDuration: 0, parameterName: parameter))))
	}

	@Test func selectingAndDeselectingWritesTheParameter() async throws {
		guard #available(macOS 15.0, iOS 18.0, *) else { return }
		let entity = ModelEntity(mesh: .generateBox(size: 1), materials: [try await material("SelectMat")])
		var driver = ShaderSelectionDriver()
		select(entity)
		driver.update(selected: [entity], deltaTime: 0.016)
		#expect(value(entity) == 1)
		entity.components.remove(SelectionEffectComponent.self)
		driver.update(selected: [], deltaTime: 0.016)
		#expect(value(entity) == 0)
		driver.update(selected: [], deltaTime: 0.016)
		#expect(driver.isIdle)
	}

	@Test func deselectingAParentKeepsASelectedChildLit() async throws {
		guard #available(macOS 15.0, iOS 18.0, *) else { return }
		let mat = try await material("SelectMat")
		let parent = ModelEntity(mesh: .generateBox(size: 1), materials: [mat])
		let child = ModelEntity(mesh: .generateBox(size: 0.5), materials: [mat])
		parent.addChild(child)
		var driver = ShaderSelectionDriver()
		select(parent)
		select(child)
		driver.update(selected: [parent, child], deltaTime: 0.016)
		parent.components.remove(SelectionEffectComponent.self)
		driver.update(selected: [child], deltaTime: 0.016)
		#expect(value(parent) == 0)
		#expect(value(child) == 1)
	}

	@Test func replacedMaterialReceivesTheCurrentValue() async throws {
		guard #available(macOS 15.0, iOS 18.0, *) else { return }
		let entity = ModelEntity(mesh: .generateBox(size: 1), materials: [try await material("SelectMat")])
		var driver = ShaderSelectionDriver()
		select(entity)
		driver.update(selected: [entity], deltaTime: 0.016)
		entity.model?.materials = [try await material("SelectMat")]   // fresh material at 0
		driver.update(selected: [entity], deltaTime: 0.016)
		#expect(value(entity) == 1)
	}

	@Test func renamingTheParameterResetsTheOldOne() async throws {
		guard #available(macOS 15.0, iOS 18.0, *) else { return }
		let entity = ModelEntity(mesh: .generateBox(size: 1), materials: [try await material("SelectMat")])
		var driver = ShaderSelectionDriver()
		select(entity)
		driver.update(selected: [entity], deltaTime: 0.016)
		select(entity, parameter: "Glow")   // this material has no Glow input
		driver.update(selected: [entity], deltaTime: 0.016)
		#expect(value(entity) == 0)
	}

	@Test func childRemovedFromTheHierarchyIsReset() async throws {
		guard #available(macOS 15.0, iOS 18.0, *) else { return }
		let mat = try await material("SelectMat")
		let parent = Entity()
		let child = ModelEntity(mesh: .generateBox(size: 1), materials: [mat])
		parent.addChild(child)
		var driver = ShaderSelectionDriver()
		select(parent)
		driver.update(selected: [parent], deltaTime: 0.016)
		#expect(value(child) == 1)
		child.removeFromParent()
		driver.update(selected: [parent], deltaTime: 0.016)
		#expect(value(child) == 0)
	}

	@Test func materialsWithoutTheInputAreLeftAlone() async throws {
		guard #available(macOS 15.0, iOS 18.0, *) else { return }
		let entity = ModelEntity(mesh: .generateBox(size: 1), materials: [try await material("OtherMat")])
		var driver = ShaderSelectionDriver()
		select(entity)
		driver.update(selected: [entity], deltaTime: 0.016)
		#expect(value(entity, "Glow") == 0)
	}
}
