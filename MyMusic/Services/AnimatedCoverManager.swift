import Foundation
import UIKit
import AVFoundation
import ImageIO
import CoreImage
import Combine
import CoreTransferable
import os

// MARK: - Менеджер анимированных обложек
/// Сервис управления, импорта, конвертации и кэширования анимированных обложек (iOS 16+)
@MainActor
final class AnimatedCoverManager: ObservableObject {
    static let shared = AnimatedCoverManager()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.timuraliev.mymusic", category: "AnimatedCover")
    private let fileManager = FileManager.default
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Настройки и системные состояния
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "isAnimatedCoversEnabled")
            if !isEnabled {
                AnimatedCoverPlaybackCoordinator.shared.stopAndRelease()
            }
        }
    }

    @Published private(set) var isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var isReduceMotion: Bool = UIAccessibility.isReduceMotionEnabled

    /// Флаг разрешения проигрывания видеообложки с учётом энергосбережения и доступности
    var canPlayAnimation: Bool {
        isEnabled && !isLowPowerMode && !isReduceMotion
    }

    // MARK: - Директория хранения в песочнице
    nonisolated var coversDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Covers", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() {
        if UserDefaults.standard.object(forKey: "isAnimatedCoversEnabled") == nil {
            self.isEnabled = true
        } else {
            self.isEnabled = UserDefaults.standard.bool(forKey: "isAnimatedCoversEnabled")
        }

        // Подписка на изменение режима энергосбережения
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            if self.isLowPowerMode {
                self.logger.info("Включён режим энергосбережения -> остановка анимированных обложек")
                AnimatedCoverPlaybackCoordinator.shared.stopAndRelease()
            }
        }

        // Подписка на изменение режима «Уменьшение движения»
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.isReduceMotion = UIAccessibility.isReduceMotionEnabled
            if self.isReduceMotion {
                self.logger.info("Включено уменьшение движения -> остановка анимированных обложек")
                AnimatedCoverPlaybackCoordinator.shared.stopAndRelease()
            }
        }
    }

    // MARK: - Расчёт и очистка дискового пространства
    nonisolated var totalDiskUsageBytes: Int64 {
        let dir = coversDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for file in files {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    nonisolated var formattedDiskUsage: String {
        let bytes = totalDiskUsageBytes
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Удаляет файл анимированной обложки, если он больше нигде не используется
    nonisolated func deleteCoverFileIfUnused(fileName: String?, in store: LibraryStore) {
        guard let fileName = fileName, !fileName.isEmpty else { return }
        let isUsedInTracks = store.tracks.contains { $0.animatedCoverFileName == fileName }
        let isUsedInAlbums = store.albums.contains { $0.animatedCoverFileName == fileName }

        if !isUsedInTracks && !isUsedInAlbums {
            let fileURL = coversDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: fileURL)
            logger.info("Удалён неиспользуемый файл анимированной обложки: \(fileName)")
        }
    }

    /// Полная очистка всех анимированных обложек
    nonisolated func clearAllCovers(in store: LibraryStore) {
        Task { @MainActor in
            AnimatedCoverPlaybackCoordinator.shared.stopAndRelease()
        }

        let dir = coversDirectory
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }

        for i in store.tracks.indices {
            store.tracks[i].animatedCoverFileName = nil
        }
        for i in store.albums.indices {
            store.albums[i].animatedCoverFileName = nil
        }
        store.save()
        logger.info("Все анимированные обложки успешно удалены")
    }

    // MARK: - Импорт и конвертация (MP4, MOV, GIF -> 720×720 H.264 без аудио, до 15 сек)
    func processAndSaveVideo(
        sourceURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> (fileName: String, previewImageData: Data) {
        let uniqueName = "\(UUID().uuidString).mp4"
        let outputURL = coversDirectory.appendingPathComponent(uniqueName)

        // Безопасный доступ к security-scoped URL (при импорте через fileImporter)
        let isSecurityScoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let isGIF = sourceURL.pathExtension.lowercased() == "gif"

        if isGIF {
            try await convertGIFToMP4(gifURL: sourceURL, outputURL: outputURL, progress: progress)
        } else {
            try await convertVideoToSquareMP4(sourceURL: sourceURL, outputURL: outputURL, progress: progress)
        }

        // Генерация статичного кадра-превью
        let previewData = try await generatePreviewImage(from: outputURL)

        return (uniqueName, previewData)
    }

    // MARK: - Конвертация GIF -> MP4 (ImageIO + AVAssetWriter)
    private func convertGIFToMP4(
        gifURL: URL,
        outputURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else {
            throw NSError(domain: "AnimatedCover", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось прочитать GIF"])
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else {
            throw NSError(domain: "AnimatedCover", code: 2, userInfo: [NSLocalizedDescriptionKey: "GIF не содержит кадров"])
        }

        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 720,
            AVVideoHeightKey: 720,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: 720,
                kCVPixelBufferHeightKey as String: 720
            ]
        )

        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var currentTime = CMTime.zero
        let maxDuration = 15.0
        var frameIdx = 0

        while currentTime.seconds < maxDuration {
            let sourceIdx = frameIdx % frameCount
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, sourceIdx, nil) else { break }

            var frameDelay = 0.1
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, sourceIdx, nil) as? [CFString: Any],
               let gifDict = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                if let unclamped = gifDict[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0.015 {
                    frameDelay = unclamped
                } else if let delay = gifDict[kCGImagePropertyGIFDelayTime] as? Double, delay > 0.015 {
                    frameDelay = delay
                }
            }
            if frameDelay < 0.02 { frameDelay = 0.1 }

            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            if let buffer = createPixelBuffer(from: cgImage, targetSize: CGSize(width: 720, height: 720)) {
                adaptor.append(buffer, withPresentationTime: currentTime)
            }

            currentTime = CMTimeAdd(currentTime, CMTime(seconds: frameDelay, preferredTimescale: 600))
            frameIdx += 1

            let p = min(currentTime.seconds / maxDuration, 1.0)
            progress(p * 0.9)

            if sourceIdx == frameCount - 1 && currentTime.seconds >= 3.0 {
                break
            }
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        progress(1.0)
    }

    // MARK: - Транскодирование видео (MP4 / MOV) в 720×720 квадрат без звука
    private func convertVideoToSquareMP4(
        sourceURL: URL,
        outputURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw NSError(domain: "AnimatedCover", code: 3, userInfo: [NSLocalizedDescriptionKey: "В файле нет видеодорожки"])
        }

        let durationSec = try await asset.load(.duration).seconds
        let targetDuration = min(durationSec, 15.0)

        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: targetDuration, preferredTimescale: 600))

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 720,
            AVVideoHeightKey: 720,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: 720,
                kCVPixelBufferHeightKey as String: 720
            ]
        )

        writer.add(writerInput)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let preferredTransform = try await videoTrack.load(.preferredTransform)

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts.seconds > targetDuration { break }

            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                if let buffer = renderImageBufferToSquare(
                    imageBuffer: imageBuffer,
                    targetSize: CGSize(width: 720, height: 720),
                    transform: preferredTransform
                ) {
                    adaptor.append(buffer, withPresentationTime: pts)
                }
            }

            let p = min(pts.seconds / targetDuration, 1.0)
            progress(p * 0.9)
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        progress(1.0)
    }

    // MARK: - Рендеринг кадра в квадрат 720×720 с центрированием (Aspect Fill)
    private func renderImageBufferToSquare(
        imageBuffer: CVPixelBuffer,
        targetSize: CGSize,
        transform: CGAffineTransform
    ) -> CVPixelBuffer? {
        var ciImage = CIImage(cvPixelBuffer: imageBuffer)
        ciImage = ciImage.transformed(by: transform)

        let extent = ciImage.extent
        guard extent.width > 0 && extent.height > 0 else { return nil }

        let scale = max(targetSize.width / extent.width, targetSize.height / extent.height)
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let scaledExtent = scaledImage.extent
        let cropX = scaledExtent.origin.x + (scaledExtent.width - targetSize.width) / 2.0
        let cropY = scaledExtent.origin.y + (scaledExtent.height - targetSize.height) / 2.0
        let cropRect = CGRect(x: cropX, y: cropY, width: targetSize.width, height: targetSize.height)

        let croppedImage = scaledImage.cropped(to: cropRect).transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))

        var outputBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(targetSize.width),
            Int(targetSize.height),
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &outputBuffer
        )
        guard let out = outputBuffer else { return nil }
        ciContext.render(croppedImage, to: out)
        return out
    }

    private func createPixelBuffer(from image: CGImage, targetSize: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(targetSize.width),
            Int(targetSize.height),
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        let scale = max(targetSize.width / imgW, targetSize.height / imgH)
        let drawW = imgW * scale
        let drawH = imgH * scale
        let drawX = (targetSize.width - drawW) / 2.0
        let drawY = (targetSize.height - drawH) / 2.0

        context.fill(CGRect(origin: .zero, size: targetSize))
        context.draw(image, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))

        return buffer
    }

    // MARK: - Извлечение первого кадра (800×800 px) для превью
    func generatePreviewImage(from videoURL: URL) async throws -> Data {
        let asset = AVURLAsset(url: videoURL)
        let durationSec = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)

        let targetTime = CMTime(seconds: min(1.0, durationSec * 0.5), preferredTimescale: 600)
        let cgImage = try await generator.image(at: targetTime).image
        let uiImage = UIImage(cgImage: cgImage)

        guard let data = uiImage.jpegData(compressionQuality: 0.90) else {
            throw NSError(domain: "AnimatedCover", code: 4, userInfo: [NSLocalizedDescriptionKey: "Не удалось сформировать превью обложки"])
        }
        return data
    }
}

