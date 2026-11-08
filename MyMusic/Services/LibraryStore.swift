import Foundation
import Combine
import UIKit

/// Модель пользовательского плейлиста (Codable, iOS 16+)
struct Playlist: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var title: String = ""
    var playlistDescription: String = ""
    var artworkData: Data? = nil
    var trackIDs: [UUID] = []
    var dateCreated: Date = Date()
    var isPinned: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, title, playlistDescription, artworkData, trackIDs, dateCreated, isPinned
    }

    init(id: UUID = UUID(),
         title: String,
         playlistDescription: String = "",
         artworkData: Data? = nil,
         trackIDs: [UUID] = [],
         dateCreated: Date = Date(),
         isPinned: Bool = false) {
        self.id = id
        self.title = title
        self.playlistDescription = playlistDescription
        self.artworkData = artworkData
        self.trackIDs = trackIDs
        self.dateCreated = dateCreated
        self.isPinned = isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.playlistDescription = try container.decodeIfPresent(String.self, forKey: .playlistDescription) ?? ""
        self.artworkData = try container.decodeIfPresent(Data.self, forKey: .artworkData)
        self.trackIDs = try container.decodeIfPresent([UUID].self, forKey: .trackIDs) ?? []
        self.dateCreated = try container.decodeIfPresent(Date.self, forKey: .dateCreated) ?? Date()
        self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(playlistDescription, forKey: .playlistDescription)
        try container.encodeIfPresent(artworkData, forKey: .artworkData)
        try container.encode(trackIDs, forKey: .trackIDs)
        try container.encode(dateCreated, forKey: .dateCreated)
        try container.encode(isPinned, forKey: .isPinned)
    }

    /// Получение актуальных объектов треков из медиатеки
    func resolvedTracks(in store: LibraryStore) -> [Track] {
        trackIDs.compactMap { id in store.tracks.first(where: { $0.id == id }) }
    }

    /// Обложка плейлиста (собственная или из первого трека)
    func resolvedArtwork(in store: LibraryStore) -> Data? {
        if let artworkData = artworkData { return artworkData }
        if let firstID = trackIDs.first, let track = store.tracks.first(where: { $0.id == firstID }) {
            return track.artworkData
        }
        return nil
    }

    /// Общая длительность всех треков плейлиста в секундах
    func totalDuration(in store: LibraryStore) -> TimeInterval {
        resolvedTracks(in: store).reduce(0.0) { $0 + $1.duration }
    }
}

