//
//  SelectionCompositor.swift
//  SelectionEffects
//
//  The renderer-agnostic half of the selection effects: given a mask of style
//  indices and depths, draws outline rings and highlight fills over a frame.
//  The RealityKit path (`SelectionRenderer`) rasterizes its mask from meshes
//  and hands it to this type; any other Metal renderer can write its own mask
//  (a ray marcher, a rasterizer) and do the same.
//

import CoreGraphics
import Foundation
import Metal
import os
import simd

/// Composites selection outlines and highlights over a rendered frame, from a
/// selection mask your renderer draws.
///
/// You render the selected objects into two textures the size of the frame:
///
/// - a **mask**, `r8Uint`, holding at each pixel the 1-based index of the
///   object's style in `styles` (0 where nothing is selected);
/// - optionally a **mask depth**, the nearest selected surface's depth at each
///   masked pixel (its value elsewhere is ignored).
///
/// `encode(...)` then grows each outline style's silhouette by its width in
/// pixels, fills highlight styles, and blends the result over `source` into
/// `target`. With a mask depth and a **scene depth** (the depth of everything
/// in the frame), parts of the selection hidden behind other geometry are drawn
/// at their style's `occludedOpacity`.
///
/// Depths can be depth textures (`depth32Float`, `depth32Float_stencil8`) or
/// float color textures (`r32Float`, `r16Float`, read from the red channel), so
/// a ray marcher can pass its hit distances directly. Both depths must use the
/// same convention, described by `DepthComparison`. The scene depth can have a
/// different size from the mask; it's sampled at the matching position.
///
/// The compositor holds no frame state: it only caches its pipelines and one
/// intermediate texture per command queue, so one instance can serve several
/// views. It's safe to call from any thread.
@available(iOS 15.0, macOS 12.0, tvOS 26.0, visionOS 1.0, *)
public final class SelectionCompositor: @unchecked Sendable {

	// MARK: - Styles

	/// How the pixels of one mask index are drawn.
	public struct Style: Hashable, Sendable {
		/// The kind of effect.
		public enum Kind: UInt32, Hashable, Sendable {
			/// A ring of `width` pixels around the silhouette.
			case outline = 0
			/// A translucent fill over the silhouette (for example, hover).
			case highlight = 1
		}

		public var kind: Kind
		/// sRGB-encoded RGBA, nominally in 0…1 (extended-range values are kept).
		/// Alpha is the blend opacity.
		public var color: SIMD4<Float>
		/// Outline width in pixels, clamped to `0...SelectionCompositor.maxWidth`.
		/// Keep it 0 for highlights (a nonzero width also draws a ring).
		public var width: Int
		/// Highlight coverage in 0…1; multiplies the color's alpha. Ignored for
		/// outlines.
		public var strength: Float
		/// Alpha multiplier, 0…1, where the selection is hidden behind other
		/// geometry: `1` draws it like the rest (X-ray), `0` hides it. Needs a
		/// mask depth and a scene depth.
		public var occludedOpacity: Float

		public init(kind: Kind, color: SIMD4<Float>, width: Int, strength: Float, occludedOpacity: Float) {
			self.kind = kind
			self.color = color
			self.width = width
			self.strength = strength
			self.occludedOpacity = occludedOpacity
		}

		/// A ring of `width` pixels around the silhouette.
		public static func outline(color: SIMD4<Float>, width: Int = 3, occludedOpacity: Float = 1) -> Style {
			Style(kind: .outline, color: color, width: width, strength: 1, occludedOpacity: occludedOpacity)
		}

		/// A translucent fill over the silhouette, covering it by
		/// `strength × color.a`.
		public static func highlight(color: SIMD4<Float>, strength: Float = 0.4, occludedOpacity: Float = 0) -> Style {
			Style(kind: .highlight, color: color, width: 0, strength: strength, occludedOpacity: occludedOpacity)
		}
	}

	/// How the mask depth and the scene depth compare.
	public struct DepthComparison: Equatable, Sendable {
		/// True when nearer surfaces have larger values (reversed Z).
		public var nearerIsLarger: Bool
		/// Tolerance: the selection counts as hidden only when it's farther than
		/// the scene by more than this, in the depths' own units.
		public var epsilon: Float

		public init(nearerIsLarger: Bool, epsilon: Float) {
			self.nearerIsLarger = nearerIsLarger
			self.epsilon = epsilon
		}

