//
//  SelectionEffectComponent.swift
//  SelectionEffects
//
//  Created by Cristian Díaz on 13.10.26.
//

import Foundation
import RealityKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Component

/// Marks an entity as selected and describes how the selection is drawn.
///
/// Add the component to select an entity; remove it to deselect. The view draws
/// the effects once `installSelectionEffects()` has been called on a
/// `RealityView`'s content or an `ARView`.
///
/// ```swift
/// entity.components.set(SelectionEffectComponent())     // outline in the accent color
/// entity.components.set(SelectionEffectComponent(.highlight(.init(color: .systemOrange))))
/// entity.components.remove(SelectionEffectComponent.self)
/// ```
///
/// Its shape follows RealityKit's `HoverEffectComponent`: the component holds an
/// effect, built from a style, and the effect is drawn while the component is present.
@available(iOS 15.0, macOS 12.0, tvOS 26.0, visionOS 1.0, *)
public struct SelectionEffectComponent: Component, Equatable {

	/// How a selected entity is drawn.
	public struct SelectionEffect: Equatable {
		enum Kind: Equatable {
			#if !os(visionOS)
			case outline(OutlineSelectionEffectStyle)
			case highlight(HighlightSelectionEffectStyle)
			#endif
			case shader(ShaderSelectionEffectInputs)
		}

		let kind: Kind

		#if !os(visionOS)
		/// A pixel-exact outline around the entity's silhouette.
		public static func outline(_ style: OutlineSelectionEffectStyle) -> SelectionEffect {
			SelectionEffect(kind: .outline(style))
		}

		/// A translucent color fill over the entity's silhouette.
		public static func highlight(_ style: HighlightSelectionEffectStyle) -> SelectionEffect {
			SelectionEffect(kind: .highlight(style))
		}
		#endif

		/// Your own look: while the entity is selected, a float parameter of its
		/// `ShaderGraphMaterial`s fades from 0 to 1, and back to 0 when it's
		/// deselected. Build the look in Reality Composer Pro's Shader Graph from
		/// that parameter (`inputs.parameterName`).
		///
		/// Unlike the outline and highlight, this effect changes the entity's
		/// materials. It needs no post-processing, so it also works on visionOS.
		@available(iOS 18.0, macOS 15.0, tvOS 26.0, visionOS 1.0, *)
		public static func shader(_ inputs: ShaderSelectionEffectInputs) -> SelectionEffect {
			SelectionEffect(kind: .shader(inputs))
		}
	}

	/// The effect drawn for this entity.
	public var selectionEffect: SelectionEffect

	/// Which meshes in this entity's hierarchy the effect is drawn for.
	public var meshSelection: MeshSelection

	#if !os(visionOS)
	/// Selects the entity with the default outline.
	public init() {
		self.init(.outline(.default))
	}
	#else
	/// Selects the entity with the default shader effect.
	public init() {
		self.init(.shader(.default))
	}
	#endif

	/// Selects the entity with `selectionEffect`.
	public init(_ selectionEffect: SelectionEffect, meshSelection: MeshSelection = .subtree) {
		self.selectionEffect = selectionEffect
		self.meshSelection = meshSelection
	}
}

// MARK: - Styles

#if canImport(UIKit)
@available(iOS 15.0, tvOS 26.0, *)
@available(visionOS, unavailable)
extension SelectionEffectComponent {
	/// The platform color type used by selection styles.
	public typealias Color = UIColor
}
#elseif canImport(AppKit)
@available(macOS 12.0, *)
extension SelectionEffectComponent {
	/// The platform color type used by selection styles.
	public typealias Color = NSColor
}
#endif

#if !os(visionOS)
@available(iOS 15.0, macOS 12.0, tvOS 26.0, *)
extension SelectionEffectComponent {

	/// The look of an outline selection effect.
	public struct OutlineSelectionEffectStyle: Equatable {
		/// The default outline: the system accent color, 3 pixels wide, fully
		/// visible behind other geometry.
		public static var `default`: OutlineSelectionEffectStyle { OutlineSelectionEffectStyle() }

		/// The outline color; `nil` uses the system accent color. Its alpha
		/// controls the blend over the frame.
		public var color: Color?

		/// Thickness in pixels, clamped to `0...OutlineSelectionEffectStyle.maxWidth`.
		public var width: Float

		/// Opacity of the parts of the outline hidden behind other geometry:
		/// `1` draws them like the rest (X-ray), `0` hides them. Reality Composer
		/// Pro draws hidden outline parts at about `0.3`.
		public var occludedOpacity: Float

		/// Largest supported width, in pixels.
		public static let maxWidth: Float = Float(SelectionRenderer.maxWidth)

