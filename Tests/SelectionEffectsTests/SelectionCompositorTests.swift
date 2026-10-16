//
//  SelectionCompositorTests.swift
//  SelectionEffects
//
//  Renders tiny frames offscreen through `SelectionCompositor` and checks pixels.
//

import Metal
import Testing
import simd

#if !os(visionOS)
import RealityKit
#endif

@testable import SelectionEffects

private let hasMetal = MTLCreateSystemDefaultDevice() != nil

/// A 32×32 offscreen frame: black source, a mask, optional depths, a float target.
private final class Bench {
	static let size = 32

	let device: any MTLDevice
	let queue: any MTLCommandQueue
	let compositor: SelectionCompositor
	let source: any MTLTexture
	let target: any MTLTexture
	let mask: any MTLTexture

	init() throws {
		device = try #require(MTLCreateSystemDefaultDevice())
		queue = try #require(device.makeCommandQueue())
		compositor = try SelectionCompositor(device: device)
		source = try Self.texture(device, .rgba32Float, usage: .shaderRead)
		target = try Self.texture(device, .rgba32Float, usage: [.shaderRead, .shaderWrite])
		mask = try Self.texture(device, .r8Uint, usage: .shaderRead)
		try upload([SIMD4<Float>](repeating: [0, 0, 0, 1], count: Self.size * Self.size), to: source)
		try upload([UInt8](repeating: 0, count: Self.size * Self.size), to: mask)
	}

	static func texture(
		_ device: any MTLDevice,
		_ format: MTLPixelFormat,
		usage: MTLTextureUsage,
		size: Int = Bench.size
	) throws -> any MTLTexture {
		let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
		desc.usage = usage
		desc.storageMode = .private
		return try #require(device.makeTexture(descriptor: desc))
	}

	func texture(_ format: MTLPixelFormat, size: Int = Bench.size) throws -> any MTLTexture {
		try Self.texture(device, format, usage: .shaderRead, size: size)
	}

	/// Copies row-major `values` into `texture` through a staging buffer.
	func upload<T>(_ values: [T], to texture: any MTLTexture) throws {
		let rowBytes = MemoryLayout<T>.stride * texture.width
		let buffer = try values.withUnsafeBytes {
			try #require(device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared))
		}
		let cb = try #require(queue.makeCommandBuffer())
		let blit = try #require(cb.makeBlitCommandEncoder())
		blit.copy(
			from: buffer, sourceOffset: 0, sourceBytesPerRow: rowBytes,
			sourceBytesPerImage: rowBytes * texture.height,
			sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
			to: texture, destinationSlice: 0, destinationLevel: 0,
			destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
		)
		blit.endEncoding()
		cb.commit()
		cb.waitUntilCompleted()
	}

	/// A row-major image of `size`² values, `inside` within the square
	/// `rect` (x0..<x1, y0..<y1), `outside` elsewhere.
	static func image<T>(
		_ outside: T,
		_ inside: T,
		x: Range<Int>,
		y: Range<Int>,
		size: Int = Bench.size
	) -> [T] {
		var values = [T](repeating: outside, count: size * size)
		for py in y { for px in x { values[py * size + px] = inside } }
		return values
	}

	/// Runs the compositor and returns the target's pixels.
	func run(
		styles: [SelectionCompositor.Style],
		maskDepth: (any MTLTexture)? = nil,
		sceneDepth: (any MTLTexture)? = nil,
		depth: SelectionCompositor.DepthComparison = .standard
	) throws -> [SIMD4<Float>] {
		let cb = try #require(queue.makeCommandBuffer())
		try compositor.encode(
			commandBuffer: cb, source: source, target: target, mask: mask,
			maskDepth: maskDepth, sceneDepth: sceneDepth, styles: styles, depth: depth
		)
		return try readTarget(after: cb)
	}

	/// Commits `cb` with a copy of the target appended, and returns its pixels.
	func readTarget(after cb: any MTLCommandBuffer) throws -> [SIMD4<Float>] {
		let count = Self.size * Self.size
		let rowBytes = MemoryLayout<SIMD4<Float>>.stride * Self.size
		let readback = try #require(device.makeBuffer(length: rowBytes * Self.size, options: .storageModeShared))
		let blit = try #require(cb.makeBlitCommandEncoder())
		blit.copy(
			from: target, sourceSlice: 0, sourceLevel: 0,
			sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
			sourceSize: MTLSize(width: Self.size, height: Self.size, depth: 1),
			to: readback, destinationOffset: 0,
			destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * Self.size
		)
		blit.endEncoding()
		cb.commit()
		cb.waitUntilCompleted()
		#expect(cb.status == .completed)
		let pointer = readback.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
		return Array(UnsafeBufferPointer(start: pointer, count: count))
	}
}

