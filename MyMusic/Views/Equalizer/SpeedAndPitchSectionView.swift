import SwiftUI

/// Секция управления скоростью и тональностью в аутентичном стиле Apple Music (iOS 16+)
struct SpeedAndPitchSectionView: View {
    @ObservedObject var eqVM = EqualizerViewModel.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    private var isModified: Bool {
        abs(eqVM.playbackRate - 1.0) > 0.005 || abs(eqVM.pitchShift) > 0.05
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Верхняя плашка с заголовком и кнопкой сброса
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.2.square")
                        .font(.title3)
                        .foregroundStyle(themeManager.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Тональность и скорость")
                            .font(.headline)
                            .fontWeight(.bold)

                        Text("Регулировка высоты тона и темпа без потери качества")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isModified {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            eqVM.resetSpeedAndPitch()
                        }
                    } label: {
                        Text("Сбросить")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(themeManager.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(themeManager.accentColor.opacity(0.15))
                            )
                    }
                }
            }

            // Блок 1: Тональность (Pitch / Key)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Тональность")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Text(pitchStatusString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(pitchValueString)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(abs(eqVM.pitchShift) > 0.05 ? themeManager.accentColor : .primary)
                }

                // Слайдер тональности: -12 ... +12 полутонов
                Slider(
                    value: Binding(
                        get: { Double(eqVM.pitchShift) },
                        set: { eqVM.setPitch(Float($0)) }
                    ),
                    in: -12.0...12.0,
                    step: 1.0
                )
                .tint(themeManager.accentColor)

                // Быстрые кнопки полутонов
                HStack(spacing: 6) {
                    pitchChip(semitones: -3, label: "-3")
                    pitchChip(semitones: -2, label: "-2")
                    pitchChip(semitones: -1, label: "-1")
                    pitchChip(semitones: 0, label: "0")
                    pitchChip(semitones: 1, label: "+1")
                    pitchChip(semitones: 2, label: "+2")
                    pitchChip(semitones: 3, label: "+3")
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
            )

            // Блок 2: Скорость (Speed / Tempo)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Скорость")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Text(speedStatusString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("\(eqVM.speedPercent)%")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(abs(eqVM.playbackRate - 1.0) > 0.01 ? themeManager.accentColor : .primary)
                }

                // Слайдер скорости: 50% ... 150% (0.50x ... 1.50x)
                Slider(
                    value: Binding(
                        get: { Double(eqVM.playbackRate) },
                        set: { eqVM.setRate(Float($0)) }
                    ),
                    in: 0.5...1.5,
                    step: 0.01
                )
                .tint(themeManager.accentColor)

                // Быстрые кнопки скорости в %
                HStack(spacing: 6) {
                    speedChip(percent: 75, label: "75%")
                    speedChip(percent: 80, label: "80%")
                    speedChip(percent: 85, label: "85%")
                    speedChip(percent: 100, label: "100%")
                    speedChip(percent: 115, label: "115%")
                    speedChip(percent: 125, label: "125%")
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
            )

            // Блок 3: Готовые стили звучания
            VStack(alignment: .leading, spacing: 8) {
                Text("Популярные стили:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        comboChip(title: "Оригинал", icon: "arrow.counterclockwise", rate: 1.0, pitch: 0.0)
                        comboChip(title: "Slowed", icon: "tortoise.fill", rate: 0.85, pitch: -2.0)
                        comboChip(title: "Nightcore", icon: "hare.fill", rate: 1.25, pitch: 3.0)
                        comboChip(title: "Daycore", icon: "moon.fill", rate: 0.80, pitch: -3.0)
                        comboChip(title: "Deep Voice", icon: "waveform", rate: 1.00, pitch: -3.0)
                        comboChip(title: "Sped Up", icon: "forward.fill", rate: 1.20, pitch: 1.0)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    // MARK: - Быстрые плашки

    private func pitchChip(semitones: Int, label: String) -> some View {
        let isSelected = abs(eqVM.pitchShift - Float(semitones)) < 0.2
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.15)) {
                eqVM.setPitch(Float(semitones))
            }
        } label: {
            Text(label)
                .font(.caption2)
                .fontWeight(isSelected ? .bold : .medium)
                .foregroundStyle(isSelected ? themeManager.contrastForegroundColor : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? themeManager.accentColor : Color(uiColor: .quaternarySystemFill))
                )
        }
    }

    private func speedChip(percent: Int, label: String) -> some View {
        let isSelected = abs(eqVM.speedPercent - percent) <= 1
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.15)) {
                eqVM.setRate(Float(percent) / 100.0)
            }
        } label: {
            Text(label)
                .font(.caption2)
                .fontWeight(isSelected ? .bold : .medium)
                .foregroundStyle(isSelected ? themeManager.contrastForegroundColor : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? themeManager.accentColor : Color(uiColor: .quaternarySystemFill))
                )
        }
    }

    private func comboChip(title: String, icon: String, rate: Float, pitch: Float) -> some View {
        let isSelected = abs(eqVM.playbackRate - rate) < 0.02 && abs(eqVM.pitchShift - pitch) < 0.2
        return Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.easeInOut(duration: 0.15)) {
                eqVM.applyCombo(rate: rate, pitch: pitch)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(title)
                    .font(.caption)
                    .fontWeight(isSelected ? .bold : .medium)
            }
            .foregroundStyle(isSelected ? themeManager.contrastForegroundColor : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? themeManager.accentColor : Color(uiColor: .tertiarySystemFill))
            )
        }
    }

    // MARK: - Строки описания

    private var pitchValueString: String {
        let semitones = Int(round(eqVM.pitchShift))
        if semitones == 0 {
            return "0 полутонов"
        } else if semitones > 0 {
            return "+\(semitones) \(semitonesDeclension(semitones))"
        } else {
            return "\(semitones) \(semitonesDeclension(abs(semitones)))"
        }
    }

    private var pitchStatusString: String {
        let semitones = Int(round(eqVM.pitchShift))
        if semitones == 0 {
            return "Оригинальная высота тона"
        } else if semitones < 0 {
            return "Понижено на \(abs(semitones)) \(semitonesDeclension(abs(semitones)))"
        } else {
            return "Повышено на \(semitones) \(semitonesDeclension(semitones))"
        }
    }

    private var speedStatusString: String {
        let p = eqVM.speedPercent
        if p == 100 {
            return "Обычная скорость"
        } else if p < 100 {
            return "Замедленно (\(p - 100)%)"
        } else {
            return "Ускорено (+\(p - 100)%)"
        }
    }

    private func semitonesDeclension(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod100 >= 11 && mod100 <= 19 {
            return "полутонов"
        }
        if mod10 == 1 {
            return "полутон"
        }
        if mod10 >= 2 && mod10 <= 4 {
            return "полутона"
        }
        return "полутонов"
    }
}
