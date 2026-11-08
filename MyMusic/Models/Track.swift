import Foundation
import AVFoundation

/// Модель трека (Codable, совместима с iOS 16+)
struct Track: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var title: String = ""
    var artist: String = ""
    var albumName: String = ""
    var albumID: UUID? = nil
    /// Относительный путь к файлу внутри Documents (например: "Library/Music/uuid_song.mp3")
    var relativeFilePath: String = ""
    /// Закладка безопасности (bookmarkData) для гарантированного доступа к внешним файлам
    var bookmarkData: Data? = nil
    var duration: TimeInterval = 0.0
    var trackNumber: Int = 1
    var artworkData: Data? = nil
    var dateAdded: Date = Date()
    /// Относительное имя файла анимированной обложки в Documents/Covers (например: "uuid.mp4")
    var animatedCoverFileName: String? = nil

    // Исходные метаданные файла (для кнопки «Вернуть исходные данные»)
    var originalTitle: String? = nil
    var originalArtist: String? = nil
    var originalAlbumName: String? = nil
    var originalTrackNumber: Int? = nil
    var originalArtworkData: Data? = nil

    init(id: UUID = UUID(),
         title: String,
         artist: String = "Неизвестный исполнитель",
         albumName: String = "Неизвестный альбом",
         albumID: UUID? = nil,
         relativeFilePath: String,
         bookmarkData: Data? = nil,
         duration: TimeInterval = 0.0,
         trackNumber: Int = 1,
         artworkData: Data? = nil,
         dateAdded: Date = Date(),
         animatedCoverFileName: String? = nil,
         originalTitle: String? = nil,
         originalArtist: String? = nil,
         originalAlbumName: String? = nil,
         originalTrackNumber: Int? = nil,
         originalArtworkData: Data? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumName = albumName
        self.albumID = albumID
        self.relativeFilePath = relativeFilePath
        self.bookmarkData = bookmarkData
        self.duration = duration
        self.trackNumber = trackNumber
        self.artworkData = artworkData
        self.dateAdded = dateAdded
        self.animatedCoverFileName = animatedCoverFileName
        self.originalTitle = originalTitle ?? title
        self.originalArtist = originalArtist ?? artist
        self.originalAlbumName = originalAlbumName ?? albumName
        self.originalTrackNumber = originalTrackNumber ?? trackNumber
        self.originalArtworkData = originalArtworkData ?? artworkData
    }

    /// Разрешение абсолютного URL анимированной обложки (с фолбэком на обложку альбома)
    func resolvedAnimatedCoverURL(in libraryStore: LibraryStore? = nil) -> URL? {
        if let fileName = animatedCoverFileName, !fileName.isEmpty {
            let url = AnimatedCoverManager.shared.coversDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let store = libraryStore ?? LibraryStore.shared
        if let album = store.album(for: self), let albumCover = album.animatedCoverFileName, !albumCover.isEmpty {
            let url = AnimatedCoverManager.shared.coversDirectory.appendingPathComponent(albumCover)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Обложка трека с фолбэком на обложку альбома
    func resolvedArtworkData(in libraryStore: LibraryStore? = nil) -> Data? {
        if let data = artworkData, !data.isEmpty {
            return data
        }
        if let orig = originalArtworkData, !orig.isEmpty {
            return orig
        }
        let store = libraryStore ?? LibraryStore.shared
        return store.album(for: self)?.resolvedArtworkData
    }

    /// Разрешение абсолютного URL файла в песочнице приложения
    func resolvedFileURL() -> URL? {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let candidate = documentsURL.appendingPathComponent(relativeFilePath)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        // Если файл перемещён, пробуем восстановить из закладки bookmarkData
        if let bookmarkData = bookmarkData {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmarkData,
                                       options: .withoutUI,
                                       relativeTo: nil,
                                       bookmarkDataIsStale: &isStale),
               FileManager.default.fileExists(atPath: resolved.path) {
                return resolved
            }
        }
        return nil
    }

    /// Извлечение исходных тегов непосредственно из аудиофайла
    func readOriginalTagsFromFile() async -> (title: String?, artist: String?, albumName: String?, trackNumber: Int?, artwork: Data?) {
        guard let url = resolvedFileURL() else {
            return (originalTitle, originalArtist, originalAlbumName, originalTrackNumber, originalArtworkData)
        }

        let asset = AVURLAsset(url: url)
        var fileTitle: String?
        var fileArtist: String?
        var fileAlbum: String?
        var fileArtwork: Data?

        if let commonMetadata = try? await asset.load(.commonMetadata) {
            for item in commonMetadata {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    fileTitle = try? await item.load(.stringValue)
                case .commonKeyArtist:
                    fileArtist = try? await item.load(.stringValue)
                case .commonKeyAlbumName:
                    fileAlbum = try? await item.load(.stringValue)
                case .commonKeyArtwork:
                    fileArtwork = try? await item.load(.dataValue)
                default:
                    break
                }
            }
        }

        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let finalTitle = fileTitle ?? originalTitle ?? fallbackTitle
        let finalArtist = fileArtist ?? originalArtist ?? "Неизвестный исполнитель"
        let finalAlbum = fileAlbum ?? originalAlbumName ?? "Неизвестный альбом"
        let finalArtwork = fileArtwork ?? originalArtworkData

        return (finalTitle, finalArtist, finalAlbum, originalTrackNumber ?? 1, finalArtwork)
    }

    /// Форматированная длительность трека вида "3:45" или "1:02:15"
    var formattedDuration: String {
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
