import Foundation
import AVFoundation
import UIKit
import Combine
import UniformTypeIdentifiers
import SwiftUI

// MARK: - Режим импорта документов
enum ImportPickerMode {
    case files
    case folder
}

// MARK: - Нативный координатор DocumentPicker (iOS 16+)
@MainActor
final class DocumentPickerPresenter: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPickerPresenter()

    private var onPicked: (([URL]) -> Void)?
    private var onCancelled: (() -> Void)?

    func present(
        mode: ImportPickerMode,
        onPicked: @escaping ([URL]) -> Void,
        onCancelled: (() -> Void)? = nil
    ) {
        self.onPicked = onPicked
        self.onCancelled = onCancelled

        let contentTypes: [UTType]
        let allowsMultiple: Bool

        switch mode {
        case .files:
            // UTType.audio охватывает все аудиоформаты: mp3, wav, m4a, flac, aac, aiff
            contentTypes = [.audio, .mp3, .wav, .mpeg4Audio]
            allowsMultiple = true
        case .folder:
            contentTypes = [.folder]
            allowsMultiple = false
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = allowsMultiple
        picker.shouldShowFileExtensions = true

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first,
              var topController = window.rootViewController else {
            print("Не удалось найти контроллер для показа UIDocumentPickerViewController")
            return
        }

        while let presented = topController.presentedViewController, !presented.isBeingDismissed {
            topController = presented
        }

        topController.present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate
    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Task { @MainActor in
            let callback = self.onPicked
            self.cleanup()
            callback?(urls)
        }
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Task { @MainActor in
            let callback = self.onCancelled
            self.cleanup()
            callback?()
        }
    }

    private func cleanup() {
        onPicked = nil
        onCancelled = nil
    }
}

/// Сервис импорта аудиофайлов и папок в медиатеку приложения (iOS 16+)
@MainActor
final class ImportService: ObservableObject {
    static let shared = ImportService()

    @Published var isImporting: Bool = false
    @Published var importProgress: Double = 0.0
    @Published var statusText: String = ""
    @Published var errorMessage: String? = nil

