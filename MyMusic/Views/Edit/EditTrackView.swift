import SwiftUI
import PhotosUI

/// Экран редактирования сведений о треке в стиле Apple Music (iOS 16+)
struct EditTrackView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var libraryStore: LibraryStore

    let track: Track

    @State private var title: String = ""
    @State private var artist: String = ""
    @State private var albumName: String = ""
    @State private var trackNumber: Int = 1
    @State private var artworkData: Data? = nil

    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var showResetAlert: Bool = false
    @State private var showAlbumSuggestions: Bool = false

    /// Список названий существующих альбомов для подсказки
    var existingAlbumTitles: [String] {
        let titles = libraryStore.albums.map { $0.title }
        let unique = Set(titles)
        return unique.sorted()
    }

    /// Фильтрованные подсказки по вводу
    var matchingAlbumTitles: [String] {
        if albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existingAlbumTitles
        }
        return existingAlbumTitles.filter {
            $0.localizedCaseInsensitiveContains(albumName) && $0 != albumName
        }
    }

    var isTitleValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(track: Track) {
        self.track = track
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
        _albumName = State(initialValue: track.albumName)
        _trackNumber = State(initialValue: track.trackNumber)
        _artworkData = State(initialValue: track.artworkData)
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Обложка
                Section {
                    HStack(spacing: 16) {
                        if let data = artworkData, let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
                        } else {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(uiColor: .tertiarySystemFill))
                                .frame(width: 80, height: 80)
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.secondary)
                                )
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker(
                                selection: $selectedPhotoItem,
                                matching: .images,
                                photoLibrary: .shared()
                            ) {
                                HStack {
                                    Image(systemName: "photo.badge.plus")
                                    Text("Выбрать обложку")
                                }
                                .font(.subheadline)
                                .fontWeight(.medium)
                            }
                            .onChange(of: selectedPhotoItem) { newItem in
                                Task {
                                    if let data = try? await newItem?.loadTransferable(type: Data.self) {
                                        let processed = ArtworkProcessor.processTo2000x2000(data: data) ?? data
                                        await MainActor.run {
                                            self.artworkData = processed
                                        }
                                    }
                                }
                            }

                            if artworkData != nil {
                                Button(role: .destructive, action: {
                                    artworkData = nil
                                    selectedPhotoItem = nil
                                }) {
                                    HStack {
                                        Image(systemName: "trash")
                                        Text("Удалить обложку")
                                    }
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Обложка")
                }

                // MARK: - Основные сведения
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Название трека")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Название трека", text: $title)
                            .font(.body)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Исполнитель")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Исполнитель", text: $artist)
                            .font(.body)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Альбом")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Альбом", text: $albumName)
                            .font(.body)
                    }

                    // Подсказки существующих альбомов
                    if !matchingAlbumTitles.isEmpty {
                        DisclosureGroup("Существующие альбомы (\(matchingAlbumTitles.count))") {
                            ForEach(matchingAlbumTitles, id: \.self) { existingTitle in
                                Button(action: {
                                    albumName = existingTitle
                                }) {
                                    HStack {
                                        Image(systemName: "square.stack")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(existingTitle)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    Stepper(value: $trackNumber, in: 1...999) {
                        HStack {
                            Text("Номер трека")
                            Spacer()
                            Text("\(trackNumber)")
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Сведения о песне")
                } footer: {
                    if !isTitleValid {
                        Text("Название трека не может быть пустым.")
                            .foregroundStyle(.red)
                    }
                }

                // MARK: - Сброс к исходным данным
                Section {
                    Button(action: { showResetAlert = true }) {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Вернуть исходные данные")
                        }
                        .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Восстанавливает название, исполнителя и альбом из исходных тегов аудиофайла на диске.")
                }
            }
            .navigationTitle("Сведения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        saveChanges()
                        dismiss()
                    }
                    .disabled(!isTitleValid)
                    .fontWeight(.bold)
                }
            }
            .alert("Сбросить данные?", isPresented: $showResetAlert) {
                Button("Сбросить", role: .destructive) {
                    resetToOriginal()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Все изменённые поля трека будут заменены исходными тегами из файла.")
            }
        }
    }

    private func saveChanges() {
        var updated = track
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.artist = cleanArtist.isEmpty ? "Неизвестный исполнитель" : cleanArtist
        let cleanAlbum = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.albumName = cleanAlbum.isEmpty ? "Неизвестный альбом" : cleanAlbum
        updated.trackNumber = trackNumber
        updated.artworkData = artworkData

        libraryStore.updateTrack(updated)
    }

    private func resetToOriginal() {
        Task {
            let (origTitle, origArtist, origAlbum, origNum, origArtwork) = await track.readOriginalTagsFromFile()
            await MainActor.run {
                self.title = origTitle ?? track.originalTitle ?? track.title
                self.artist = origArtist ?? track.originalArtist ?? track.artist
                self.albumName = origAlbum ?? track.originalAlbumName ?? track.albumName
                self.trackNumber = origNum ?? track.originalTrackNumber ?? track.trackNumber
                self.artworkData = origArtwork ?? track.originalArtworkData
                self.selectedPhotoItem = nil
            }
        }
    }
}
