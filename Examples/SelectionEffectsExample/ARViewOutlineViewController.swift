//
//  ARViewOutlineViewController.swift
//  SelectionEffectsExample
//
//  Created by Cristian Díaz on 29.03.26.
//
//  ARView path (iOS 15+ / macOS 12+). This file is self-contained: copy it into a
//  UIKit (or AppKit) app that depends on the SelectionEffects package, and add a
//  `gramophone.usdz` (or change the model name below).
//

import SelectionEffects
import RealityKit

#if os(iOS)
import UIKit

/// Shows a model in a non-AR `ARView` and outlines whatever the user taps.
@available(iOS 15.0, *)
final class ARViewOutlineViewController: UIViewController {
	private var arView: ARView!
	private var selection = OutlineDemoSelection(color: .systemYellow)

	override func loadView() {
		// `.nonAR` renders a virtual scene through our own camera; no ARSession is needed.
		arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
		arView.environment.background = .color(.secondarySystemBackground)
		view = arView
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		// 1. Draw SelectionEffectComponent effects in this view.
		arView.installSelectionEffects()

		// 2. Build the scene (camera, light, models) and preload the outline geometry.
		OutlineDemoScene.build(in: arView)

		// 3. Tap to select; tapping empty space clears the selection.
		let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
		arView.addGestureRecognizer(tap)
	}

	@objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
		let location = recognizer.location(in: arView)
		// `entity(at:)` hit-tests collision shapes, so the model needs `generateCollisionShapes`.
		selection.select(OutlineDemoScene.selectableRoot(of: arView.entity(at: location)))
	}
}

#elseif os(macOS)
import AppKit

/// AppKit twin of the UIKit controller above. Scene setup is shared via `OutlineDemoScene`.
@available(macOS 12.0, *)
final class ARViewOutlineViewController: NSViewController {
	private var arView: ARView!
	private var selection = OutlineDemoSelection(color: .systemYellow)

	override func loadView() {
		// On macOS ARView always renders a virtual (non-AR) scene.
		arView = ARView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
		arView.environment.background = .color(.windowBackgroundColor)
		view = arView
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		arView.installSelectionEffects()
		OutlineDemoScene.build(in: arView)

		let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
		arView.addGestureRecognizer(click)
	}

	@objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
		let location = recognizer.location(in: arView)
		selection.select(OutlineDemoScene.selectableRoot(of: arView.entity(at: location)))
	}
}
#endif

// MARK: - Selection

/// Selecting adds a `SelectionEffectComponent`; deselecting removes it.
@available(iOS 15.0, macOS 12.0, *)
@MainActor
struct OutlineDemoSelection {
	let style: SelectionEffectComponent.OutlineSelectionEffectStyle
	private(set) var selected: Entity?

	init(color: SelectionEffectComponent.Color) {
		style = .init(color: color, width: 3)
	}

	/// Selects `entity`, or clears the selection when it's `nil`.
	mutating func select(_ entity: Entity?) {
		selected?.components.remove(SelectionEffectComponent.self)
		selected = entity
		selected?.components.set(SelectionEffectComponent(.outline(style)))
	}
}

// MARK: - Shared scene setup

/// Builds the demo scene. `generateCollisionShapes` is there for
/// `ARView.entity(at:)`, which picks by collision shape.
@available(iOS 15.0, macOS 12.0, *)
@MainActor
enum OutlineDemoScene {
	/// Name given to entities that should be selected as a whole.
	static let selectableName = "selectable"

	/// Adds a camera, a light, the gramophone and an orbiting box, and preloads
	/// their outline geometry so the first tap doesn't hitch.
	static func build(in arView: ARView) {
		DemoMotionSystem.register()
		let anchor = AnchorEntity(world: .zero)

		let camera = PerspectiveCamera()
		camera.position = [0, 0.5, 1.5]
		anchor.addChild(camera)

		let light = DirectionalLight()
		light.look(at: .zero, from: [1, 2, 2], relativeTo: nil)
		anchor.addChild(light)

		let box = ModelEntity(
			mesh: .generateBox(size: 0.15, cornerRadius: 0.02),
			materials: [SimpleMaterial(color: .systemBlue, isMetallic: false)]
		)
		box.name = selectableName
		box.generateCollisionShapes(recursive: false)
		box.components.set(DemoMotionComponent(spin: 1, spinAxis: [1, 1, 0], orbitRadius: 0.6, orbitSpeed: 0.8, orbitHeight: 0.35))
		anchor.addChild(box)
		SelectionEffectComponent.preloadGeometry(of: [box])

		arView.scene.addAnchor(anchor)

		func addModel(_ model: Entity) {
			model.name = selectableName
			model.generateCollisionShapes(recursive: true)
			model.components.set(DemoMotionComponent(spin: 0.3))
			anchor.addChild(model)
			SelectionEffectComponent.preloadGeometry(of: [model])
		}

		if #available(iOS 18.0, macOS 15.0, *) {
			// Load asynchronously so the view appears immediately.
			Task { @MainActor in
				do {
					addModel(try await Entity(named: "gramophone"))
				} catch {
					print("Failed to load gramophone: \(error)")
				}
			}
		} else {
			do {
				addModel(try Entity.load(named: "gramophone"))
			} catch {
				print("Failed to load gramophone: \(error)")
			}
		}
	}

	/// Taps hit individual collision parts; walk up to the whole model.
	/// Returns `nil` for empty space, which clears the selection.
	static func selectableRoot(of entity: Entity?) -> Entity? {
		var current = entity
		while let candidate = current {
			if candidate.name == selectableName { return candidate }
			current = candidate.parent
		}
		return entity
	}
}
