import Foundation

/// Модель альбома (Codable, совместима с iOS 16+)
struct Album: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var title: String = ""
    var artist: String = ""
    var artworkData: Data? = nil
    var dateAdded: Date = Date()
    var tracks: [Track] = []
    /// Относительное имя файла анимированной обложки в Documents/Covers (например: "uuid.mp4")
    var animatedCoverFileName: String? = nil

    init(id: UUID = UUID(),
         title: String,
         artist: String = "Неизвестный исполнитель",
         artworkData: Data? = nil,
         dateAdded: Date = Date(),
         tracks: [Track] = [],
         animatedCoverFileName: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkData = artworkData
        self.dateAdded = dateAdded
        self.tracks = tracks
        self.animatedCoverFileName = animatedCoverFileName
    }

    /// Разрешение абсолютного URL анимированной обложки альбома
    var resolvedAnimatedCoverURL: URL? {
        if let fileName = animatedCoverFileName, !fileName.isEmpty {
            let url = AnimatedCoverManager.shared.coversDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Обложка альбома: собственная или первая доступная из треков
    var resolvedArtworkData: Data? {
        if let data = artworkData, !data.isEmpty {
            return data
        }
        return tracks.first(where: { $0.artworkData != nil && !$0.artworkData!.isEmpty })?.artworkData
    }

    /// Общая длительность всех треков альбома
    var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }

    /// Форматированная длительность: "42 мин." или "1 ч. 15 мин."
    var formattedDuration: String {
        let total = Int(totalDuration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours) ч. \(minutes) мин."
        } else {
            return "\(max(1, minutes)) мин."
        }
    }

    /// Склонение слова "трек" в зависимости от количества
    var formattedTrackCount: String {
        let count = tracks.count
        let lastDigit = count % 10
        let lastTwoDigits = count % 100

        if lastTwoDigits >= 11 && lastTwoDigits <= 14 {
            return "\(count) треков"
        }
        switch lastDigit {
        case 1:
            return "\(count) трек"
        case 2, 3, 4:
            return "\(count) трека"
        default:
            return "\(count) треков"
        }
    }
}