    private let supportedExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "aif", "aiff", "alac", "caf"]

    private init() {}

    // MARK: - Импорт списка отдельных файлов (пачками по 20 треков)
    func importFiles(urls: [URL], libraryStore: LibraryStore = .shared) async {
        guard !urls.isEmpty else { return }

        isImporting = true
        importProgress = 0.0
        statusText = "Подготовка файлов..."
        errorMessage = nil

        var currentBatch: [(track: Track, albumTitle: String, albumArtist: String, artwork: Data?)] = []
        var totalImportedCount = 0
        let total = Double(urls.count)

        for (index, url) in urls.enumerated() {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            statusText = "Импорт: \(url.lastPathComponent) (\(index + 1) из \(urls.count))..."
            importProgress = Double(index) / total

            do {
                if let trackInfo = try await processSingleAudioFile(sourceURL: url) {
                    currentBatch.append(trackInfo)
                    totalImportedCount += 1

                    // Пачка по 20 треков: сразу добавляем в медиатеку и даем UI перерисоваться
                    if currentBatch.count >= 20 {
                        commitBatch(currentBatch, to: libraryStore)
                        currentBatch.removeAll()
                        await Task.yield()
                    }
                }
            } catch {
                print("Ошибка при обработке файла \(url.lastPathComponent): \(error)")
            }
        }

        // Сохранение оставшихся треков последней пачки
        if !currentBatch.isEmpty {
            commitBatch(currentBatch, to: libraryStore)
            currentBatch.removeAll()
        }

        if totalImportedCount == 0 {
            errorMessage = "Не удалось импортировать аудиофайлы. Проверьте формат файлов."
            isImporting = false
            return
        }

        importProgress = 1.0
        statusText = "Импорт завершён! Добавлено треков: \(totalImportedCount)"
        try? await Task.sleep(nanoseconds: 500_000_000)
        isImporting = false
    }

    private func commitBatch(
        _ batch: [(track: Track, albumTitle: String, albumArtist: String, artwork: Data?)],
        to store: LibraryStore
    ) {
        guard !batch.isEmpty else { return }
        let groupedByAlbum = Dictionary(grouping: batch) { $0.albumTitle }
        for (albumTitle, items) in groupedByAlbum {
            let albumArtist = items.first?.albumArtist ?? "Неизвестный исполнитель"
            let artwork = items.first(where: { $0.artwork != nil })?.artwork
            let tracks = items.map { item -> Track in
                var t = item.track
                if t.artworkData == nil {
                    t.artworkData = artwork
                }
                return t
            }
            store.addTracks(tracks, forAlbum: albumTitle, artist: albumArtist, artwork: artwork)
        }
    }

    // MARK: - Импорт папки (создание альбома пачками по 20 треков)
    func importFolder(url: URL, libraryStore: LibraryStore = .shared) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        isImporting = true
        importProgress = 0.0
        statusText = "Сканирование папки..."
        errorMessage = nil

        let audioURLs = findAudioFiles(in: url)
        guard !audioURLs.isEmpty else {
            errorMessage = "В выбранной папке не найдено поддерживаемых аудиофайлов (.mp3, .wav, .m4a и др.)."
            isImporting = false
            return
        }

        let folderName = url.lastPathComponent
        var currentBatch: [Track] = []
        var totalProcessedCount = 0
        var detectedAlbumName: String?
        var detectedArtistName: String?
        var detectedArtwork: Data?

        let total = Double(audioURLs.count)

        for (index, fileURL) in audioURLs.enumerated() {
            let fileAccessing = fileURL.startAccessingSecurityScopedResource()
            defer {
                if fileAccessing {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            statusText = "Импорт: \(fileURL.lastPathComponent) (\(index + 1) из \(audioURLs.count))..."
            importProgress = Double(index) / total

            do {
                if let info = try await processSingleAudioFile(sourceURL: fileURL) {
                    currentBatch.append(info.track)
                    totalProcessedCount += 1

                    if detectedAlbumName == nil && info.albumTitle != "Неизвестный альбом" {
                        detectedAlbumName = info.albumTitle
                    }
                    if detectedArtistName == nil && info.albumArtist != "Неизвестный исполнитель" {
                        detectedArtistName = info.albumArtist
                    }
                    if detectedArtwork == nil && info.artwork != nil {
                        detectedArtwork = info.artwork
                    }

                    // Сохраняем пачками по 20 треков
                    if currentBatch.count >= 20 {
                        let finalAlbumTitle = (detectedAlbumName?.isEmpty == false) ? detectedAlbumName! : folderName
                        let finalArtist = detectedArtistName ?? "Неизвестный исполнитель"
                        let tracksToSave = currentBatch.map { track -> Track in
                            var t = track
                            t.albumName = finalAlbumTitle
                            if t.artworkData == nil { t.artworkData = detectedArtwork }
                            return t
                        }
                        libraryStore.addTracks(tracksToSave, forAlbum: finalAlbumTitle, artist: finalArtist, artwork: detectedArtwork)
                        currentBatch.removeAll()
                        await Task.yield()
                    }
                }
            } catch {
                print("Ошибка обработки \(fileURL.lastPathComponent): \(error)")
            }
        }

        let finalAlbumTitle = (detectedAlbumName?.isEmpty == false) ? detectedAlbumName! : folderName
        let finalArtist = detectedArtistName ?? "Неизвестный исполнитель"

        if !currentBatch.isEmpty {
            let tracksToSave = currentBatch.map { track -> Track in
                var t = track
                t.albumName = finalAlbumTitle
                if t.artworkData == nil { t.artworkData = detectedArtwork }
                return t
            }
            libraryStore.addTracks(tracksToSave, forAlbum: finalAlbumTitle, artist: finalArtist, artwork: detectedArtwork)
            currentBatch.removeAll()
        }

        guard totalProcessedCount > 0 else {
            errorMessage = "Не удалось прочитать аудиофайлы из папки."
            isImporting = false
            return
        }

        importProgress = 1.0
        statusText = "Альбом успешно добавлен (\(totalProcessedCount) треков)!"
        try? await Task.sleep(nanoseconds: 500_000_000)
        isImporting = false
    }

    // MARK: - Обработка отдельного аудиофайла
    private func processSingleAudioFile(sourceURL: URL) async throws -> (track: Track, albumTitle: String, albumArtist: String, artwork: Data?)? {
        guard supportedExtensions.contains(sourceURL.pathExtension.lowercased()) else {
            return nil
        }

        let bookmarkData = try? sourceURL.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let fileManager = FileManager.default
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let musicDir = docs.appendingPathComponent("Library/Music", isDirectory: true)

        if !fileManager.fileExists(atPath: musicDir.path) {
            try fileManager.createDirectory(at: musicDir, withIntermediateDirectories: true)
        }

        let uniqueFileName = "\(UUID().uuidString.prefix(8))_\(sourceURL.lastPathComponent)"
        let destinationURL = musicDir.appendingPathComponent(uniqueFileName)

        // Копирование файла в sandbox приложения
        var didCopy = false
        var copyError: Error?

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(readingItemAt: sourceURL, options: .withoutChanges, error: &coordinationError) { readURL in
            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try? fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: readURL, to: destinationURL)
                didCopy = true
            } catch {
                copyError = error
            }
        }

        // Если координатор или copyItem не сработал, пробуем прямое чтение Data
        if !didCopy {
            do {
                let data = try Data(contentsOf: sourceURL)
                try data.write(to: destinationURL, options: .atomic)
                didCopy = true
            } catch {
                print("Не удалось скопировать \(sourceURL.lastPathComponent): \(copyError?.localizedDescription ?? error.localizedDescription)")
            }
        }

        guard didCopy else { return nil }

        let relativePath = "Library/Music/\(uniqueFileName)"

        // Извлечение метаданных через AVURLAsset
        let asset = AVURLAsset(url: destinationURL)
        let commonMetadata = try await asset.load(.commonMetadata)

        var title: String?
        var artist: String?
        var albumName: String?
        var artworkData: Data?

        for item in commonMetadata {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle:
                title = try? await item.load(.stringValue)
            case .commonKeyArtist:
                artist = try? await item.load(.stringValue)
            case .commonKeyAlbumName:
                albumName = try? await item.load(.stringValue)
            case .commonKeyArtwork:
                if let rawArt = try? await item.load(.dataValue) {
                    artworkData = ArtworkProcessor.processTo2000x2000(data: rawArt) ?? rawArt
                }
            default:
                break
            }
        }

        let durationCM = try await asset.load(.duration)
        var duration: TimeInterval = durationCM.seconds
        if !duration.isFinite || duration <= 0 {
            if let file = try? AVAudioFile(forReading: destinationURL) {
                duration = Double(file.length) / file.processingFormat.sampleRate
            } else {
                duration = 0.0
            }
        }

        let fallbackTitle = sourceURL.deletingPathExtension().lastPathComponent
        let finalTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? title! : fallbackTitle
        let finalArtist = (artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? artist! : "Неизвестный исполнитель"
        let finalAlbum = (albumName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? albumName! : "Неизвестный альбом"

        let track = Track(
            title: finalTitle,
            artist: finalArtist,
            albumName: finalAlbum,
            relativeFilePath: relativePath,
            bookmarkData: bookmarkData,
            duration: duration,
            artworkData: artworkData
        )

        return (track: track, albumTitle: finalAlbum, albumArtist: finalArtist, artwork: artworkData)
    }

    private func findAudioFiles(in folderURL: URL) -> [URL] {
        var results: [URL] = []
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                results.append(fileURL)
            }
        }
        return results.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Делегат для перехвата редиректов коротких ссылок (on.soundcloud.com)