private extension Array where Element == SIMD4<Float> {
	subscript(x x: Int, y y: Int) -> SIMD4<Float> { self[y * Bench.size + x] }
}

private func close(_ a: SIMD4<Float>, _ b: SIMD4<Float>, tolerance: Float = 1e-3) -> Bool {
	simd_reduce_max(simd_abs(a - b)) <= tolerance
}

private let black: SIMD4<Float> = [0, 0, 0, 1]
private let red: SIMD4<Float> = [1, 0, 0, 1]

@Suite("Selection compositor", .enabled(if: hasMetal, "Needs a Metal device"))
struct SelectionCompositorTests {

	// Selected square: x 12..<20, y 12..<20.
	private let square = (x: 12..<20, y: 12..<20)

	@Test func outlineRingHasTheStyleWidthAndLeavesTheInsideAlone() throws {
		let bench = try Bench()
		try bench.upload(Bench.image(UInt8(0), 1, x: square.x, y: square.y), to: bench.mask)
		let pixels = try bench.run(styles: [.outline(color: red, width: 2)])

		#expect(close(pixels[x: 11, y: 15], red))   // 1 px out
		#expect(close(pixels[x: 10, y: 15], red))   // 2 px out
		#expect(close(pixels[x: 9, y: 15], black))  // 3 px out: beyond the width
		#expect(close(pixels[x: 21, y: 15], red))
		#expect(close(pixels[x: 22, y: 15], black))
		#expect(close(pixels[x: 15, y: 15], black)) // inside: untouched
		#expect(close(pixels[x: 0, y: 0], black))
		// Corners are round: (10, 10) is √8 > 2 px from the nearest selected pixel.
		#expect(close(pixels[x: 10, y: 10], black))
		#expect(close(pixels[x: 11, y: 11], red))
	}

	@Test func colorsAreSRGBEncodedAndAlphaBlends() throws {
		let bench = try Bench()
		try bench.upload(Bench.image(UInt8(0), 1, x: square.x, y: square.y), to: bench.mask)
		let pixels = try bench.run(styles: [.outline(color: [0.5, 1, 0, 0.5], width: 1)])
		let linearHalf = SelectionCompositor.linear(fromSRGB: [0.5, 0, 0, 1]).x  // ≈ 0.214
		#expect(close(pixels[x: 11, y: 15], [linearHalf * 0.5, 0.5, 0, 1]))
	}

	@Test func eachMaskIndexUsesItsOwnStyle() throws {
		let bench = try Bench()
		var mask = Bench.image(UInt8(0), 1, x: 4..<8, y: 12..<20)
		for y in 12..<20 { for x in 22..<26 { mask[y * Bench.size + x] = 2 } }
		try bench.upload(mask, to: bench.mask)
		let blue: SIMD4<Float> = [0, 0, 1, 1]
		let pixels = try bench.run(styles: [.outline(color: red, width: 1), .outline(color: blue, width: 3)])

		#expect(close(pixels[x: 3, y: 15], red))
		#expect(close(pixels[x: 2, y: 15], black))
		#expect(close(pixels[x: 19, y: 15], blue))  // 3 px left of the second square
		#expect(close(pixels[x: 18, y: 15], black))
	}

	@Test func highlightFillsTheSilhouetteWithoutARing() throws {
		let bench = try Bench()
		try bench.upload(Bench.image(UInt8(0), 1, x: square.x, y: square.y), to: bench.mask)
		let pixels = try bench.run(styles: [.highlight(color: [1, 1, 1, 1], strength: 0.5)])

		#expect(close(pixels[x: 15, y: 15], [0.5, 0.5, 0.5, 1]))
		#expect(close(pixels[x: 11, y: 15], black))
	}

	@Test func indicesWithoutAStyleDrawNothing() throws {
		let bench = try Bench()
		var mask = Bench.image(UInt8(0), 1, x: square.x, y: square.y)
		for y in 0..<4 { for x in 0..<4 { mask[y * Bench.size + x] = 9 } }
		try bench.upload(mask, to: bench.mask)
		let pixels = try bench.run(styles: [.outline(color: red, width: 2)])
		#expect(close(pixels[x: 5, y: 2], black))
		#expect(close(pixels[x: 10, y: 15], red))
	}