		/// Normalized device depth, 0 near and 1 far.
		public static let standard = DepthComparison(nearerIsLarger: false, epsilon: 1e-4)
		/// Reversed normalized device depth, 1 near and 0 far.
		public static let reversed = DepthComparison(nearerIsLarger: true, epsilon: 1e-5)

		/// Distances along the view ray (a ray marcher's hit distance), in scene
		/// units. Store a miss as a large value (or infinity) in the scene depth.
		public static func distance(epsilon: Float = 1e-3) -> DepthComparison {
			DepthComparison(nearerIsLarger: false, epsilon: epsilon)
		}

		/// The convention of the depth buffer `projection` renders into.
		public init(projection: simd_float4x4) {
			self = SelectionCompositor.isReversedZ(projection) ? .reversed : .standard
		}
	}

	/// Why `encode(...)` drew nothing.
	public enum CompositorError: Error, Equatable, Sendable {
		/// The package's shader library couldn't be loaded.
		case libraryUnavailable
		/// A pipeline couldn't be built.
		case pipelineUnavailable(String)
		/// A texture has a pixel format the compositor can't read or write.
		case unsupportedPixelFormat(texture: String, format: MTLPixelFormat)
		/// A texture's size doesn't match the frame's.
		case sizeMismatch(texture: String)
		/// An intermediate texture couldn't be allocated.
		case textureAllocationFailed
		/// The command buffer didn't provide an encoder.
		case encoderUnavailable
	}

	/// Number of distinct styles a mask can address (indices 1…127; the mask's
	/// eighth bit is used internally).
	public static let maxStyles = 127

	/// Largest outline width in pixels. The dilate pass scans a (2w+1)²
	/// neighborhood per pixel, so larger values would stall the GPU.
	public static let maxWidth = 32

	/// The device the pipelines are built for.
	public let device: any MTLDevice

	// MARK: - Init

	// Also holds the RealityKit mask pass (`SelectionRenderer`).
	let library: any MTLLibrary
	// 1×1 float texture bound when no depth is given (never read then).
	private let placeholderDepth: any MTLTexture

	private struct Pipelines {
		let dilate: any MTLComputePipelineState
		let composite: any MTLComputePipelineState
	}

	private struct DepthKinds: Hashable {
		let maskIsFloat: Bool
		let sceneIsFloat: Bool
	}

	private struct EdgeTexture {
		weak var queue: (any MTLCommandQueue)?
		let texture: any MTLTexture
	}

	private let lock = NSLock()
	private var pipelines: [DepthKinds: Pipelines] = [:]
	// Per command queue, recreated only when the frame size changes. Per queue,
	// because frames on different queues can run on the GPU at once.
	private var edgeTextures: [ObjectIdentifier: EdgeTexture] = [:]
	private var loggedSRGBViewFailure = false

	static let logger = Logger(subsystem: "SelectionEffects", category: "SelectionCompositor")

	/// Loads the shaders for `device`. Pipelines are built on first use, or
	/// ahead of time with `prepare(maskDepthFormat:sceneDepthFormat:)`.
	public init(device: any MTLDevice) throws {
		self.device = device
		guard let library = Self.makeLibrary(device: device) else { throw CompositorError.libraryUnavailable }
		self.library = library
		let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
		desc.usage = .shaderRead
		desc.storageMode = .private
		guard let placeholder = device.makeTexture(descriptor: desc) else { throw CompositorError.textureAllocationFailed }
		self.placeholderDepth = placeholder
	}

	/// Builds the pipelines for these depth formats now, so the first frame
	/// doesn't compile them. `nil` stands for no depth texture.
	public func prepare(maskDepthFormat: MTLPixelFormat?, sceneDepthFormat: MTLPixelFormat?) throws {
		let mask = try maskDepthFormat.map { try Self.depthKind($0, name: "maskDepth") } ?? true
		let scene = try sceneDepthFormat.map { try Self.depthKind($0, name: "sceneDepth") } ?? mask
		_ = try pipelines(for: DepthKinds(maskIsFloat: mask, sceneIsFloat: scene))
	}

	/// Whether `texture` can be passed as a mask depth or scene depth.
	public static func canReadDepth(_ texture: any MTLTexture) -> Bool {
		texture.textureType == .type2D && (try? depthKind(texture.pixelFormat, name: "")) != nil
	}

	// MARK: - Encoding