final class SoundCloudRedirectDelegate: NSObject, URLSessionTaskDelegate {
    var redirectedURL: String?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let location = response.value(forHTTPHeaderField: "Location") {
            redirectedURL = location
        } else if let location = response.allHeaderFields["Location"] as? String {
            redirectedURL = location
        } else if let location = response.allHeaderFields["location"] as? String {
            redirectedURL = location
        } else if let u = request.url?.absoluteString {
            redirectedURL = u
        }

        // Если получен целевой URL soundcloud.com (не короткий), прерываем редирект
        if let target = redirectedURL, target.contains("soundcloud.com") && !target.contains("on.soundcloud.com") {
            completionHandler(nil)
            return
        }

        // Если это кастомная схема (soundcloud://), останавливаем, чтобы не было ошибки unsupported URL
        if request.url?.scheme != "http" && request.url?.scheme != "https" {
            completionHandler(nil)
            return
        }

        completionHandler(request)
    }
}

// MARK: - Результат разрешения ссылки SoundCloud
enum SoundCloudResolvedItem {
    case track([String: Any])
    case playlist([String: Any])
}

// MARK: - Загрузчик треков и альбомов из SoundCloud (MP3 320 kbps)
@MainActor
final class SoundCloudDownloader: ObservableObject {
    static let shared = SoundCloudDownloader()

    @Published var isDownloading: Bool = false
    @Published var progress: Double = 0.0
    @Published var statusMessage: String = ""
    @Published var errorMessage: String? = nil
    @Published var lastImportedTrack: Track? = nil
    @Published var lastImportedPlaylist: Playlist? = nil
    @Published var lastImportedTracksCount: Int = 0

    private let fallbackClientId = "39AVoiZVrdvJEMFLH8T0c5WGshQaAPRJ"
    private let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    func reset() {
        isDownloading = false
        progress = 0.0
        statusMessage = ""
        errorMessage = nil
        lastImportedTrack = nil
        lastImportedPlaylist = nil
        lastImportedTracksCount = 0
    }

    /// Очистка строки для использования в качестве имени папки или файла
    func sanitizeName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
            .union(.newlines)
            .union(.controlCharacters)
        var cleaned = name.components(separatedBy: invalidCharacters).joined(separator: " ")
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// Извлечение актуального client_id или fallback
    func getClientId() async -> String {
        do {
            guard let pageURL = URL(string: "https://soundcloud.com") else { return fallbackClientId }
            var req = URLRequest(url: pageURL)
            req.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 6
            let (htmlData, _) = try await URLSession.shared.data(for: req)
            guard let html = String(data: htmlData, encoding: .utf8) else { return fallbackClientId }

            let pattern = #"https://a-v2\.sndcdn\.com/assets/[^"']+\.js"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return fallbackClientId }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

            for m in matches.suffix(2).reversed() {
                if let range = Range(m.range, in: html), let scriptURL = URL(string: String(html[range])) {
                    var sReq = URLRequest(url: scriptURL)
                    sReq.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
                    sReq.timeoutInterval = 5
                    if let (sData, _) = try? await URLSession.shared.data(for: sReq),
                       let sContent = String(data: sData, encoding: .utf8) {
                        let cidPattern = #"client_id[:=]["']([a-zA-Z0-9]{32})["']"#
                        if let cidRegex = try? NSRegularExpression(pattern: cidPattern),
                           let cidMatch = cidRegex.firstMatch(in: sContent, range: NSRange(sContent.startIndex..., in: sContent)),
                           let cidRange = Range(cidMatch.range(at: 1), in: sContent) {
                            let cid = String(sContent[cidRange])
                            if !cid.isEmpty {
                                return cid
                            }
                        }
                    }
                }
            }
        } catch {
            print("SoundCloud client_id fallback used: \(error)")
        }
        return fallbackClientId
    }

    /// Удаление трекинговых параметров из ссылки (?si=..., utm_...) и нормализация домена
    func cleanUrlString(_ rawUrlString: String) -> String {
        var clean = rawUrlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.hasPrefix("http://") && !clean.hasPrefix("https://") {
            clean = "https://" + clean
        }

        // Заменяем мобильный домен m.soundcloud.com на десктопный soundcloud.com,
        // так как api-v2.soundcloud.com/resolve возвращает пустой объект {} для m.soundcloud.com!
        clean = clean.replacingOccurrences(of: "://m.soundcloud.com", with: "://soundcloud.com")
        clean = clean.replacingOccurrences(of: "://mobile.soundcloud.com", with: "://soundcloud.com")

        guard let comp = URLComponents(string: clean) else { return clean }
        var cleanComp = comp
        if let items = comp.queryItems {
            let filtered = items.filter { item in
                let n = item.name.lowercased()
                return n != "si" && !n.hasPrefix("utm_") && n != "ref"
            }
            cleanComp.queryItems = filtered.isEmpty ? nil : filtered
        }
        return cleanComp.url?.absoluteString ?? clean
    }