/// Хранилище медиатеки с сохранением в JSON в Application Support (полная поддержка iOS 16+)
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published var tracks: [Track] = []
    @Published var albums: [Album] = []
    @Published var playlists: [Playlist] = []

    private let fileManager = FileManager.default

    private var libraryFolderURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("MyMusic", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var libraryFileURL: URL {
        libraryFolderURL.appendingPathComponent("library.json")
    }

    private struct StorageData: Codable {
        var albums: [Album]
        var tracks: [Track]
        var playlists: [Playlist]?
    }

    init() {
        load()
    }

    // MARK: - Загрузка и сохранение данных
    func load() {
        let fileURL = libraryFileURL
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(StorageData.self, from: data)
            self.albums = decoded.albums
            self.tracks = decoded.tracks
            self.playlists = decoded.playlists ?? []
            upgradeExistingArtworksTo2000IfNeeded()
            DispatchQueue.main.async {
                PlayerViewModel.shared.restorePlaybackState(in: self)
            }
        } catch {
            print("Ошибка загрузки library.json: \(error.localizedDescription)")
        }
    }

    /// Фоновое обновление ранее сохранённых обложек с низким разрешением до 2000×2000 px
    private func upgradeExistingArtworksTo2000IfNeeded() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            var changed = false
            for i in self.tracks.indices {
                if let data = self.tracks[i].artworkData,
                   let img = UIImage(data: data),
                   img.size.width < 1800 || img.size.height < 1800 {
                    if let upgraded = ArtworkProcessor.processTo2000x2000(image: img) {
                        await MainActor.run {
                            if i < self.tracks.count {
                                self.tracks[i].artworkData = upgraded
                            }
                        }
                        changed = true
                    }
                }
            }
            for i in self.albums.indices {
                if let data = self.albums[i].artworkData,
                   let img = UIImage(data: data),
                   img.size.width < 1800 || img.size.height < 1800 {
                    if let upgraded = ArtworkProcessor.processTo2000x2000(image: img) {
                        await MainActor.run {
                            if i < self.albums.count {
                                self.albums[i].artworkData = upgraded
                            }
                        }
                        changed = true
                    }
                }
            }
            if changed {
                await MainActor.run {
                    self.save()
                }
            }
        }
    }

    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "com.timuraliev.mymusic.librarysave", qos: .utility)

    func save() {
        saveWorkItem?.cancel()
        let fileURL = libraryFileURL
        let storage = StorageData(albums: albums, tracks: tracks, playlists: playlists)

        let item = DispatchWorkItem {
            do {
                let encoded = try JSONEncoder().encode(storage)
                try encoded.write(to: fileURL, options: [.atomicWrite])
            } catch {
                print("Ошибка фонового сохранения library.json: \(error.localizedDescription)")
            }
        }
        saveWorkItem = item
        saveQueue.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    /// Принудительное сохранение при закрытии приложения
    func saveImmediate() {
        saveWorkItem?.cancel()
        let fileURL = libraryFileURL
        let storage = StorageData(albums: albums, tracks: tracks, playlists: playlists)
        saveQueue.sync {
            do {
                let encoded = try JSONEncoder().encode(storage)
                try encoded.write(to: fileURL, options: [.atomicWrite])
            } catch {
                print("Ошибка немедленного сохранения library.json: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Добавление треков и альбомов
    func addTracks(_ newTracks: [Track], forAlbum albumTitle: String, artist: String, artwork: Data?) {
        var targetAlbum: Album

        if let index = albums.firstIndex(where: { $0.title.caseInsensitiveCompare(albumTitle) == .orderedSame }) {
            targetAlbum = albums[index]
            for track in newTracks {
                if !targetAlbum.tracks.contains(where: { $0.id == track.id }) {
                    targetAlbum.tracks.append(track)
                }
            }
            if targetAlbum.artworkData == nil && artwork != nil {
                targetAlbum.artworkData = artwork
            }
            albums[index] = targetAlbum
        } else {
            targetAlbum = Album(
                title: albumTitle,
                artist: artist,
                artworkData: artwork,
                tracks: newTracks
            )
            albums.append(targetAlbum)
        }

        // Добавляем в общий список всех треков
        for track in newTracks {
            if let existingIndex = tracks.firstIndex(where: { $0.id == track.id }) {
                tracks[existingIndex] = track
            } else {
                tracks.append(track)
            }
        }

        save()
    }

    // MARK: - Обновление метаданных трека
    func updateTrack(_ updatedTrack: Track) {
        var trackToSave = updatedTrack

        // Валидация входных значений
        let trimmedTitle = trackToSave.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            trackToSave.title = "Без названия"
        } else {
            trackToSave.title = trimmedTitle
        }

        let trimmedArtist = trackToSave.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        trackToSave.artist = trimmedArtist.isEmpty ? "Неизвестный исполнитель" : trimmedArtist

        let trimmedAlbum = trackToSave.albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        trackToSave.albumName = trimmedAlbum.isEmpty ? "Неизвестный альбом" : trimmedAlbum

        // 1. Обновляем в глобальном списке треков
        if let idx = tracks.firstIndex(where: { $0.id == trackToSave.id }) {
            tracks[idx] = trackToSave
        }

        // 2. Удаляем трек из всех предыдущих альбомов
        for i in 0..<albums.count {
            albums[i].tracks.removeAll { $0.id == trackToSave.id }
        }

        // 3. Помещаем трек в целевой альбом (или создаём новый)
        if let targetIdx = albums.firstIndex(where: { $0.title.caseInsensitiveCompare(trackToSave.albumName) == .orderedSame }) {
            albums[targetIdx].tracks.append(trackToSave)
            if albums[targetIdx].artworkData == nil && trackToSave.artworkData != nil {
                albums[targetIdx].artworkData = trackToSave.artworkData
            }
        } else {
            let newAlbum = Album(
                title: trackToSave.albumName,
                artist: trackToSave.artist,
                artworkData: trackToSave.artworkData,
                tracks: [trackToSave]
            )
            albums.append(newAlbum)
        }

        // 4. Очищаем альбомы, оставшиеся без треков
        albums.removeAll { $0.tracks.isEmpty }

        save()

        // 5. Мгновенно синхронизируем с плеером
        DispatchQueue.main.async {
            PlayerViewModel.shared.updateTrackMetadata(trackToSave)
        }
    }

    // MARK: - Обновление метаданных альбома
    func updateAlbum(albumID: UUID, newTitle: String, newArtist: String, newArtwork: Data?, applyToTracks: Bool) {
        guard let albumIdx = albums.firstIndex(where: { $0.id == albumID }) else { return }

        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmedTitle.isEmpty ? "Неизвестный альбом" : trimmedTitle

        let trimmedArtist = newArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalArtist = trimmedArtist.isEmpty ? "Неизвестный исполнитель" : trimmedArtist

        albums[albumIdx].title = finalTitle
        albums[albumIdx].artist = finalArtist
        if let artwork = newArtwork {
            albums[albumIdx].artworkData = artwork
        }

        if applyToTracks {
            for trackIdx in 0..<albums[albumIdx].tracks.count {
                albums[albumIdx].tracks[trackIdx].albumName = finalTitle
                albums[albumIdx].tracks[trackIdx].artist = finalArtist
                if let artwork = newArtwork {
                    albums[albumIdx].tracks[trackIdx].artworkData = artwork
                }

                let trackID = albums[albumIdx].tracks[trackIdx].id
                if let globalIdx = tracks.firstIndex(where: { $0.id == trackID }) {
                    tracks[globalIdx] = albums[albumIdx].tracks[trackIdx]
                    DispatchQueue.main.async {
                        PlayerViewModel.shared.updateTrackMetadata(self.tracks[globalIdx])
                    }
                }
            }
        }

        save()
    }

    // MARK: - Сброс метаданных трека к исходным данным из файла
    func revertTrackToOriginal(_ track: Track) async -> Track {
        let (origTitle, origArtist, origAlbum, origNum, origArtwork) = await track.readOriginalTagsFromFile()

        var reverted = track
        reverted.title = origTitle ?? track.originalTitle ?? track.title
        reverted.artist = origArtist ?? track.originalArtist ?? track.artist
        reverted.albumName = origAlbum ?? track.originalAlbumName ?? track.albumName
        reverted.trackNumber = origNum ?? track.originalTrackNumber ?? track.trackNumber
        reverted.artworkData = origArtwork ?? track.originalArtworkData

        updateTrack(reverted)
        return reverted
    }

    // MARK: - Удаление данных
    func deleteTrack(_ track: Track) {
        // Удаляем физический аудиофайл из Documents/Library/Music
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = docs.appendingPathComponent(track.relativeFilePath)
        try? fileManager.removeItem(at: fileURL)

        // Удаляем из общего списка
        tracks.removeAll { $0.id == track.id }

        // Удаляем из альбомов
        for i in 0..<albums.count {
            albums[i].tracks.removeAll { $0.id == track.id }
        }

        // Удаляем из плейлистов
        for i in 0..<playlists.count {
            playlists[i].trackIDs.removeAll { $0 == track.id }
        }

        // Удаляем опустевшие альбомы
        albums.removeAll { $0.tracks.isEmpty }

        save()

        DispatchQueue.main.async {
            PlayerViewModel.shared.removeQueueTrack(withID: track.id)
        }
    }

    func deleteAlbum(_ album: Album) {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Удаляем аудиофайлы всех треков альбома
        for track in album.tracks {
            let fileURL = docs.appendingPathComponent(track.relativeFilePath)
            try? fileManager.removeItem(at: fileURL)
            tracks.removeAll { $0.id == track.id }
            DispatchQueue.main.async {
                PlayerViewModel.shared.removeQueueTrack(withID: track.id)
            }
        }

        albums.removeAll { $0.id == album.id }
        save()
    }

    func clearAll() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let musicDir = docs.appendingPathComponent("Library/Music", isDirectory: true)
        try? fileManager.removeItem(at: musicDir)

        tracks.removeAll()
        albums.removeAll()
        playlists.removeAll()
        save()
    }

    // MARK: - Управление плейлистами
    @discardableResult
    func createPlaylist(title: String, description: String = "", initialTrackIDs: [UUID] = [], artworkData: Data? = nil) -> Playlist {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = name.isEmpty ? "Новый плейлист" : name
        let playlist = Playlist(
            id: UUID(),
            title: finalTitle,
            playlistDescription: description,
            artworkData: artworkData,
            trackIDs: initialTrackIDs,
            dateCreated: Date()
        )
        playlists.insert(playlist, at: 0)
        save()
        return playlist
    }

    func updatePlaylist(_ playlist: Playlist) {
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index] = playlist
            save()
        }
    }

    func deletePlaylist(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        save()
    }

    func addTrack(_ track: Track, to playlist: Playlist) {
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            if !playlists[index].trackIDs.contains(track.id) {
                playlists[index].trackIDs.append(track.id)
                save()
            }
        }
    }

    func removeTrack(id trackID: UUID, from playlist: Playlist) {
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index].trackIDs.removeAll { $0 == trackID }
            save()
        }
    }

    func moveTracks(in playlist: Playlist, from source: IndexSet, to destination: Int) {
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index].trackIDs.move(fromOffsets: source, toOffset: destination)
            save()
        }
    }

    // MARK: - Поиск альбома для трека
    func album(for track: Track) -> Album? {
        if let albumID = track.albumID, let album = albums.first(where: { $0.id == albumID }) {
            return album
        }
        if !track.albumName.isEmpty {
            return albums.first(where: { $0.title.caseInsensitiveCompare(track.albumName) == .orderedSame })
        }
        return nil
    }

    // MARK: - Закрепление плейлистов
    func togglePin(playlist: Playlist) {
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index].isPinned.toggle()
            save()
        }
    }

    func setPin(playlist: Playlist, isPinned: Bool) {
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index].isPinned = isPinned
            save()
        }
    }

    // MARK: - Плейлист «Нравится» (Избранное)
    func getOrCreateFavoritesPlaylist() -> Playlist {
        if let existing = playlists.first(where: {
            let t = $0.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return t == "нравится" || t == "нравиться" || t == "любимые" || t == "избранное"
        }) {
            return existing
        }
        return createPlaylist(title: "Нравится", description: "Любимые треки")
    }

    func isTrackFavorite(_ track: Track) -> Bool {
        guard let fav = playlists.first(where: {
            let t = $0.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return t == "нравится" || t == "нравиться" || t == "любимые" || t == "избранное"
        }) else { return false }
        return fav.trackIDs.contains(track.id)
    }

    @discardableResult
    func toggleFavorite(for track: Track) -> Bool {
        let playlist = getOrCreateFavoritesPlaylist()
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            if playlists[index].trackIDs.contains(track.id) {
                playlists[index].trackIDs.removeAll { $0 == track.id }
                save()
                return false
            } else {
                playlists[index].trackIDs.append(track.id)
                save()
                return true
            }
        }
        return false
    }
}
