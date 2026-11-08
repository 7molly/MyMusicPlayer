import SwiftUI

/// Главный экран «Эквалайзер» с 10 вертикальными полосами, пресетами и настройкой строя
struct EqualizerView: View {
    @ObservedObject var eqVM = EqualizerViewModel.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var showSavePresetDialog: Bool = false
    @State private var newPresetName: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Карточка главного переключателя и пресетов
                    VStack(spacing: 16) {
                        HStack {
                            Toggle("Эквалайзер", isOn: $eqVM.isEQEnabled)
                                .font(.headline)
                                .tint(themeManager.accentColor)

                            Spacer()

                            Button("Сбросить") {
                                eqVM.resetEQ()
                            }
                            .font(.subheadline)
                            .foregroundStyle(themeManager.accentColor)
                            .disabled(!eqVM.isEQEnabled)
                        }

                        Divider()

                        // Выбор пресета
                        HStack {
                            Text("Пресет")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Menu {
                                Section("Встроенные") {
                                    ForEach(EQPreset.builtInPresets) { preset in
                                        Button(action: { eqVM.selectPreset(preset) }) {
                                            HStack {
                                                Text(preset.name)
                                                if eqVM.selectedPresetName == preset.name {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }

                                if !eqVM.customPresets.isEmpty {
                                    Section("Пользовательские") {
                                        ForEach(eqVM.customPresets) { preset in
                                            Button(action: { eqVM.selectPreset(preset) }) {
                                                HStack {
                                                    Text(preset.name)
                                                    if eqVM.selectedPresetName == preset.name {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                Divider()

                                Button(action: {
                                    newPresetName = ""
                                    showSavePresetDialog = true
                                }) {
                                    Label("Сохранить текущий как пресет…", systemImage: "plus.app")
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(eqVM.selectedPresetName)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(themeManager.accentColor)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(Color(uiColor: .tertiarySystemFill))
                                )
                            }
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )

                    // 10 вертикальных слайдеров
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("10-полосный эквалайзер")
                                .font(.headline)
                                .fontWeight(.bold)
                            Spacer()
                            Text("±12 дБ")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(0..<10, id: \.self) { index in
                                    VerticalSliderView(
                                        bandIndex: index,
                                        frequencyLabel: EQPreset.frequencyLabels[index],
                                        gain: eqVM.gains[index],
                                        isEnabled: eqVM.isEQEnabled,
                                        onGainChanged: { newGain in
                                            eqVM.setGain(bandIndex: index, gain: newGain)
                                        }
                                    )
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )
                    .opacity(eqVM.isEQEnabled ? 1.0 : 0.6)

                    // Секция скорости и тональности (Slowed, Sped Up & Pitch Shift)
                    SpeedAndPitchSectionView()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: PlayerViewModel.shared.currentTrack != nil ? 144 : 76)
            }
            .navigationTitle("Эквалайзер")
            .navigationBarTitleDisplayMode(.large)
            .background(Color(uiColor: .systemGroupedBackground))
            .alert("Сохранить пресет", isPresented: $showSavePresetDialog) {
                TextField("Название пресета", text: $newPresetName)
                Button("Сохранить") {
                    eqVM.saveCustomPreset(name: newPresetName)
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Введите имя для текущей конфигурации 10 полос.")
            }
        }
    }
}