	/// Encodes the outline and highlight passes, reading `source` and writing
	/// every pixel of `target`.
	///
	/// - Parameters:
	///   - commandBuffer: Receives two compute passes.
	///   - source: The rendered frame. Any readable float color format.
	///   - target: Receives the frame with the effects; the same size as
	///     `source`, writable from a shader (`.shaderWrite`), and a different
	///     texture from `source`. An 8-bit sRGB target is written through a
	///     linear view on GPUs that can't write sRGB from shaders.
	///   - mask: `r8Uint`, the size of `source`: each pixel's 1-based index into
	///     `styles`, or 0. Indices beyond `styles` draw nothing.
	///   - maskDepth: The nearest selected surface's depth, the size of `mask`.
	///     Without it, the selection is always drawn as visible.
	///   - sceneDepth: The frame's depth. Without it, the selection is always
	///     drawn as visible.
	///   - styles: At most `maxStyles`; extra ones are ignored.
	///   - depth: How the two depths compare.
	/// - Throws: `CompositorError` before anything is encoded when an input is
	///   invalid; `.encoderUnavailable` possibly after the first pass. In both
	///   cases `target` hasn't been written: copy `source` into it yourself if
	///   the frame must still be shown.
	public func encode(
		commandBuffer: any MTLCommandBuffer,
		source: any MTLTexture,
		target: any MTLTexture,
		mask: any MTLTexture,
		maskDepth: (any MTLTexture)?,
		sceneDepth: (any MTLTexture)?,
		styles: [Style],
		depth: DepthComparison
	) throws {
		let w = source.width, h = source.height
		guard mask.pixelFormat == .r8Uint else {
			throw CompositorError.unsupportedPixelFormat(texture: "mask", format: mask.pixelFormat)
		}
		guard mask.width == w, mask.height == h else { throw CompositorError.sizeMismatch(texture: "mask") }
		guard target.width == w, target.height == h else { throw CompositorError.sizeMismatch(texture: "target") }
		if let maskDepth, maskDepth.width != w || maskDepth.height != h {
			throw CompositorError.sizeMismatch(texture: "maskDepth")
		}

		// Without a mask depth there is nothing to compare: bind placeholders
		// and switch the comparison off. Without a scene depth, the mask depth
		// stands in for it, unused.
		let useDepth = maskDepth != nil && sceneDepth != nil
		let maskDepthTexture = maskDepth ?? placeholderDepth
		let sceneDepthTexture = (useDepth ? sceneDepth : nil) ?? maskDepthTexture
		let kinds = DepthKinds(
			maskIsFloat: try Self.depthKind(maskDepthTexture.pixelFormat, name: "maskDepth"),
			sceneIsFloat: try Self.depthKind(sceneDepthTexture.pixelFormat, name: "sceneDepth")
		)
		let pipelines = try pipelines(for: kinds)
		let output = try writableTarget(target)
		let edge = try edgeTexture(queue: commandBuffer.commandQueue, w: w, h: h)

		var gpuStyles = Self.gpuStyles(Array(styles.prefix(Self.maxStyles)))
		// Pad to every index the mask can hold, so any index reads a style
		// (padding draws nothing: width 0, outline kind).
		gpuStyles += Array(repeating: Self.emptyStyle, count: Self.maxStyles + 1 - gpuStyles.count)
		var maxWidth = gpuStyles.map(\.width).max() ?? 0
		var depthParams = DepthParams(
			useSceneDepth: useDepth ? 1 : 0,
			reversedZ: depth.nearerIsLarger ? 1 : 0,
			epsilon: depth.epsilon
		)

		// Pass 2 — grow outline rings around the silhouettes.
		guard let dilate = commandBuffer.makeComputeCommandEncoder() else { throw CompositorError.encoderUnavailable }
		dilate.setComputePipelineState(pipelines.dilate)
		dilate.setTexture(mask, index: 0)
		dilate.setTexture(edge, index: 1)
		dilate.setTexture(maskDepthTexture, index: kinds.maskIsFloat ? 6 : 2)
		dilate.setTexture(sceneDepthTexture, index: kinds.sceneIsFloat ? 7 : 3)
		dilate.setBytes(&maxWidth, length: MemoryLayout<Int32>.size, index: 0)
		gpuStyles.withUnsafeBytes { dilate.setBytes($0.baseAddress!, length: $0.count, index: 1) }
		dilate.setBytes(&depthParams, length: MemoryLayout<DepthParams>.stride, index: 2)
		Self.dispatch(dilate, w: w, h: h)
		dilate.endEncoding()

		// Pass 3 — blend rings and highlight fills over the source frame.
		guard let composite = commandBuffer.makeComputeCommandEncoder() else { throw CompositorError.encoderUnavailable }
		composite.setComputePipelineState(pipelines.composite)
		composite.setTexture(source, index: 0)
		composite.setTexture(edge, index: 1)
		composite.setTexture(output.texture, index: 2)
		composite.setTexture(mask, index: 3)
		composite.setTexture(maskDepthTexture, index: kinds.maskIsFloat ? 6 : 4)
		composite.setTexture(sceneDepthTexture, index: kinds.sceneIsFloat ? 7 : 5)
		gpuStyles.withUnsafeBytes { composite.setBytes($0.baseAddress!, length: $0.count, index: 0) }
		var encodeSRGB: UInt32 = output.encodeSRGB ? 1 : 0
		composite.setBytes(&encodeSRGB, length: MemoryLayout<UInt32>.size, index: 1)
		composite.setBytes(&depthParams, length: MemoryLayout<DepthParams>.stride, index: 2)
		Self.dispatch(composite, w: w, h: h)
		composite.endEncoding()
	}