    /// Разворачивание коротких ссылок (on.soundcloud.com)
    func expandUrlIfNeeded(_ rawUrlString: String) async -> String {
        let clean = cleanUrlString(rawUrlString)
        guard let url = URL(string: clean) else { return clean }

        if url.host?.contains("on.soundcloud.com") == true {
            statusMessage = "Распознавание короткой ссылки..."

            // Способ 1: через URLSession delegate с прерыванием
            let delegate = SoundCloudRedirectDelegate()
            let config = URLSessionConfiguration.default
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10

            if let (data, response) = try? await session.data(for: request) {
                if let loc = delegate.redirectedURL, loc.contains("soundcloud.com") && !loc.contains("on.soundcloud.com") {
                    return cleanUrlString(loc)
                }
                if let respUrl = response.url?.absoluteString, respUrl.contains("soundcloud.com") && !respUrl.contains("on.soundcloud.com") {
                    return cleanUrlString(respUrl)
                }
                if let html = String(data: data, encoding: .utf8) {
                    if let ogUrl = extractRegexMatch(in: html, pattern: #"<meta\s+property=["']og:url["']\s+content=["'](https://[^"']*soundcloud\.com/[^"']+)["']"#) {
                        return cleanUrlString(ogUrl)
                    }
                    if let canonical = extractRegexMatch(in: html, pattern: #"<link\s+rel=["']canonical["']\s+href=["'](https://[^"']*soundcloud\.com/[^"']+)["']"#) {
                        return cleanUrlString(canonical)
                    }
                    if let trackID = extractRegexMatch(in: html, pattern: #"soundcloud://tracks[:/](\d+)"#) {
                        return "track_id:\(trackID)"
                    }
                }
            }

            // Способ 2: резервный запрос без делегата (URLSession сам следует редиректам)
            var directReq = URLRequest(url: url)
            directReq.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
            directReq.timeoutInterval = 10
            if let (dData, dResp) = try? await URLSession.shared.data(for: directReq) {
                if let finalUrl = dResp.url?.absoluteString, finalUrl.contains("soundcloud.com") && !finalUrl.contains("on.soundcloud.com") {
                    return cleanUrlString(finalUrl)
                }
                if let html = String(data: dData, encoding: .utf8) {
                    if let ogUrl = extractRegexMatch(in: html, pattern: #"<meta\s+property=["']og:url["']\s+content=["'](https://[^"']*soundcloud\.com/[^"']+)["']"#) {
                        return cleanUrlString(ogUrl)
                    }
                }
            }
        }
        return clean
    }

    private func extractRegexMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    /// Разрешение URL: трек или альбом/плейлист
    private func resolveItem(from rawUrlString: String, clientId: String) async throws -> SoundCloudResolvedItem {
        let resolvedUrlString = await expandUrlIfNeeded(rawUrlString)

        // Вариант 1: Поиск по track_id
        if resolvedUrlString.hasPrefix("track_id:") {
            let trackId = resolvedUrlString.replacingOccurrences(of: "track_id:", with: "")
            if let trackURL = URL(string: "https://api-v2.soundcloud.com/tracks/\(trackId)?client_id=\(clientId)") {
                var req = URLRequest(url: trackURL)
                req.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   let http = resp as? HTTPURLResponse, http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return .track(json)
                }
            }
        }

