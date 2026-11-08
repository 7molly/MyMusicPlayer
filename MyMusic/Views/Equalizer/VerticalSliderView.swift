import SwiftUI

/// Вертикальный слайдер полосы эквалайзера в стиле Apple
struct VerticalSliderView: View {
    let bandIndex: Int
    let frequencyLabel: String
    let gain: Float
    let isEnabled: Bool
    let onGainChanged: (Float) -> Void

    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var dragGain: Float? = nil

    private var currentGain: Float {
        dragGain ?? gain
    }

    var body: some View {
        VStack(spacing: 6) {
            // Метка текущего значения дБ вверху
            Text(formattedGain(currentGain))
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(currentGain != 0 ? themeManager.accentColor : .secondary)
                .frame(height: 14)

            // Сам вертикальный слайдер
            GeometryReader { geometry in
                let height = geometry.size.height
                let width = geometry.size.width
                let normalized = CGFloat((currentGain + 12.0) / 24.0)
                let fillHeight = height * max(0.0, min(1.0, normalized))

                ZStack(alignment: .bottom) {
                    // Фоновая дорожка
                    Capsule()
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .frame(width: 8)

                    // Центральная отметка 0 дБ
                    Rectangle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 14, height: 1.5)
                        .position(x: width / 2, y: height / 2)

                    // Заполненная часть слайдера
                    Capsule()
                        .fill(isEnabled ? (currentGain != 0 ? themeManager.accentColor : Color.primary.opacity(0.4)) : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: fillHeight)

                    // Ползунок (Thumb)
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
                        .frame(width: 22, height: 22)
                        .position(x: width / 2, y: height - fillHeight)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { gesture in
                            guard isEnabled else { return }
                            let yPosition = height - gesture.location.y
                            let percent = max(0.0, min(1.0, yPosition / height))
                            let calculated = Float((percent * 24.0) - 12.0)
                            let roundedGain = (calculated * 2.0).rounded() / 2.0
                            let clampedGain = max(-12.0, min(12.0, roundedGain))
                            dragGain = clampedGain
                            onGainChanged(clampedGain)
                        }
                        .onEnded { _ in
                            if let finalGain = dragGain {
                                onGainChanged(finalGain)
                            }
                            dragGain = nil
                        }
                )
            }
            .frame(width: 28, height: 160)

            // Частотная метка внизу
            Text(frequencyLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func formattedGain(_ val: Float) -> String {
        if val > 0 {
            return String(format: "+%.1f", val)
        } else if val < 0 {
            return String(format: "%.1f", val)
        } else {
            return "0"
        }
    }
}
