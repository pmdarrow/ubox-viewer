import AVFoundation
import SwiftUI

struct VideoView: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        view.layer = displayLayer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
