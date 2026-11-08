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

    var isTitleValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(album: Album) {
        self.album = album
        _title = State(initialValue: album.title)
        _artist = State(initialValue: album.artist)
        _artworkData = State(initialValue: album.artworkData)
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
                    .disabled(!isTitleValid)
                    .fontWeight(.bold)
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
            applyToTracks: applyToTracks
        )
    }
}
