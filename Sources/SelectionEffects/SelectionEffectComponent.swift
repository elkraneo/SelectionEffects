//
//  SelectionEffectComponent.swift
//  SelectionEffects
//
//  Created by Cristian Díaz on 13.10.26.
//

import CoreGraphics
import RealityKit
import SwiftUI

// MARK: - Component

/// Marks an entity as selected and says how the selection is drawn.
///
/// Add it to select an entity, remove it to deselect. The effect is drawn by the
/// view's selection effects, installed once with `installSelectionEffects()` on
/// a `RealityView`'s content or on an `ARView`.
///
/// ```swift
/// entity.components.set(SelectionEffectComponent(.outline(.init(color: .yellow, width: 3))))
/// entity.components.remove(SelectionEffectComponent.self)
/// ```
///
/// Modeled on RealityKit's `HoverEffectComponent`: the component describes the
/// effect, and the system draws it while the component is present.
@available(iOS 15.0, macOS 12.0, tvOS 26.0, *)
@available(visionOS, unavailable)
public struct SelectionEffectComponent: Component, Equatable {

	/// How a selected entity is drawn.
	public struct SelectionEffect: Equatable, Sendable {
		enum Kind: Equatable, Sendable {
			case outline(OutlineStyle)
		}

		let kind: Kind

		/// A pixel-exact outline around the entity's silhouette, drawn as a
		/// post-process. It's X-ray style: it stays visible behind other geometry.
		public static func outline(_ style: OutlineStyle = OutlineStyle()) -> SelectionEffect {
			SelectionEffect(kind: .outline(style))
		}
	}

	public var effect: SelectionEffect

	public init(_ effect: SelectionEffect = .outline()) {
		self.effect = effect
	}
}

// MARK: - Mesh selection

/// Which meshes in a selected entity's hierarchy an effect is drawn for.
@available(iOS 15.0, macOS 12.0, tvOS 26.0, *)
@available(visionOS, unavailable)
public enum MeshSelection: Sendable, Equatable {
	/// The entity's own mesh and every mesh below it. The default.
	case subtree
	/// The entity's own mesh if it has one; otherwise the nearest meshes below it.
	/// Avoids outlining a whole imported hierarchy when a grouping entity also
	/// carries a mesh.
	case nearestMeshes
	/// Meshes below the entity, falling back to its own mesh only when it has no
	/// descendant meshes. For USD stages where a parent prim carries an aggregate
	/// mesh that doesn't match the displayed child meshes.
	case preferDescendants
}

// MARK: - Outline style

/// The look of an outline selection effect.
@available(iOS 15.0, macOS 12.0, tvOS 26.0, *)
@available(visionOS, unavailable)
public struct OutlineStyle: Equatable, Sendable {
	/// Outline color as sRGB-encoded RGBA in 0…1. Alpha controls the blend over the frame.
	public var color: SIMD4<Float>

	/// Outline thickness in pixels, clamped to `0...OutlineStyle.maxWidth`.
	public var width: Int

	/// Largest supported width, in pixels.
	public static let maxWidth = SelectionRenderer.maxWidth

	/// Which meshes in the entity's hierarchy are outlined.
	public var meshes: MeshSelection

	/// - Parameters:
	///   - color: sRGB-encoded RGBA in 0…1 (the values a color picker shows).
	///   - width: Thickness in pixels.
	///   - meshes: Which meshes in the entity's hierarchy are outlined.
	public init(
		color: SIMD4<Float> = [1, 1, 0, 1],
		width: Int = 3,
		meshes: MeshSelection = .subtree
	) {
		self.color = color
		self.width = width
		self.meshes = meshes
	}

	/// Creates a style from a `CGColor`, converted to sRGB.
	public init(
		color: CGColor,
		width: Int = 3,
		meshes: MeshSelection = .subtree
	) {
		self.init(color: SelectionRenderer.rgba(from: color), width: width, meshes: meshes)
	}

	/// Creates a style from a SwiftUI `Color`, resolved in the default environment.
	@available(iOS 17.0, macOS 14.0, tvOS 26.0, *)
	public init(
		color: Color,
		width: Int = 3,
		meshes: MeshSelection = .subtree
	) {
		let r = color.resolve(in: EnvironmentValues())
		self.init(
			color: SIMD4(Float(r.red), Float(r.green), Float(r.blue), Float(r.opacity)),
			width: width,
			meshes: meshes
		)
	}
}

// MARK: - Preloading

@available(iOS 15.0, macOS 12.0, tvOS 26.0, *)
@available(visionOS, unavailable)
extension SelectionEffectComponent {
	/// Reads and caches the outline geometry of `entities` now, so selecting them
	/// later doesn't hitch. The first read of a large mesh can take ~100 ms;
	/// selection is ~1 ms after that.
	@MainActor
	public static func preloadGeometry(
		of entities: [Entity],
		meshes: MeshSelection = .subtree
	) {
		for entity in entities {
			_ = OutlineMeshExtraction.collect(from: entity, mode: meshes, cache: .shared)
		}
	}
}