        // Вариант 2: Запрос к resolve endpoint
        var components = URLComponents(string: "https://api-v2.soundcloud.com/resolve")
        components?.queryItems = [
            URLQueryItem(name: "url", value: resolvedUrlString),
            URLQueryItem(name: "client_id", value: clientId)
        ]
        if let resolveURL = components?.url {
            var req = URLRequest(url: resolveURL)
            req.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
            if let (resolveData, resolveResp) = try? await URLSession.shared.data(for: req),
               let http = resolveResp as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: resolveData) as? [String: Any],
               !json.isEmpty,
               (json["id"] != nil || json["tracks"] != nil) {
                let kind = json["kind"] as? String ?? ""
                if kind == "playlist" {
                    return .playlist(json)
                } else {
                    return .track(json)
                }
            }
        }

        // Вариант 3: Резервный парсинг window.__sc_hydration из HTML страницы
        if let pageURL = URL(string: resolvedUrlString) {
            statusMessage = "Анализ страницы SoundCloud..."
            var pageReq = URLRequest(url: pageURL)
            pageReq.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
            if let (pageData, _) = try? await URLSession.shared.data(for: pageReq),
               let html = String(data: pageData, encoding: .utf8) {
                let hydrationPattern = #"window\.__sc_hydration\s*=\s*(\[.*?\]);\s*<\/script>"#
                if let regex = try? NSRegularExpression(pattern: hydrationPattern, options: .dotMatchesLineSeparators),
                   let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   match.numberOfRanges > 1,
                   let jsonRange = Range(match.range(at: 1), in: html),
                   let hData = String(html[jsonRange]).data(using: .utf8),
                   let items = try? JSONSerialization.jsonObject(with: hData) as? [[String: Any]] {
                    for item in items where (item["hydratable"] as? String) == "playlist" {
                        if let playlist = item["data"] as? [String: Any] {
                            return .playlist(playlist)
                        }
                    }
                    for item in items where (item["hydratable"] as? String) == "sound" {
                        if let sound = item["data"] as? [String: Any] {
                            return .track(sound)
                        }
                    }
                }

                // Дополнительный поиск ID трека в мета-тегах (al:ios:url или twitter:app:url:iphone)
                if let trackID = extractRegexMatch(in: html, pattern: #"soundcloud:\/\/(?:tracks|sounds)[:/](\d+)"#),
                   let trackURL = URL(string: "https://api-v2.soundcloud.com/tracks/\(trackID)?client_id=\(clientId)") {
                    var tReq = URLRequest(url: trackURL)
                    tReq.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
                    if let (tData, tResp) = try? await URLSession.shared.data(for: tReq),
                       let tHttp = tResp as? HTTPURLResponse, tHttp.statusCode == 200,
                       let tJson = try? JSONSerialization.jsonObject(with: tData) as? [String: Any],
                       !tJson.isEmpty {
                        return .track(tJson)
                    }
                }
            }
        }

        throw NSError(domain: "SoundCloud", code: 404, userInfo: [NSLocalizedDescriptionKey: "Трек или альбом не найден. Проверьте ссылку на SoundCloud."])
    }

    /// Скачивание аудиопотока одного трека
    private func downloadTrackAudio(
        trackDict: [String: Any],
        clientId: String,
        progressBase: Double,
        progressSpan: Double
    ) async throws -> (audioData: Data, fileExtension: String, duration: Double) {
        guard let media = trackDict["media"] as? [String: Any],
              let transcodings = media["transcodings"] as? [[String: Any]],
              !transcodings.isEmpty else {
            throw NSError(domain: "SoundCloud", code: 4, userInfo: [NSLocalizedDescriptionKey: "У трека нет доступного аудиопотока."])
        }

        let sortedTranscodings = transcodings.sorted { t1, t2 in
            let f1 = t1["format"] as? [String: Any]
            let p1 = f1?["protocol"] as? String ?? ""
            let m1 = f1?["mime_type"] as? String ?? ""

            let f2 = t2["format"] as? [String: Any]
            let p2 = f2?["protocol"] as? String ?? ""
            let m2 = f2?["mime_type"] as? String ?? ""

            func score(p: String, m: String) -> Int {
                if p == "progressive" && m.contains("mpeg") { return 100 }
                if p == "hls" && m.contains("mp4") { return 90 }
                if p == "hls" && m.contains("mpeg") { return 80 }
                return 50
            }
            return score(p: p1, m: m1) > score(p: p2, m: m2)
        }

        var activeStreamDirectURL: URL? = nil
        var chosenTranscoding: [String: Any]? = nil

        for t in sortedTranscodings {
            guard let streamApiUrlStr = t["url"] as? String,
                  let streamApiURL = URL(string: "\(streamApiUrlStr)?client_id=\(clientId)") else { continue }

            var streamReq = URLRequest(url: streamApiURL)
            streamReq.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
            streamReq.timeoutInterval = 8

            if let (streamData, sResp) = try? await URLSession.shared.data(for: streamReq),
               let http = sResp as? HTTPURLResponse, http.statusCode == 200,
               let streamJson = try? JSONSerialization.jsonObject(with: streamData) as? [String: Any],
               let directMediaUrlStr = streamJson["url"] as? String,
               let directMediaURL = URL(string: directMediaUrlStr) {
                activeStreamDirectURL = directMediaURL
                chosenTranscoding = t
                break
            }
        }

        guard let directMediaURL = activeStreamDirectURL, let transcoding = chosenTranscoding else {
            throw NSError(domain: "SoundCloud", code: 6, userInfo: [NSLocalizedDescriptionKey: "Не удалось получить ссылку на аудиопоток."])
        }

        let format = transcoding["format"] as? [String: Any]
        let proto = format?["protocol"] as? String ?? ""
        let isHls = proto == "hls" || directMediaURL.pathExtension.lowercased() == "m3u8" || directMediaURL.absoluteString.contains(".m3u8")

        var finalAudioData = Data()
        var fileExtension = "mp3"

        if isHls {
            var m3u8Req = URLRequest(url: directMediaURL)
            m3u8Req.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
            let (m3u8Data, _) = try await URLSession.shared.data(for: m3u8Req)
            guard let m3u8Text = String(data: m3u8Data, encoding: .utf8) else {
                throw NSError(domain: "SoundCloud", code: 7, userInfo: [NSLocalizedDescriptionKey: "Не удалось прочитать m3u8 плейлист."])
            }

            var segmentUrls: [URL] = []
            var initUrl: URL? = nil

            let lines = m3u8Text.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("#EXT-X-MAP:URI=\"") {
                    let mapPart = trimmed.replacingOccurrences(of: "#EXT-X-MAP:URI=\"", with: "")
                    if let endQuote = mapPart.firstIndex(of: "\"") {
                        let uriString = String(mapPart[..<endQuote])
                        initUrl = URL(string: uriString, relativeTo: directMediaURL)?.absoluteURL
                    }
                } else if !trimmed.hasPrefix("#") && !trimmed.isEmpty {
                    if let segURL = URL(string: trimmed, relativeTo: directMediaURL)?.absoluteURL {
                        segmentUrls.append(segURL)
                    }
                }
            }

            if initUrl != nil {
                fileExtension = "m4a"
                if let iUrl = initUrl, let (iData, _) = try? await URLSession.shared.data(from: iUrl) {
                    finalAudioData.append(iData)
                }
            }

            let totalSegs = max(1, segmentUrls.count)
            for (idx, segUrl) in segmentUrls.enumerated() {
                if let (segData, _) = try? await URLSession.shared.data(from: segUrl) {
                    finalAudioData.append(segData)
                }
                let segFrac = Double(idx + 1) / Double(totalSegs)
                self.progress = min(0.98, progressBase + progressSpan * segFrac)
            }
        } else {
            var audioReq = URLRequest(url: directMediaURL)
            audioReq.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
            let (downloadedData, _) = try await URLSession.shared.data(for: audioReq)
            finalAudioData = downloadedData
            fileExtension = "mp3"
            self.progress = min(0.98, progressBase + progressSpan)
        }

        guard !finalAudioData.isEmpty else {
            throw NSError(domain: "SoundCloud", code: 8, userInfo: [NSLocalizedDescriptionKey: "Загруженный аудиофайл пуст."])
        }

        let durationMs = (trackDict["duration"] as? Double) ?? ((trackDict["full_duration"] as? Double) ?? 0.0)
        let durationSec = durationMs > 0 ? durationMs / 1000.0 : 0.0

        return (finalAudioData, fileExtension, durationSec)
    }

    /// Импорт альбома или плейлиста SoundCloud: создаёт новую папку с названием альбома и сохраняет туда все треки
    private func importPlaylist(
        playlistDict: [String: Any],
        clientId: String,
        targetPlaylist: Playlist?,
        libraryStore: LibraryStore
    ) async throws -> (tracks: [Track], playlist: Playlist?) {
        let albumTitle = (playlistDict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Альбом SoundCloud"
        let userDict = playlistDict["user"] as? [String: Any]
        let albumArtist = (userDict?["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "SoundCloud Artist"

        // Загрузка обложки альбома (2000×2000 px)
        statusMessage = "Загрузка обложки альбома «\(albumTitle)» (2000×2000)..."
        progress = 0.15

        let rawAlbumArtUrl = (playlistDict["artwork_url"] as? String) ?? (userDict?["avatar_url"] as? String)
        let albumArtworkData = await fetchHighResArtworkData(from: rawAlbumArtUrl)

        guard let rawTracks = playlistDict["tracks"] as? [[String: Any]], !rawTracks.isEmpty else {
            throw NSError(domain: "SoundCloud", code: 404, userInfo: [NSLocalizedDescriptionKey: "В этом альбоме нет доступных треков."])
        }

        statusMessage = "Получение списка треков альбома (\(rawTracks.count))..."
        progress = 0.20

        // SoundCloud возвращает треки после первых пяти без media (заглушки). Пакетно догружаем недостающие
        var allTrackDicts: [[String: Any]] = []
        let stubIds = rawTracks.filter { $0["media"] == nil }.compactMap { ($0["id"] as? Int) ?? ($0["id"] as? Int64).map(Int.init) }

        var resolvedStubs: [Int: [String: Any]] = [:]
        let chunkSize = 50
        for i in stride(from: 0, to: stubIds.count, by: chunkSize) {
            let end = Swift.min(i + chunkSize, stubIds.count)
            let chunk = stubIds[i..<end]
            let idsStr = chunk.map(String.init).joined(separator: ",")
            if let batchURL = URL(string: "https://api-v2.soundcloud.com/tracks?ids=\(idsStr)&client_id=\(clientId)") {
                var bReq = URLRequest(url: batchURL)
                bReq.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
                if let (bData, _) = try? await URLSession.shared.data(for: bReq),
                   let bArray = try? JSONSerialization.jsonObject(with: bData) as? [[String: Any]] {
                    for t in bArray {
                        if let tid = t["id"] as? Int {
                            resolvedStubs[tid] = t
                        }
                    }
                }
            }
        }

        for t in rawTracks {
            if t["media"] != nil {
                allTrackDicts.append(t)
            } else if let tid = (t["id"] as? Int) ?? (t["id"] as? Int64).map(Int.init), let full = resolvedStubs[tid] {
                allTrackDicts.append(full)
            }
        }

        guard !allTrackDicts.isEmpty else {
            throw NSError(domain: "SoundCloud", code: 4, userInfo: [NSLocalizedDescriptionKey: "Не удалось получить аудиопотоки треков из альбома."])
        }

        // 1. Создание отдельной папки на диске с названием альбома!
        let fileManager = FileManager.default
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safeAlbumFolderName = sanitizeName(albumTitle)
        let albumDir = docs.appendingPathComponent("Library/Music/\(safeAlbumFolderName)", isDirectory: true)
        if !fileManager.fileExists(atPath: albumDir.path) {
            try fileManager.createDirectory(at: albumDir, withIntermediateDirectories: true)
        }

        let total = allTrackDicts.count
        var downloadedTracks: [Track] = []

        // 2. Скачивание всех треков альбома в эту папку
        for (index, tDict) in allTrackDicts.enumerated() {
            let trackTitle = (tDict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Track \(index + 1)"
            let tUser = tDict["user"] as? [String: Any]
            let trackArtist = (tUser?["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? albumArtist

            statusMessage = "Загрузка [\(index + 1)/\(total)]: \(trackTitle)..."

            let progressBase = 0.22 + (Double(index) / Double(total)) * 0.70
            let progressSpan = 0.70 / Double(total)

            do {
                let (audioData, ext, fallbackDur) = try await downloadTrackAudio(
                    trackDict: tDict,
                    clientId: clientId,
                    progressBase: progressBase,
                    progressSpan: progressSpan
                )

                let safeTrackTitle = sanitizeName(trackTitle)
                let trackIndexStr = String(format: "%02d", index + 1)
                let fileName = "\(trackIndexStr) - \(safeTrackTitle).\(ext)"
                let destinationURL = albumDir.appendingPathComponent(fileName)

                try audioData.write(to: destinationURL, options: .atomic)

                let relativePath = "Library/Music/\(safeAlbumFolderName)/\(fileName)"
                let bookmarkData = try? destinationURL.bookmarkData(options: .minimalBookmark)

                var finalDuration = fallbackDur
                let asset = AVURLAsset(url: destinationURL)
                if let cmDur = try? await asset.load(.duration), cmDur.seconds.isFinite && cmDur.seconds > 0 {
                    finalDuration = cmDur.seconds
                }

                // Индивидуальная обложка трека (2000×2000 px) или обложка альбома
                var trackArtworkData: Data? = nil
                if let tArtStr = tDict["artwork_url"] as? String {
                    trackArtworkData = await fetchHighResArtworkData(from: tArtStr)
                }
                if trackArtworkData == nil {
                    trackArtworkData = albumArtworkData
                }

                let track = Track(
                    title: trackTitle,
                    artist: trackArtist,
                    albumName: albumTitle,
                    relativeFilePath: relativePath,
                    bookmarkData: bookmarkData,
                    duration: finalDuration,
                    artworkData: trackArtworkData
                )
                downloadedTracks.append(track)
            } catch {
                print("Пропуск трека \(trackTitle) из-за ошибки: \(error)")
            }
        }

        guard !downloadedTracks.isEmpty else {
            throw NSError(domain: "SoundCloud", code: 9, userInfo: [NSLocalizedDescriptionKey: "Не удалось загрузить ни одного трека из альбома."])
        }

        // 3. Добавление треков в медиатеку (под именем альбома)
        statusMessage = "Сохранение альбома и плейлиста..."
        progress = 0.95

        libraryStore.addTracks(downloadedTracks, forAlbum: albumTitle, artist: albumArtist, artwork: albumArtworkData)

        // 4. Создание плейлиста с названием альбома и добавление в него всех треков
        let playlist = libraryStore.createPlaylist(
            title: albumTitle,
            description: "Альбом из SoundCloud • \(albumArtist)",
            initialTrackIDs: downloadedTracks.map { $0.id },
            artworkData: albumArtworkData
        )

        // Если было выбрано добавление в целевой плейлист, добавляем и в него
        if let target = targetPlaylist, target.id != playlist.id {
            for t in downloadedTracks {
                libraryStore.addTrack(t, to: target)
            }
        }

        progress = 1.0
        statusMessage = "Альбом «\(albumTitle)» загружен! Сохранено \(downloadedTracks.count) треков в папку «\(safeAlbumFolderName)» и создан плейлист."
        lastImportedPlaylist = playlist
        lastImportedTracksCount = downloadedTracks.count
        isDownloading = false

        return (downloadedTracks, playlist)
    }

    /// Импорт одиночного трека SoundCloud в папку с названием альбома
    private func importSingleTrack(
        trackDict: [String: Any],
        clientId: String,
        targetPlaylist: Playlist?,
        libraryStore: LibraryStore
    ) async throws -> Track {
        let title = (trackDict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "SoundCloud Track"
        let userDict = trackDict["user"] as? [String: Any]
        let artist = (userDict?["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "SoundCloud Artist"

        // Название альбома трека (если есть тег, иначе SoundCloud)
        var rawAlbumName = (trackDict["release_title"] as? String)
            ?? ((trackDict["publisher_metadata"] as? [String: Any])?["album_title"] as? String)
            ?? ((trackDict["publisher_metadata"] as? [String: Any])?["release_title"] as? String)
        if rawAlbumName == nil || rawAlbumName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            rawAlbumName = "SoundCloud"
        }
        let albumTitle = rawAlbumName!

        progress = 0.25
        statusMessage = "Загрузка обложки трека (2000×2000)..."

        let rawTrackArtUrl = (trackDict["artwork_url"] as? String) ?? (userDict?["avatar_url"] as? String)
        let artworkData = await fetchHighResArtworkData(from: rawTrackArtUrl)

        progress = 0.35
        statusMessage = "Загрузка аудиопотока (320 kbps)..."

        let (audioData, fileExtension, fallbackDuration) = try await downloadTrackAudio(
            trackDict: trackDict,
            clientId: clientId,
            progressBase: 0.35,
            progressSpan: 0.55
        )

        progress = 0.92
        statusMessage = "Сохранение трека в папку альбома..."

        // Создаём отдельную папку с названием альбома на диске
        let fileManager = FileManager.default
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safeAlbumFolderName = sanitizeName(albumTitle)
        let albumDir = docs.appendingPathComponent("Library/Music/\(safeAlbumFolderName)", isDirectory: true)
        if !fileManager.fileExists(atPath: albumDir.path) {
            try fileManager.createDirectory(at: albumDir, withIntermediateDirectories: true)
        }

        let safeTitle = sanitizeName(title)
        let fileName = "\(safeTitle).\(fileExtension)"
        let destinationURL = albumDir.appendingPathComponent(fileName)

        try audioData.write(to: destinationURL, options: .atomic)

        let relativePath = "Library/Music/\(safeAlbumFolderName)/\(fileName)"
        let bookmarkData = try? destinationURL.bookmarkData(options: .minimalBookmark)

        var finalDuration = fallbackDuration
        let asset = AVURLAsset(url: destinationURL)
        if let cmDuration = try? await asset.load(.duration), cmDuration.seconds.isFinite && cmDuration.seconds > 0 {
            finalDuration = cmDuration.seconds
        }

        let track = Track(
            title: title,
            artist: artist,
            albumName: albumTitle,
            relativeFilePath: relativePath,
            bookmarkData: bookmarkData,
            duration: finalDuration,
            artworkData: artworkData
        )

        libraryStore.addTracks([track], forAlbum: albumTitle, artist: artist, artwork: artworkData)

        if let playlist = targetPlaylist {
            libraryStore.addTrack(track, to: playlist)
        }

        progress = 1.0
        statusMessage = "Трек успешно импортирован! Сохранён в папку «\(safeAlbumFolderName)»."
        lastImportedTrack = track
        isDownloading = false

        return track
    }

    /// Загружает обложку в ультра-высоком разрешении (пытается взять исходный мастер -original. до 2000×2000 / 3000×3000)
    /// и приводит её к эталону 2000×2000 пикселей высокой чёткости.
    func fetchHighResArtworkData(from rawUrlString: String?) async -> Data? {
        guard let rawUrlString = rawUrlString, !rawUrlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var candidateUrls: [String] = []

        // 1. Приоритет: -original. (полноразмерный мастер-оригинал, залитый автором)
        if rawUrlString.contains("-large.") {
            candidateUrls.append(rawUrlString.replacingOccurrences(of: "-large.", with: "-original."))
            candidateUrls.append(rawUrlString.replacingOccurrences(of: "-large.", with: "-t500x500."))
        } else if rawUrlString.contains("-t500x500.") {
            candidateUrls.append(rawUrlString.replacingOccurrences(of: "-t500x500.", with: "-original."))
            candidateUrls.append(rawUrlString)
        }
        candidateUrls.append(rawUrlString)

        for urlStr in candidateUrls {
            guard let url = URL(string: urlStr) else { continue }
            var request = URLRequest(url: url)
            request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 12.0

            if let (data, response) = try? await URLSession.shared.data(for: request),
               let httpResp = response as? HTTPURLResponse,
               httpResp.statusCode == 200,
               data.count > 1000,
               let image = UIImage(data: data),
               image.size.width > 0, image.size.height > 0 {
                return ArtworkProcessor.processTo2000x2000(image: image) ?? data
            }
        }

        return nil
    }

    /// Главный метод импорта: принимает ссылку на любой трек или альбом SoundCloud
    @discardableResult
    func importTrackOrAlbum(
        from soundcloudUrl: String,
        targetPlaylist: Playlist? = nil,
        libraryStore: LibraryStore
    ) async throws -> (tracks: [Track], playlist: Playlist?) {
        isDownloading = true
        progress = 0.05
        statusMessage = "Подключение к SoundCloud..."
        errorMessage = nil
        lastImportedTrack = nil
        lastImportedPlaylist = nil
        lastImportedTracksCount = 0

        let clientId = await getClientId()
        progress = 0.12
        statusMessage = "Поиск метаданных..."

        let item = try await resolveItem(from: soundcloudUrl, clientId: clientId)

        switch item {
        case .playlist(let playlistDict):
            return try await importPlaylist(
                playlistDict: playlistDict,
                clientId: clientId,
                targetPlaylist: targetPlaylist,
                libraryStore: libraryStore
            )
        case .track(let trackDict):
            let track = try await importSingleTrack(
                trackDict: trackDict,
                clientId: clientId,
                targetPlaylist: targetPlaylist,
                libraryStore: libraryStore
            )
            return ([track], nil)
        }
    }

    /// Совместимость для импорта одиночного трека
    @discardableResult
    func importTrack(
        from soundcloudUrl: String,
        targetPlaylist: Playlist? = nil,
        libraryStore: LibraryStore
    ) async throws -> Track {
        let (tracks, _) = try await importTrackOrAlbum(from: soundcloudUrl, targetPlaylist: targetPlaylist, libraryStore: libraryStore)
        guard let first = tracks.first else {
            throw NSError(domain: "SoundCloud", code: 404, userInfo: [NSLocalizedDescriptionKey: "Не удалось загрузить трек."])
        }
        return first
    }
}

// MARK: - Модальное окно импорта из SoundCloud
struct SoundCloudImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var libraryStore: LibraryStore
    @ObservedObject var playerVM = PlayerViewModel.shared
    @StateObject private var downloader = SoundCloudDownloader.shared

    @State private var urlText: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.15))
                                .frame(width: 80, height: 80)

                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 42))
                                .foregroundStyle(Color.orange)
                        }
                        .padding(.top, 16)

                        Text("Импорт из SoundCloud")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("Вставьте ссылку на любой трек или альбом из SoundCloud для сохранения в медиатеку в качестве MP3 320 kbps. Для альбома будет автоматически создана папка на диске и отдельный плейлист.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ссылка на трек или альбом")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        HStack(spacing: 10) {
                            Image(systemName: "link")
                                .foregroundStyle(.secondary)

                            TextField("https://soundcloud.com/...", text: $urlText)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .keyboardType(.URL)
                                .disabled(downloader.isDownloading)

                            if !urlText.isEmpty {
                                Button {
                                    urlText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Button {
                                if let clip = UIPasteboard.general.string {
                                    urlText = clip
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(Color.orange)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 20)

                    if downloader.isDownloading {
                        VStack(spacing: 12) {
                            ProgressView(value: downloader.progress, total: 1.0)
                                .tint(Color.orange)

                            Text(downloader.statusMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 20)
                    }

                    // Карточка успешно импортированного альбома
                    if let playlist = downloader.lastImportedPlaylist {
                        VStack(spacing: 14) {
                            HStack(spacing: 14) {
                                ArtworkView(
                                    data: playlist.artworkData,
                                    cornerRadius: 8,
                                    placeholderBackground: Color(white: 0.2),
                                    placeholderSymbolColor: .white,
                                    placeholderSymbol: "music.note.list"
                                )
                                .frame(width: 60, height: 60)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playlist.title)
                                        .font(.headline)
                                        .lineLimit(1)

                                    Text(playlist.playlistDescription)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    HStack(spacing: 6) {
                                        Text("Альбом • \(downloader.lastImportedTracksCount) треков")
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.2))
                                            .foregroundStyle(Color.orange)
                                            .clipShape(Capsule())

                                        Text("📁 Папка создана")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                            Button {
                                playerVM.playPlaylist(playlist, in: libraryStore)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text("Слушать альбом")
                                }
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.orange)
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal, 20)
                    } else if let track = downloader.lastImportedTrack {
                        // Карточка одиночного трека
                        VStack(spacing: 14) {
                            HStack(spacing: 14) {
                                ArtworkView(
                                    data: track.artworkData,
                                    cornerRadius: 8,
                                    placeholderBackground: Color(white: 0.2),
                                    placeholderSymbolColor: .white
                                )
                                .frame(width: 56, height: 56)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(track.title)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text("MP3 320 kbps")
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.2))
                                            .foregroundStyle(Color.orange)
                                            .clipShape(Capsule())

                                        Text(formatTime(track.duration))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                            Button {
                                playerVM.playTrack(track)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text("Слушать сейчас")
                                }
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.orange)
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    if let err = downloader.errorMessage {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(err)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        .padding(.horizontal, 20)
                    }

                    if downloader.lastImportedTrack == nil && downloader.lastImportedPlaylist == nil {
                        Button {
                            startDownload()
                        } label: {
                            HStack(spacing: 8) {
                                if downloader.isDownloading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "arrow.down.to.line")
                                }
                                Text(downloader.isDownloading ? "Загрузка..." : "Скачать (трек или альбом)")
                            }
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(canDownload ? Color.orange : Color.gray.opacity(0.4))
                            .clipShape(Capsule())
                        }
                        .disabled(!canDownload || downloader.isDownloading)
                        .padding(.horizontal, 20)
                    }

                    Spacer(minLength: 30)
                }
            }
            .navigationTitle("SoundCloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                downloader.reset()
                if let clip = UIPasteboard.general.string, clip.contains("soundcloud.com") {
                    urlText = clip
                }
            }
        }
    }

    private var canDownload: Bool {
        let clean = urlText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clean.contains("soundcloud.com")
    }

    private func startDownload() {
        guard canDownload else { return }
        Task {
            do {
                _ = try await downloader.importTrackOrAlbum(from: urlText, libraryStore: libraryStore)
            } catch {
                downloader.errorMessage = error.localizedDescription
                downloader.isDownloading = false
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
