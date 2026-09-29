import AVKit
import SwiftUI

/// The system AirPlay and audio-output picker.
struct RoutePickerButton: UIViewRepresentable {
    var prioritizesVideoDevices = false

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = prioritizesVideoDevices
        view.tintColor = UIColor(named: "AccentColor")
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.prioritizesVideoDevices = prioritizesVideoDevices
    }
}
