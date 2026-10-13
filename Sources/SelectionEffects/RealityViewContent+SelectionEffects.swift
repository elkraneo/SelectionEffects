//
//  RealityViewContent+SelectionEffects.swift
//  SelectionEffects
//
//  Created by Cristian Díaz on 13.10.26.
//

#if os(visionOS)
import RealityKit
import SwiftUI

@available(visionOS 1.0, *)
extension RealityViewContent {
	/// Drives `SelectionEffectComponent` effects in this `RealityView`.
	///
	/// On visionOS only `.shader` effects are available: RealityKit has no
	/// post-processing there, which the outline and highlight need.
	@MainActor
	public mutating func installSelectionEffects() {
		SelectionEffectSystem.registerOnce()
	}
}
#endif
