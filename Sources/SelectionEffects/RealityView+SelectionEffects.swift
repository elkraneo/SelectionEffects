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
import simd

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
	/// - Parameters:
	///   - camera: The entity whose `PerspectiveCameraComponent` renders the view.
	///     If `nil`, the scene's first active perspective camera is used; pass it
	///     when the scene can contain other cameras (loaded USD content, for example).
	///   - frameHandler: Called on the render thread with each frame, after the
	///     selection effects are encoded. RealityView allows a single
	///     post-processing effect, and one effect can't hand the frame to
	///     another, so this is where to capture the frame or draw your own effect
	///     over it. See `SelectionEffectsFrame` for the frame's lifetime.
	@MainActor
	public mutating func installSelectionEffects(
		camera: Entity? = nil,
		frameHandler: (@Sendable (SelectionEffectsFrame) -> Void)? = nil
	) {
		let renderer = SelectionRenderer()
		let effect = SelectionOutlinePostProcess(renderer: renderer, frameHandler: frameHandler)
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
			viewMatrix: { [weak camera] scene in
				guard let camera else { return SelectionEffectsHost.sceneCameraViewMatrix(scene) }
				let noRef: Entity? = nil
				return camera.transformMatrix(relativeTo: noRef).inverse
			},
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
	let frameHandler: (@Sendable (SelectionEffectsFrame) -> Void)?

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
		frameHandler?(
			SelectionEffectsFrame(
				device: context.device,
				commandBuffer: context.commandBuffer,
				texture: context.targetColorTexture,
				depthTexture: context.sourceDepthTexture,
				projection: context.projection,
				time: context.time
			)
		)
	}
}

/// A frame whose selection effects have been encoded, handed to the
/// `frameHandler` of `installSelectionEffects(camera:frameHandler:)`.
///
/// The handler runs on RealityKit's render thread, once per frame, before the
/// command buffer is committed; nothing has executed on the GPU yet. Encode
/// your own work into `commandBuffer` **synchronously, before the handler
/// returns**: read `texture` (blit it to your own texture to capture the
/// frame; read the copy in a completed handler) or draw into it. Don't keep
/// the frame, the command buffer or the textures after the handler returns:
/// RealityKit commits the buffer and reuses the textures.
@available(iOS 26.0, macOS 26.0, tvOS 26.0, *)
@available(visionOS, unavailable)
public struct SelectionEffectsFrame {
	public let device: any MTLDevice
	public let commandBuffer: any MTLCommandBuffer
	/// The view's output texture, with the selection effects drawn.
	public let texture: any MTLTexture
	/// The scene depth RealityKit rendered.
	public let depthTexture: any MTLTexture
	public let projection: simd_float4x4
	public let time: TimeInterval
}

#endif