// MARK: - Единый координатор воспроизведения видеообложек
/// Гарантирует наличие не более одного активного AVQueuePlayer в памяти устройства (Apple Music 60 fps)
@MainActor
final class AnimatedCoverPlaybackCoordinator: ObservableObject {
    static let shared = AnimatedCoverPlaybackCoordinator()

    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private(set) var currentURL: URL?

    @Published private(set) var isPlaying: Bool = false

    private init() {}

    /// Запуск или возобновление воспроизведения по URL
    func play(url: URL) {
        guard AnimatedCoverManager.shared.canPlayAnimation else {
            stopAndRelease()
            return
        }

        if currentURL == url, let p = player {
            p.play()
            self.isPlaying = true
            return
        }

        // Освобождаем предыдущий плеер
        stopAndRelease()

        let item = AVPlayerItem(url: url)
        let newPlayer = AVQueuePlayer()
        newPlayer.isMuted = true
        newPlayer.allowsExternalPlayback = false
        newPlayer.preventsDisplaySleepDuringVideoPlayback = false
        newPlayer.actionAtItemEnd = .none

        self.looper = AVPlayerLooper(player: newPlayer, templateItem: item)
        self.player = newPlayer
        self.currentURL = url

        newPlayer.play()
        self.isPlaying = true
    }

    /// Приостановка на текущем кадре (при паузе музыки)
    func pause() {
        player?.pause()
        self.isPlaying = false
    }

    /// Полная остановка и освобождение ресурсов (при сворачивании плеера, уходе в фон или жесте)
    func stopAndRelease() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = nil
        currentURL = nil
        isPlaying = false
    }
}

// MARK: - CoreTransferable модель для импорта видео из PhotosPicker (iOS 16+)
struct MovieTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let tempDir = FileManager.default.temporaryDirectory
            let targetURL = tempDir.appendingPathComponent("\(UUID().uuidString).\(received.file.pathExtension)")
            try? FileManager.default.removeItem(at: targetURL)
            try FileManager.default.copyItem(at: received.file, to: targetURL)
            return MovieTransferable(url: targetURL)
        }
    }
}