	// MARK: - Shader-side types

	/// Shader-side style, matching `SelectionStyle` in OutlineShaders.metal (32 bytes).
	struct GPUStyle: Equatable {
		var color: SIMD4<Float>
		var occludedOpacity: Float
		var strength: Float
		var kind: UInt32
		var width: Int32
	}

	/// Matches `DepthParams` in OutlineShaders.metal.
	struct DepthParams {
		var useSceneDepth: UInt32
		var reversedZ: UInt32
		var epsilon: Float
	}

	static let emptyStyle = GPUStyle(color: .zero, occludedOpacity: 1, strength: 0, kind: 0, width: 0)

	/// Per-style shader inputs, indexed by style (index 0 is unused), with
	/// colors converted to linear and widths clamped.
	static func gpuStyles(_ styles: [Style]) -> [GPUStyle] {
		[emptyStyle]
			+ styles.map {
				GPUStyle(
					color: linear(fromSRGB: $0.color),
					occludedOpacity: min(max($0.occludedOpacity, 0), 1),
					strength: min(max($0.strength, 0), 1),
					kind: $0.kind.rawValue,
					width: Int32(clampWidth($0.width))
				)
			}
	}

	static func clampWidth(_ width: Int) -> Int {
		min(max(width, 0), maxWidth)
	}

	/// sRGB-encoded RGBA → linear RGB (alpha unchanged). Extended-range
	/// components (below 0 or above 1, from wide-gamut colors) are kept, using
	/// the sign-mirrored transfer function of extended sRGB.
	static func linear(fromSRGB c: SIMD4<Float>) -> SIMD4<Float> {
		func channel(_ v: Float) -> Float {
			let a = abs(v)
			let l = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
			return v < 0 ? -l : l
		}
		return SIMD4(channel(c.x), channel(c.y), channel(c.z), c.w)
	}

	/// Whether `projection` maps nearer points to larger depth (reversed Z).
	static func isReversedZ(_ projection: simd_float4x4) -> Bool {
		func depth(at z: Float) -> Float {
			let clip = projection * SIMD4<Float>(0, 0, z, 1)
			return clip.z / clip.w
		}
		return depth(at: -1) > depth(at: -10)
	}

	/// A `CGColor` as sRGB-encoded RGBA components, for `Style.color`.
	/// `nil` if it can't be converted.
	public static func srgbComponents(of color: CGColor) -> SIMD4<Float>? {
		guard
			let srgb = CGColorSpace(name: CGColorSpace.sRGB),
			let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
			let c = converted.components, c.count >= 4
		else { return nil }
		return SIMD4(Float(c[0]), Float(c[1]), Float(c[2]), Float(c[3]))
	}

	// MARK: - Helpers

	/// Whether a depth input of `format` is read as a float color texture
	/// (true) or as a depth texture (false).
	private static func depthKind(_ format: MTLPixelFormat, name: String) throws -> Bool {
		switch format {
		case .depth32Float, .depth32Float_stencil8: return false
		case .r32Float, .r16Float: return true
		default: throw CompositorError.unsupportedPixelFormat(texture: name, format: format)
		}
	}

