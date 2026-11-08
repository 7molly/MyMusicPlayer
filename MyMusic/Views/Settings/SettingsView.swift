import SwiftUI

/// Экран «Настройки» с секцией «Оформление», информацией о хранилище, инструкции и аудиодвижке (iOS 16+)
struct SettingsView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @ObservedObject var playerVM = PlayerViewModel.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var diskUsageString: String = "Вычисление…"
    @State private var showClearConfirmation: Bool = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Секция «Оформление»
                Section("Оформление") {
                    // Блок 1: Тема приложения
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Тема")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Picker("Тема", selection: $themeManager.colorSchemeOption) {
                            ForEach(AppThemeMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.vertical, 4)

                    // Блок 2: Цвет акцента
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Цвет акцента")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button("Сбросить") {
                                withAnimation {
                                    themeManager.resetToDefaults()
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(themeManager.accentColor)
                        }

                        // Горизонтальный ряд круглых цветных кнопок
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(ThemePresetColor.allPresets) { preset in
                                    let isSelected = themeManager.isMatchingPreset(preset)
                                    Button(action: {
                                        withAnimation {
                                            themeManager.setAccentColor(preset.color)
                                        }
                                    }) {
                                        ZStack {
                                            Circle()
                                                .fill(preset.color)
                                                .frame(width: 36, height: 36)
                                                .shadow(color: preset.color.opacity(0.35), radius: 4, x: 0, y: 2)

                                            if isSelected {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 15, weight: .bold))
                                                    .foregroundStyle(themeManager.contrastTextColor(for: preset.color))
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }

                                // Кнопка «Свой цвет» с ColorPicker
                                ZStack {
                                    Circle()
                                        .fill(themeManager.isCustomColorSelected ? themeManager.accentColor : Color(uiColor: .tertiarySystemFill))
                                        .frame(width: 36, height: 36)
                                        .shadow(color: themeManager.isCustomColorSelected ? themeManager.accentColor.opacity(0.35) : .clear, radius: 4, x: 0, y: 2)

                                    if themeManager.isCustomColorSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(themeManager.contrastForegroundColor)
                                    } else {
                                        Image(systemName: "paintpalette.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.primary)
                                    }

                                    // Прозрачный ColorPicker поверх кнопки
                                    ColorPicker("", selection: Binding(
                                        get: { themeManager.accentColor },
                                        set: { newColor in
                                            themeManager.setAccentColor(newColor)
                                        }
                                    ))
                                    .labelsHidden()
                                    .opacity(0.02)
                                    .frame(width: 36, height: 36)
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Секция хранилища
                Section("Хранилище и медиатека") {
                    HStack {
                        Label("Всего треков", systemImage: "music.note")
                        Spacer()
                        Text("\(libraryStore.tracks.count)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Всего альбомов", systemImage: "square.stack")
                        Spacer()
                        Text("\(libraryStore.albums.count)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Занято на диске", systemImage: "internaldrive")
                        Spacer()
                        Text(diskUsageString)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive, action: {
                        showClearConfirmation = true
                    }) {
                        Label("Очистить медиатеку", systemImage: "trash")
                    }
                    .disabled(libraryStore.tracks.isEmpty)
                }

                // MARK: - Секция аудиодвижка
                Section("Аудиодвижок (AVAudioEngine)") {
                    HStack {
                        Label("Цепочка обработки", systemImage: "waveform.path")
                        Spacer()
                        Text("Player → EQ → Pitch → Mixer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Фоновое воспроизведение", systemImage: "speaker.wave.3")
                        Spacer()
                        Text("Включено")
                            .font(.caption)
                            .foregroundStyle(themeManager.accentColor)
                    }

                    HStack {
                        Label("Поддержка форматов", systemImage: "doc.badge.gearshape")
                        Spacer()
                        Text("MP3, WAV, M4A, FLAC")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: - Секция инструкции
                Section("Как добавить музыку") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Нажмите «+» в правом верхнем углу Медиатеки.")
                            .font(.subheadline)
                        Text("2. Выберите «Выбрать файлы…» для добавления одного или нескольких треков.")
                            .font(.subheadline)
                        Text("3. Выберите «Выбрать папку…», чтобы добавить всю папку — из неё будет автоматически создан целый альбом с треками.")
                            .font(.subheadline)
                        Text("4. Музыка копируется в песочницу приложения и остаётся доступной навсегда без подключения к интернету.")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                }

                // MARK: - О приложении
                Section("О приложении") {
                    HStack {
                        Text("Версия")
                        Spacer()
                        Text("1.0.0 (Apple Music Style)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Платформа")
                        Spacer()
                        Text("iOS 16+ • Swift 5.9+")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: playerVM.currentTrack != nil ? 144 : 76)
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                calculateDiskUsage()
            }
            .confirmationDialog(
                "Удалить всю музыку?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Очистить медиатеку", role: .destructive) {
                    clearAllData()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Все импортированные аудиофайлы и альбомы будут безвозвратно удалены из песочницы приложения.")
            }
        }
    }

    private func calculateDiskUsage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let musicDir = docs.appendingPathComponent("Library/Music", isDirectory: true)

            var totalBytes: Int64 = 0
            if let enumerator = FileManager.default.enumerator(at: musicDir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let fileURL as URL in enumerator {
                    if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        totalBytes += Int64(size)
                    }
                }
            }

            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB, .useKB]
            formatter.countStyle = .file
            let string = formatter.string(fromByteCount: totalBytes)

            DispatchQueue.main.async {
                self.diskUsageString = string
            }
        }
    }

    private func clearAllData() {
        playerVM.stop()
        playerVM.currentTrack = nil
        libraryStore.clearAll()
        calculateDiskUsage()
    }
}
