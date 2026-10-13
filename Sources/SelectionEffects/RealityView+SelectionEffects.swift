//
//  RealityView+SelectionEffects.swift
//  SelectionEffects
//
//  Created by Cristian Díaz on 13.10.26.
//

#if !os(visionOS)

import Metal
import RealityKit
import SwiftUI

@available(iOS 26.0, macOS 26.0, tvOS 26.0, *)
@available(visionOS, unavailable)
extension RealityViewCameraContent {
	/// Draws `SelectionEffectComponent` effects in this `RealityView`.
	///
	/// Call it once, in the make closure. It sets the view's custom
	/// post-processing effect, so it replaces any other one you set.
	///
	/// ```swift
	/// RealityView { content in
	///     content.installSelectionEffects()
	///     // …
	/// }
	/// ```
	///
	/// The scene needs a camera entity with `PerspectiveCameraComponent`.
	///
	/// - Parameter cachesGeometry: Cache each entity's outline geometry (default).
	///   Turn it off for content edited in place, such as a live USD stage: a mesh
	///   changed with `MeshResource.replace(with:)` that keeps its bounds would
	///   otherwise keep its old outline.
	@MainActor
	public mutating func installSelectionEffects(cachesGeometry: Bool = true) {
		let renderer = SelectionRenderer()
		renderer.cachesGeometry = cachesGeometry
		let effect = SelectionOutlinePostProcess(renderer: renderer)
		// Attach the effect on the first scene update, through a copy of the
		// content, rather than here. On macOS 27, setting `customPostProcessing`
		// before the view has rendered traps inside RealityKit: in make 3 of 3
		// runs, from `update:` 5 of 8, on the first update 0 of 8. The
		// `ARView.renderCallbacks` setter that backs it force-unwraps the camera's
		// RECameraViewDescriptorsComponent, which exists only once rendering has
		// started. Apple's documentation sets no timing rule for this property, so
		// this is most likely a RealityKit bug. See Docs/PostProcessTiming.md;
		// remove this workaround once it's fixed.
		var content = self
		let host = SelectionEffectsHost(
			renderer: renderer,
			viewMatrix: SelectionEffectsHost.sceneCameraViewMatrix,
			attach: { content.renderingEffects.customPostProcessing = .effect(effect) }
		)
		add(host.makeEntity())
	}
}

/// The `PostProcessEffect` behind `installSelectionEffects()`.
@available(iOS 26.0, macOS 26.0, tvOS 26.0, *)
@available(visionOS, unavailable)
struct SelectionOutlinePostProcess: PostProcessEffect {
	let renderer: SelectionRenderer

	func prepare(for device: any MTLDevice) {
		renderer.prepare(device: device)
	}

	func postProcess(context: borrowing PostProcessEffectContext<any MTLCommandBuffer>) {
		renderer.encode(
			device: context.device,
			commandBuffer: context.commandBuffer,
			source: context.sourceColorTexture,
			sourceDepth: context.sourceDepthTexture,
			target: context.targetColorTexture,
			projection: context.projection
		)
	}
}

#endif