		public init(color: Color? = nil, width: Float = 3, occludedOpacity: Float = 1) {
			self.color = color
			self.width = width
			self.occludedOpacity = occludedOpacity
		}
	}

	/// The look of a highlight selection effect.
	public struct HighlightSelectionEffectStyle: Equatable {
		/// The default highlight: the system accent color at 40% strength.
		public static var `default`: HighlightSelectionEffectStyle { HighlightSelectionEffectStyle() }

		/// The fill color; `nil` uses the system accent color.
		public var color: Color?

		/// How strongly the color covers the entity, from `0` to `1`. It
		/// multiplies the color's alpha.
		public var strength: Float

		/// Opacity of the parts hidden behind other geometry: `1` draws them like
		/// the rest, `0` hides them (the default).
		public var occludedOpacity: Float

		public init(color: Color? = nil, strength: Float = 0.4, occludedOpacity: Float = 0) {
			self.color = color
			self.strength = strength
			self.occludedOpacity = occludedOpacity
		}
	}
}
#endif

@available(iOS 15.0, macOS 12.0, tvOS 26.0, visionOS 1.0, *)
extension SelectionEffectComponent {

	/// The inputs of a shader selection effect.
	public struct ShaderSelectionEffectInputs: Equatable, Sendable {
		/// The default inputs: a 0.2-second fade in and out of the
		/// `SelectionIntensity` parameter.
		public static var `default`: ShaderSelectionEffectInputs { ShaderSelectionEffectInputs() }

		/// The time it takes in seconds for the effect to fade in.
		public var fadeInDuration: TimeInterval

		/// The time it takes in seconds for the effect to fade out.
		public var fadeOutDuration: TimeInterval

		/// The name of the float parameter, declared as an input of your Shader
		/// Graph material, that receives the selection intensity (0…1).
		public var parameterName: String

		public init(
			fadeInDuration: TimeInterval = 0.2,
			fadeOutDuration: TimeInterval = 0.2,
			parameterName: String = "SelectionIntensity"
		) {
			self.fadeInDuration = fadeInDuration
			self.fadeOutDuration = fadeOutDuration
			self.parameterName = parameterName
		}
	}

	/// Which meshes in a selected entity's hierarchy an effect is drawn for.
	public enum MeshSelection: Sendable, Equatable {
		/// The entity's own mesh and every mesh below it. The default.
		case subtree
		/// The entity's own mesh if it has one; otherwise the nearest meshes below
		/// it. Avoids drawing a whole imported hierarchy when a grouping entity
		/// also carries a mesh.
		case nearestMeshes
		/// Meshes below the entity, falling back to its own mesh only when it has
		/// no descendant meshes. For USD stages where a parent prim carries an
		/// aggregate mesh that doesn't match the displayed child meshes.
		case preferDescendants
	}
}

#if !os(visionOS)
// MARK: - Preloading

@available(iOS 15.0, macOS 12.0, tvOS 26.0, *)
@available(visionOS, unavailable)
extension SelectionEffectComponent {
	/// Reads and caches the geometry of `entities` now, so selecting them later
	/// doesn't hitch. The first read of a large mesh can take ~100 ms; selecting
	/// is ~1 ms after that.
	@MainActor
	public static func preloadGeometry(
		of entities: [Entity],
		meshSelection: MeshSelection = .subtree
	) {
		for entity in entities {
			_ = OutlineMeshExtraction.collect(from: entity, mode: meshSelection, cache: .shared)
		}
	}
}

// MARK: - Resolving for the renderer

@available(iOS 15.0, macOS 12.0, tvOS 26.0, *)
@available(visionOS, unavailable)
extension SelectionEffectComponent {
	/// The effect as the post-process renderer draws it, with colors resolved to
	/// sRGB; `nil` for effects it doesn't draw.
	@MainActor
	var renderStyle: RenderStyle? {
		switch selectionEffect.kind {
		case .shader:
			return nil
		case .outline(let style):
			return RenderStyle(
				kind: .outline,
				color: Self.srgb(style.color),
				width: Int(style.width.rounded()),
				strength: 1,
				occludedOpacity: style.occludedOpacity
			)
		case .highlight(let style):
			return RenderStyle(
				kind: .highlight,
				color: Self.srgb(style.color),
				width: 0,
				strength: style.strength,
				occludedOpacity: style.occludedOpacity
			)
		}
	}

	@MainActor
	private static func srgb(_ color: Color?) -> SIMD4<Float> {
		#if canImport(UIKit)
		let resolved = color ?? .tintColor
		#else
		let resolved = color ?? .controlAccentColor
		#endif
		return SelectionRenderer.rgba(from: resolved.cgColor)
	}
}
#endif
