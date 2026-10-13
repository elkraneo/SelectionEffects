//
//  ARView+SelectionEffects.swift
//  SelectionEffects
//
//  Created by Cristian Díaz on 13.10.26.
//

#if !os(visionOS)

import Foundation
import Metal
import ObjectiveC
import RealityKit

@available(iOS 15.0, macOS 12.0, tvOS 26.0, *)
@available(visionOS, unavailable)
extension ARView {
	/// Draws `SelectionEffectComponent` effects in this view.
	///
	/// The outline runs in `renderCallbacks.postProcess`. Callbacks already set
	/// when the effects start (on the next frame) are kept and run first; set
	/// callbacks after that and they replace the effects. The view's camera is
	/// read every frame, so no camera entity is needed.
	@MainActor
	public func installSelectionEffects() {
		removeSelectionEffects()

		let renderer = SelectionRenderer()
		let installation = SelectionEffectsInstallation()
		let host = SelectionEffectsHost(
			renderer: renderer,
			viewMatrix: { [weak self] _ in self?.cameraTransform.matrix.inverse },
			attach: { [weak self, weak installation] in
				guard let self, let installation else { return }
				installation.previousCallbacks = self.renderCallbacks
				self.renderCallbacks = SelectionEffectsInstallation.chain(
					renderer: renderer,
					after: self.renderCallbacks
				)
				installation.attached = true
			}
		)
		let anchor = AnchorEntity(world: .zero)
		anchor.name = "SelectionEffects"
		anchor.addChild(host.makeEntity())
		scene.addAnchor(anchor)
		installation.anchor = anchor
		SelectionEffectsInstallation.set(installation, on: self)
	}

	/// Stops drawing selection effects and restores the render callbacks that
	/// were set before `installSelectionEffects()`.
	@MainActor
	public func removeSelectionEffects() {
		guard let installation = SelectionEffectsInstallation.get(from: self) else { return }
		if let anchor = installation.anchor {
			scene.removeAnchor(anchor)
		}
		if installation.attached {
			renderCallbacks = installation.previousCallbacks
		}
		SelectionEffectsInstallation.set(nil, on: self)
		OutlineGeometryCache.shared.pruneReleasedEntities(force: true)
	}
}

/// What `installSelectionEffects()` changed on an `ARView`, so it can be undone.
@available(iOS 15.0, macOS 12.0, tvOS 26.0, *)
@available(visionOS, unavailable)
@MainActor
private final class SelectionEffectsInstallation {
	var anchor: AnchorEntity?
	var previousCallbacks = ARView.RenderCallbacks()
	var attached = false

	private nonisolated(unsafe) static var key: UInt8 = 0

	static func set(_ installation: SelectionEffectsInstallation?, on view: ARView) {
		objc_setAssociatedObject(view, &key, installation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
	}

	static func get(from view: ARView) -> SelectionEffectsInstallation? {
		objc_getAssociatedObject(view, &key) as? SelectionEffectsInstallation
	}

	/// Render callbacks that run `previous` first, then the outline. Built
	/// outside any actor: RealityKit calls them on its render thread.
	nonisolated static func chain(
		renderer: SelectionRenderer,
		after previous: ARView.RenderCallbacks
	) -> ARView.RenderCallbacks {
		let chained = ChainedPostProcess(renderer: renderer, previous: previous)
		var callbacks = ARView.RenderCallbacks()
		callbacks.prepareWithDevice = { device in chained.prepare(device: device) }
		callbacks.postProcess = { context in chained.postProcess(context) }
		return callbacks
	}
}

/// Runs an app's existing post-process into an intermediate texture, then the
/// outline from that texture into the frame.
@available(iOS 15.0, macOS 12.0, tvOS 26.0, *)
@available(visionOS, unavailable)
private final class ChainedPostProcess: @unchecked Sendable {
	private let renderer: SelectionRenderer
	private let previous: ARView.RenderCallbacks
	private let lock = NSLock()
	private var intermediate: (any MTLTexture)?

	init(renderer: SelectionRenderer, previous: ARView.RenderCallbacks) {
		self.renderer = renderer
		self.previous = previous
	}

	func prepare(device: any MTLDevice) {
		previous.prepareWithDevice?(device)
		renderer.prepare(device: device)
	}

	func postProcess(_ context: ARView.PostProcessContext) {
		var source = context.sourceColorTexture
		if let earlier = previous.postProcess {
			guard let texture = intermediateTexture(like: context.targetColorTexture, device: context.device) else {
				// No room for both: keep the app's effect.
				earlier(context)
				return
			}
			var first = context
			first.targetColorTexture = texture
			earlier(first)
			source = texture
		}
		renderer.encode(
			device: context.device,
			commandBuffer: context.commandBuffer,
			source: source,
			sourceDepth: context.sourceDepthTexture,
			target: context.targetColorTexture,
			projection: context.projection
		)
	}

	private func intermediateTexture(like target: any MTLTexture, device: any MTLDevice) -> (any MTLTexture)? {
		lock.withLock {
			if let texture = intermediate, texture.device === device,
				texture.width == target.width, texture.height == target.height,
				texture.pixelFormat == target.pixelFormat
			{
				return texture
			}
			let descriptor = MTLTextureDescriptor.texture2DDescriptor(
				pixelFormat: target.pixelFormat,
				width: target.width,
				height: target.height,
				mipmapped: false
			)
			descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
			descriptor.storageMode = .private
			intermediate = device.makeTexture(descriptor: descriptor)
			return intermediate
		}
	}
}

#endif
