import SwiftUI
import UIKit
import ReplayKit

/// The system broadcast picker, stretched over our own card with its icon hidden, so a tap on the
/// card is a real tap on Apple's button (the only way to start a broadcast from inside an app).
final class FillingBroadcastPicker: RPSystemBroadcastPickerView {
    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundColor = .clear
        for case let button as UIButton in subviews {
            button.frame = bounds
            button.tintColor = .clear
            button.imageView?.alpha = 0
        }
    }
}

struct BroadcastPickerOverlay: UIViewRepresentable {
    let extensionID: String?

    func makeUIView(context: Context) -> FillingBroadcastPicker {
        let picker = FillingBroadcastPicker(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        picker.preferredExtension = extensionID
        picker.showsMicrophoneButton = false
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: FillingBroadcastPicker, context: Context) {
        uiView.preferredExtension = extensionID
        uiView.setNeedsLayout()
    }
}
