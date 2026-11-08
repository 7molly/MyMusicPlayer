import SwiftUI
import AVKit

/// Кнопка выбора маршрута вывода звука (AirPlay / Bluetooth / Наушники)
struct AirPlayButtonView: UIViewRepresentable {
    var tintColor: UIColor = UIColor.white.withAlphaComponent(0.50)
    var activeTintColor: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let routePicker = AVRoutePickerView()
        routePicker.tintColor = tintColor
        routePicker.activeTintColor = activeTintColor
        routePicker.prioritizesVideoDevices = false
        routePicker.backgroundColor = .clear
        return routePicker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = activeTintColor
    }
}