	private func pipelines(for kinds: DepthKinds) throws -> Pipelines {
		try lock.withLock {
			if let cached = pipelines[kinds] { return cached }
			let constants = MTLFunctionConstantValues()
			var maskIsFloat = kinds.maskIsFloat, sceneIsFloat = kinds.sceneIsFloat
			constants.setConstantValue(&maskIsFloat, type: .bool, index: 0)
			constants.setConstantValue(&sceneIsFloat, type: .bool, index: 1)
			func make(_ name: String) throws -> any MTLComputePipelineState {
				do {
					let function = try library.makeFunction(name: name, constantValues: constants)
					return try device.makeComputePipelineState(function: function)
				} catch {
					Self.logger.error("Failed to build \(name, privacy: .public) pipeline: \(error.localizedDescription, privacy: .public)")
					throw CompositorError.pipelineUnavailable(name)
				}
			}
			let built = Pipelines(dilate: try make("outlineDilate"), composite: try make("outlineComposite"))
			pipelines[kinds] = built
			return built
		}
	}

	/// Loads the package's compiled shaders, falling back to the main bundle's default library.
	private static func makeLibrary(device: any MTLDevice) -> (any MTLLibrary)? {
		do {
			return try device.makeDefaultLibrary(bundle: .module)
		} catch {
			logger.error("Failed to load shader library from package bundle: \(error.localizedDescription, privacy: .public). Falling back to the default library.")
		}
		if let library = device.makeDefaultLibrary(), library.functionNames.contains("outlineComposite") {
			return library
		}
		logger.error("No Metal library containing the outline shaders was found. Selection effects are disabled.")
		return nil
	}

	/// Returns `queue`'s cached edge texture, recreating it only when the size changes.
	private func edgeTexture(queue: any MTLCommandQueue, w: Int, h: Int) throws -> any MTLTexture {
		try lock.withLock {
			let key = ObjectIdentifier(queue)
			if let cached = edgeTextures[key], cached.queue === queue,
				cached.texture.width == w, cached.texture.height == h
			{
				return cached.texture
			}
			let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: w, height: h, mipmapped: false)
			desc.usage = [.shaderRead, .shaderWrite]
			desc.storageMode = .private
			guard let texture = device.makeTexture(descriptor: desc) else {
				Self.logger.error("Failed to allocate a \(w)x\(h) outline texture.")
				throw CompositorError.textureAllocationFailed
			}
			edgeTextures = edgeTextures.filter { $0.value.queue != nil }
			edgeTextures[key] = EdgeTexture(queue: queue, texture: texture)
			return texture
		}
	}

	/// GPUs without `.apple2` support can't write sRGB textures from a shader.
	/// Following Apple's guidance, an 8-bit sRGB target is written through a
	/// non-sRGB view, with the composite pass encoding linear→sRGB itself
	/// (`encodeSRGB`) so the frame doesn't darken. Other formats (RealityKit
	/// also hands out `rgba16Float` targets) are written directly; creating a
	/// view of an incompatible format would abort instead of returning nil.
	/// https://developer.apple.com/documentation/realitykit/checking-the-pixel-format-of-a-postprocess-effect-s-output-texture
	private func writableTarget(_ target: any MTLTexture) throws -> (texture: any MTLTexture, encodeSRGB: Bool) {
		if device.supportsFamily(.apple2) { return (target, false) }

		let viewFormat: MTLPixelFormat
		switch target.pixelFormat {
		case .bgra8Unorm_srgb: viewFormat = .bgra8Unorm
		case .rgba8Unorm_srgb: viewFormat = .rgba8Unorm
		default: return (target, false)
		}
		// Switching only between sRGB and linear variants of the same layout
		// doesn't need `.pixelFormatView` usage.
		guard let view = target.makeTextureView(pixelFormat: viewFormat) else {
			let first = lock.withLock {
				defer { loggedSRGBViewFailure = true }
				return !loggedSRGBViewFailure
			}
			if first { Self.logger.error("Can't write the sRGB output texture on this GPU; selection effects skipped.") }
			throw CompositorError.unsupportedPixelFormat(texture: "target", format: target.pixelFormat)
		}
		return (view, true)
	}

	private static func dispatch(_ encoder: any MTLComputeCommandEncoder, w: Int, h: Int) {
		let tg = MTLSize(width: 16, height: 16, depth: 1)
		let grid = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
		encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
	}
}
