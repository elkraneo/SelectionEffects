// Reproduces a crash when a RealityView's customPostProcessing is set before
// the view has rendered. Uses Apple frameworks only.
//
//   swift run PostProcessTimingRepro make      # set in the make closure → traps
//   swift run PostProcessTimingRepro update    # set in update: → traps intermittently
//   swift run PostProcessTimingRepro deferred  # set on the first SceneEvents.Update → works
//
// Prints "OK" and exits 0 when the app survives 3 seconds.

import AppKit
import Metal
import RealityKit
import SwiftUI

/// The simplest possible effect: copy the frame through unchanged.
struct PassThrough: PostProcessEffect {
    func postProcess(context: borrowing PostProcessEffectContext<any MTLCommandBuffer>) {
        guard let blit = context.commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: context.sourceColorTexture, to: context.targetColorTexture)
        blit.endEncoding()
    }
}

let mode = CommandLine.arguments.dropFirst().first ?? "make"

struct ReproView: View {
    @State private var subscription: EventSubscription?

    var body: some View {
        RealityView { content in
            let camera = Entity()
            camera.components.set(PerspectiveCameraComponent())
            camera.position = [0, 0, 2]
            content.add(camera)
            content.add(ModelEntity(mesh: .generateBox(size: 0.5), materials: [SimpleMaterial()]))

            switch mode {
            case "make":
                content.renderingEffects.customPostProcessing = .effect(PassThrough())
            case "deferred":
                var later = content
                var attached = false
                subscription = content.subscribe(to: SceneEvents.Update.self) { _ in
                    guard !attached else { return }
                    attached = true
                    later.renderingEffects.customPostProcessing = .effect(PassThrough())
                }
            default:
                break
            }
        } update: { content in
            if mode == "update" {
                content.renderingEffects.customPostProcessing = .effect(PassThrough())
            }
        }
        .frame(width: 640, height: 480)
        .task {
            try? await Task.sleep(for: .seconds(3))
            print("OK")
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
    styleMask: [.titled], backing: .buffered, defer: false
)
window.contentView = NSHostingView(rootView: ReproView())
window.center()
window.makeKeyAndOrderFront(nil)
app.activate()
app.run()
