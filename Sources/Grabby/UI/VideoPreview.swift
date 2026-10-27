import AVFoundation
import SwiftUI

/// Hosts the pipeline's sample-buffer layer, which frames are enqueued into
/// straight from the USB thread without going through SwiftUI.
struct VideoPreview: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> LayerHostView {
        LayerHostView(hosted: layer)
    }

    func updateNSView(_ view: LayerHostView, context: Context) {}

    final class LayerHostView: NSView {
        private let hosted: CALayer

        init(hosted: CALayer) {
            self.hosted = hosted
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = .black
            layer?.addSublayer(hosted)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted.frame = bounds
            CATransaction.commit()
        }
    }
}