	/// Mask depth 5 everywhere it's selected; scene depth 2 (in front) on the
	/// left half of the frame, 10 (behind) on the right.
	private func rayDistanceDepths(_ bench: Bench) throws -> (any MTLTexture, any MTLTexture) {
		let maskDepth = try bench.texture(.r32Float)
		try bench.upload(Bench.image(Float.infinity, 5, x: square.x, y: square.y), to: maskDepth)
		let sceneDepth = try bench.texture(.r32Float)
		try bench.upload(Bench.image(Float(10), 2, x: 0..<16, y: 0..<32), to: sceneDepth)
		return (maskDepth, sceneDepth)
	}

	@Test func hiddenPartsUseOccludedOpacityWithRayDistances() throws {
		let bench = try Bench()
		try bench.upload(Bench.image(UInt8(0), 1, x: square.x, y: square.y), to: bench.mask)
		let (maskDepth, sceneDepth) = try rayDistanceDepths(bench)
		let pixels = try bench.run(
			styles: [.outline(color: red, width: 2, occludedOpacity: 0.25)],
			maskDepth: maskDepth, sceneDepth: sceneDepth, depth: .distance()
		)
		#expect(close(pixels[x: 10, y: 15], [0.25, 0, 0, 1]))  // left: behind the scene
		#expect(close(pixels[x: 21, y: 15], red))              // right: in front
	}

	@Test func hiddenHighlightUsesOccludedOpacity() throws {
		let bench = try Bench()
		try bench.upload(Bench.image(UInt8(0), 1, x: square.x, y: square.y), to: bench.mask)
		let (maskDepth, sceneDepth) = try rayDistanceDepths(bench)
		let pixels = try bench.run(
			styles: [.highlight(color: [1, 1, 1, 1], strength: 1, occludedOpacity: 0)],
			maskDepth: maskDepth, sceneDepth: sceneDepth, depth: .distance()
		)
		#expect(close(pixels[x: 13, y: 15], black))           // hidden: not drawn
		#expect(close(pixels[x: 18, y: 15], [1, 1, 1, 1]))    // visible: filled
	}

	@Test func depthTexturesWorkInBothConventions() throws {
		let bench = try Bench()
		try bench.upload(Bench.image(UInt8(0), 1, x: square.x, y: square.y), to: bench.mask)
		let maskDepth = try Bench.texture(bench.device, .depth32Float, usage: .shaderRead)
		let sceneDepth = try Bench.texture(bench.device, .depth32Float, usage: .shaderRead)
		let style = SelectionCompositor.Style.outline(color: red, width: 2, occludedOpacity: 0)

		// Standard: 0 near, 1 far. Selection at 0.5; scene 0.2 left, 0.9 right.
		try bench.upload(Bench.image(Float(1), 0.5, x: square.x, y: square.y), to: maskDepth)
		try bench.upload(Bench.image(Float(0.9), 0.2, x: 0..<16, y: 0..<32), to: sceneDepth)
		var pixels = try bench.run(styles: [style], maskDepth: maskDepth, sceneDepth: sceneDepth, depth: .standard)
		#expect(close(pixels[x: 10, y: 15], black))
		#expect(close(pixels[x: 21, y: 15], red))

		// Reversed: 1 near, 0 far. Same scene, mirrored values.
		try bench.upload(Bench.image(Float(0), 0.5, x: square.x, y: square.y), to: maskDepth)
		try bench.upload(Bench.image(Float(0.1), 0.8, x: 0..<16, y: 0..<32), to: sceneDepth)
		pixels = try bench.run(styles: [style], maskDepth: maskDepth, sceneDepth: sceneDepth, depth: .reversed)
		#expect(close(pixels[x: 10, y: 15], black))
		#expect(close(pixels[x: 21, y: 15], red))
	}

	@Test func sceneDepthOfAnotherSizeIsSampledAtTheSamePosition() throws {
		let bench = try Bench()
		try bench.upload(Bench.image(UInt8(0), 1, x: square.x, y: square.y), to: bench.mask)
		let maskDepth = try bench.texture(.r32Float)
		try bench.upload(Bench.image(Float.infinity, 5, x: square.x, y: square.y), to: maskDepth)
		let sceneDepth = try bench.texture(.r32Float, size: 16)  // half resolution
		try bench.upload(Bench.image(Float(10), 2, x: 0..<8, y: 0..<16, size: 16), to: sceneDepth)
		let pixels = try bench.run(
			styles: [.outline(color: red, width: 2, occludedOpacity: 0)],
			maskDepth: maskDepth, sceneDepth: sceneDepth, depth: .distance()
		)
		#expect(close(pixels[x: 10, y: 15], black))
		#expect(close(pixels[x: 21, y: 15], red))
	}

