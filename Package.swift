// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "SelectionEffects",
	platforms: [
		// ARView: iOS 15 / macOS 12. RealityView needs iOS / macOS 26.
		.iOS(.v15),
		.macOS(.v12),
		// RealityKit's ARView / ModelComponent APIs exist on tvOS from 26.
		.tvOS("26.0"),
	],
	products: [
		.library(
			name: "SelectionEffects",
			targets: ["SelectionEffects"]
		)
	],
	targets: [
		.target(
			name: "SelectionEffects",
			resources: [
				// Compiled into default.metallib inside the package resource bundle,
				// loaded at runtime via `Bundle.module`.
				.process("OutlineShaders.metal")
			]
		),
		.testTarget(
			name: "SelectionEffectsTests",
			dependencies: ["SelectionEffects"]
		),
	]
)
