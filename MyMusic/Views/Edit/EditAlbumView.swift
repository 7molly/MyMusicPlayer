import SwiftUI
import PhotosUI

/// Экран редактирования сведений об альбоме в стиле Apple Music (iOS 16+)
struct EditAlbumView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var libraryStore: LibraryStore

    let album: Album

    @State private var title: String = ""
    @State private var artist: String = ""
    @State private var artworkData: Data? = nil
    @State private var applyToTracks: Bool = true
    @State private var selectedPhotoItem: PhotosPickerItem? = nil

    // Анимированная обложка
    @State private var animatedCoverFileName: String? = nil
    @State private var applyAnimatedCoverToTracks: Bool = true
    @State private var selectedVideoItem: PhotosPickerItem? = nil
    @State private var showFileImporter: Bool = false
    @State private var isProcessingVideo: Bool = false
    @State private var videoProcessProgress: Double = 0.0
    @State private var videoProcessError: String? = nil

    var isTitleValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(album: Album) {
        self.album = album
        _title = State(initialValue: album.title)
        _artist = State(initialValue: album.artist)
        _artworkData = State(initialValue: album.artworkData)
        _animatedCoverFileName = State(initialValue: album.animatedCoverFileName)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Обложка альбома
                Section {
                    HStack(spacing: 16) {
                        if let data = artworkData, let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
                        } else {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(uiColor: .tertiarySystemFill))
                                .frame(width: 80, height: 80)
                                .overlay(
                                    Image(systemName: "square.stack")
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
                    Text("Обложка альбома")
                }

                // MARK: - Анимированная обложка альбома
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
                                            Text("Удалить видеообложку")
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

                    Toggle("Применить видеообложку ко всем трекам", isOn: $applyAnimatedCoverToTracks)
                } header: {
                    Text("Анимированная обложка альбома (Apple Music)")
                } footer: {
                    Text("Поддерживаются форматы MP4, MOV и GIF. Видео будет автоматически кадрировано в квадрат 720×720 и обрезано до 15 секунд без звука.")
                }

                // Название и исполнитель альбома
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Название альбома")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Название альбома", text: $title)
                            .font(.body)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Исполнитель альбома")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Исполнитель альбома", text: $artist)
                            .font(.body)
                    }
                } header: {
                    Text("Сведения об альбоме")
                } footer: {
                    if !isTitleValid {
                        Text("Название альбома не может быть пустым.")
                            .foregroundStyle(.red)
                    }
                }

                // Опция применения ко всем трекам
                Section {
                    Toggle("Применить ко всем трекам альбома", isOn: $applyToTracks)
                } footer: {
                    Text("Обновит тег альбома, имя исполнителя и обложку у всех \(album.tracks.count) треков этого альбома.")
                }
            }
            .navigationTitle("Изменить альбом")
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
                    .disabled(!isTitleValid || isProcessingVideo)
                    .fontWeight(.bold)
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie, .gif],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    processVideoFromFile(url: url)
                case .failure(let error):
                    self.videoProcessError = "Ошибка выбора файла: \(error.localizedDescription)"
                }
            }
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
                        self.videoProcessError = "Не удалось загрузить видео из Фото."
                    }
                    return
                }

                let result = try await AnimatedCoverManager.shared.processAndSaveVideo(sourceURL: movie.url) { progress in
                    Task { @MainActor in
                        self.videoProcessProgress = progress
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
                    self.isProcessingVideo = false
                    self.videoProcessError = "Ошибка обработки видео: \(error.localizedDescription)"
                }
            }
        }
    }

    private func processVideoFromFile(url: URL) {
        isProcessingVideo = true
        videoProcessProgress = 0.0
        videoProcessError = nil

        Task {
            let canAccess = url.startAccessingSecurityScopedResource()
            defer {
                if canAccess { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let result = try await AnimatedCoverManager.shared.processAndSaveVideo(sourceURL: url) { progress in
                    Task { @MainActor in
                        self.videoProcessProgress = progress
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
                    self.isProcessingVideo = false
                    self.videoProcessError = "Ошибка обработки видео: \(error.localizedDescription)"
                }
            }
        }
    }

    private func saveChanges() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)

        libraryStore.updateAlbum(
            albumID: album.id,
            newTitle: cleanTitle.isEmpty ? "Неизвестный альбом" : cleanTitle,
            newArtist: cleanArtist.isEmpty ? "Неизвестный исполнитель" : cleanArtist,
            newArtwork: artworkData,
            applyToTracks: applyToTracks,
            newAnimatedCoverFileName: animatedCoverFileName,
            applyAnimatedCoverToTracks: applyAnimatedCoverToTracks
        )
    }
}