	@Test func withoutDepthEverythingIsVisible() throws {
		let bench = try Bench()
		try bench.upload(Bench.image(UInt8(0), 1, x: square.x, y: square.y), to: bench.mask)
		let (maskDepth, sceneDepth) = try rayDistanceDepths(bench)
		let style = SelectionCompositor.Style.outline(color: red, width: 2, occludedOpacity: 0)
		for (m, s) in [(nil, sceneDepth), (maskDepth, nil), (nil, nil)] as [((any MTLTexture)?, (any MTLTexture)?)] {
			let pixels = try bench.run(styles: [style], maskDepth: m, sceneDepth: s, depth: .distance())
			#expect(close(pixels[x: 10, y: 15], red))
		}
	}

	@Test func invalidInputsThrowBeforeEncoding() throws {
		let bench = try Bench()
		let cb = try #require(bench.queue.makeCommandBuffer())
		let floatMask = try bench.texture(.r32Float)
		#expect(throws: SelectionCompositor.CompositorError.unsupportedPixelFormat(texture: "mask", format: .r32Float)) {
			try bench.compositor.encode(
				commandBuffer: cb, source: bench.source, target: bench.target, mask: floatMask,
				maskDepth: nil, sceneDepth: nil, styles: [], depth: .standard
			)
		}
		let smallMask = try bench.texture(.r8Uint, size: 16)
		#expect(throws: SelectionCompositor.CompositorError.sizeMismatch(texture: "mask")) {
			try bench.compositor.encode(
				commandBuffer: cb, source: bench.source, target: bench.target, mask: smallMask,
				maskDepth: nil, sceneDepth: nil, styles: [], depth: .standard
			)
		}
		let colorDepth = try bench.texture(.rgba8Unorm)
		#expect(throws: SelectionCompositor.CompositorError.unsupportedPixelFormat(texture: "sceneDepth", format: .rgba8Unorm)) {
			try bench.compositor.encode(
				commandBuffer: cb, source: bench.source, target: bench.target, mask: bench.mask,
				maskDepth: try bench.texture(.r32Float), sceneDepth: colorDepth, styles: [], depth: .standard
			)
		}
		#expect(!SelectionCompositor.canReadDepth(colorDepth))
		#expect(SelectionCompositor.canReadDepth(floatMask))
	}

	@Test func depthComparisonFollowsTheProjection() {
		let standard = simd_float4x4(rows: [
			[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, -1.0002, -0.20002], [0, 0, -1, 0],
		])
		let reversed = simd_float4x4(rows: [
			[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 0, 0.1], [0, 0, -1, 0],
		])
		#expect(SelectionCompositor.DepthComparison(projection: standard) == .standard)
		#expect(SelectionCompositor.DepthComparison(projection: reversed) == .reversed)
		#expect(!SelectionCompositor.DepthComparison.distance().nearerIsLarger)
	}
}

#if !os(visionOS)
@MainActor
@Suite("RealityKit path through the compositor", .enabled(if: hasMetal, "Needs a Metal device"))
struct SelectionRendererCompositingTests {

	@Test func selectedBoxGetsARingAroundItsSilhouette() throws {
		let bench = try Bench()
		let renderer = SelectionRenderer()
		let box = ModelEntity(mesh: .generateBox(size: 1), materials: [])
		renderer.setSelected([(box, .outline(color: red, width: 2), .subtree)])
		// Not in a scene, so it keeps the transform taken at selection
		// (`updateTransforms()` skips inactive entities).
		// Camera 3 units in front of the box, looking down -Z, 90° field of view:
		// the front face (x ±0.5 at distance 2.5) spans pixels 12.8…19.2.
		renderer.setViewMatrix(simd_float4x4(rows: [
			[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, -3], [0, 0, 0, 1],
		]))
		let projection = simd_float4x4(rows: [
			[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, -1.0002, -0.20002], [0, 0, -1, 0],
		])
		let cb = try #require(bench.queue.makeCommandBuffer())
		renderer.encode(
			device: bench.device, commandBuffer: cb, source: bench.source,
			sourceDepth: nil, target: bench.target, projection: projection
		)
		let pixels = try bench.readTarget(after: cb)

		#expect(close(pixels[x: 16, y: 16], black))  // inside the silhouette
		#expect(close(pixels[x: 11, y: 16], red))    // within 2 px of it
		#expect(close(pixels[x: 20, y: 16], red))
		#expect(close(pixels[x: 16, y: 11], red))
		#expect(close(pixels[x: 9, y: 16], black))   // beyond the width
		#expect(close(pixels[x: 22, y: 16], black))
	}
}
#endif
