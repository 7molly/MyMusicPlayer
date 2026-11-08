import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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
    @State private var animatedCoverFileName: String? = nil

    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var selectedVideoItem: PhotosPickerItem? = nil
    @State private var showFileImporter: Bool = false
    @State private var isProcessingVideo: Bool = false
    @State private var videoProcessProgress: Double = 0.0
    @State private var videoProcessError: String? = nil
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
        _animatedCoverFileName = State(initialValue: track.animatedCoverFileName)
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
                    Text("Статичная обложка")
                }

                // MARK: - Анимированная обложка
                Section {
                    if isProcessingVideo {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                ProgressView()
                                    .controlSize(.regular)
                                Text("Конвертация видео (720×720, H.264)…")
                                    .font(.subheadline)
                            }
                            ProgressView(value: videoProcessProgress)
                                .progressViewStyle(.linear)
                        }
                        .padding(.vertical, 8)
                    } else {
                        HStack(spacing: 16) {
                            if let fileName = animatedCoverFileName,
                               let url = AnimatedCoverManager.shared.coversDirectory.appendingPathComponent(fileName) as URL?,
                               FileManager.default.fileExists(atPath: url.path) {
                                MiniAnimatedCoverPreviewView(url: url, cornerRadius: 10, size: 80)
                                    .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
                            } else {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(uiColor: .tertiarySystemFill))
                                    .frame(width: 80, height: 80)
                                    .overlay(
                                        Image(systemName: "video.badge.plus")
                                            .font(.system(size: 26))
                                            .foregroundStyle(.secondary)
                                    )
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                PhotosPicker(
                                    selection: $selectedVideoItem,
                                    matching: .videos,
                                    photoLibrary: .shared()
                                ) {
                                    HStack {
                                        Image(systemName: "film")
                                        Text("Выбрать из Фото…")
                                    }
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                }
                                .onChange(of: selectedVideoItem) { newItem in
                                    guard let item = newItem else { return }
                                    processVideoFromPhotos(item: item)
                                }

                                Button {
                                    showFileImporter = true
                                } label: {
                                    HStack {
                                        Image(systemName: "folder")
                                        Text("Выбрать файл (MP4, MOV, GIF)…")
                                    }
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                }

                                if animatedCoverFileName != nil {
                                    Button(role: .destructive, action: {
                                        animatedCoverFileName = nil
                                        selectedVideoItem = nil
                                    }) {
                                        HStack {
                                            Image(systemName: "trash")
                                            Text("Удалить анимацию")
                                        }
                                        .font(.subheadline)
                                        .foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if let error = videoProcessError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Анимированная обложка (Apple Music)")
                } footer: {
                    Text("Поддерживаются форматы MP4, MOV и GIF. Видео будет автоматически кадрировано в квадрат 720×720 и обрезано до 15 секунд без звука.")
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
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie, .gif, UTType(filenameExtension: "gif") ?? .gif],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    processVideoURL(url: url)
                case .failure(let error):
                    videoProcessError = "Ошибка выбора файла: \(error.localizedDescription)"
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
        let oldFileName = track.animatedCoverFileName

        var updated = track
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.artist = cleanArtist.isEmpty ? "Неизвестный исполнитель" : cleanArtist
        let cleanAlbum = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.albumName = cleanAlbum.isEmpty ? "Неизвестный альбом" : cleanAlbum
        updated.trackNumber = trackNumber
        updated.artworkData = artworkData
        updated.animatedCoverFileName = animatedCoverFileName

        libraryStore.updateTrack(updated)

        // Удаляем старый файл обложки, если он был заменён или удалён
        if let old = oldFileName, old != animatedCoverFileName {
            AnimatedCoverManager.shared.deleteCoverFileIfUnused(fileName: old, in: libraryStore)
        }
    }

    private func processVideoFromPhotos(item: PhotosPickerItem) {
        isProcessingVideo = true
        videoProcessProgress = 0.0
        videoProcessError = nil

        Task {
            do {
                guard let movie = try await item.loadTransferable(type: MovieTransferable.self) else {
                    await MainActor.run {
                        self.isProcessingVideo = false
                        self.videoProcessError = "Не удалось загрузить видео из Фото"
                    }
                    return
                }

                let result = try await AnimatedCoverManager.shared.processAndSaveVideo(
                    sourceURL: movie.url
                ) { p in
                    Task { @MainActor in
                        self.videoProcessProgress = p
                    }
                }

                await MainActor.run {
                    self.animatedCoverFileName = result.fileName
                    if self.artworkData == nil {
                        self.artworkData = result.previewImageData
                    }
                    self.isProcessingVideo = false
                }
            } catch {
                await MainActor.run {
                    self.videoProcessError = "Ошибка обработки: \(error.localizedDescription)"
                    self.isProcessingVideo = false
                }
            }
        }
    }

    private func processVideoURL(url: URL) {
        isProcessingVideo = true
        videoProcessProgress = 0.0
        videoProcessError = nil

        Task {
            do {
                let result = try await AnimatedCoverManager.shared.processAndSaveVideo(
                    sourceURL: url
                ) { p in
                    Task { @MainActor in
                        self.videoProcessProgress = p
                    }
                }

                await MainActor.run {
                    self.animatedCoverFileName = result.fileName
                    if self.artworkData == nil {
                        self.artworkData = result.previewImageData
                    }
                    self.isProcessingVideo = false
                }
            } catch {
                await MainActor.run {
                    self.videoProcessError = "Ошибка обработки: \(error.localizedDescription)"
                    self.isProcessingVideo = false
                }
            }
        }
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
