import SwiftUI
import UIKit
import ImageIO
import CryptoKit
import os

// MARK: - Процессор обложек 2000×2000 px
/// Обработчик масштабирования и оптимизации обложек альбомов и треков до эталонного разрешения 2000×2000 px
enum ArtworkProcessor {
    static let targetDimension: CGFloat = 2000.0

    /// Масштабирует, центрирует и обрезает изображение до квадрата 2000×2000 px с максимальным качеством (Lanczos/bicubic)
    static func processTo2000x2000(data: Data?) -> Data? {
        guard let data = data, !data.isEmpty, let image = UIImage(data: data) else {
            return data
        }
        return processTo2000x2000(image: image) ?? data
    }

    /// Преобразует любое изображение в идеальный квадрат 2000×2000 px высокой чёткости с сохранением пропорций и качеством JPEG 0.92
    static func processTo2000x2000(image: UIImage) -> Data? {
        let originalSize = image.size
        guard originalSize.width > 0 && originalSize.height > 0 else {
            return image.jpegData(compressionQuality: 0.92)
        }

        let targetSize = CGSize(width: targetDimension, height: targetDimension)

        // Центрированный кроп в квадрат с масштабированием до targetSize (aspect fill)
        let aspectWidth = targetSize.width / originalSize.width
        let aspectHeight = targetSize.height / originalSize.height
        let scale = max(aspectWidth, aspectHeight)

        let scaledWidth = originalSize.width * scale
        let scaledHeight = originalSize.height * scale
        let originX = (targetSize.width - scaledWidth) / 2.0
        let originY = (targetSize.height - scaledHeight) / 2.0
        let drawRect = CGRect(x: originX, y: originY, width: scaledWidth, height: scaledHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0 // Фиксированное физическое разрешение 2000×2000 пикселей
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let processedImage = renderer.image { context in
            // Чёрная подложка
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: drawRect)
        }

        return processedImage.jpegData(compressionQuality: 0.92)
    }
}

// MARK: - Высокопроизводительный кэш миниатюр обложек (NSCache + Диск + ImageIO Downsampling)
final class ArtworkThumbnailCache {
    static let shared = ArtworkThumbnailCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheQueue = DispatchQueue(label: "com.timuraliev.mymusic.artworkcache", qos: .utility)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.timuraliev.mymusic", category: "ArtworkCache")

    private var diskCacheDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("ArtworkThumbnails_v2", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() {
        memoryCache.countLimit = 150
        memoryCache.totalCostLimit = 48 * 1024 * 1024 // 48 МБ максимум в RAM

        // Очищаем старый повреждённый кэш обложек
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let oldDir = caches.appendingPathComponent("ArtworkThumbnails", isDirectory: true)
        try? fileManager.removeItem(at: oldDir)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    @objc private func handleMemoryWarning() {
        logger.warning("Очистка кэша обложек в памяти из-за предупреждения системы (didReceiveMemoryWarning).")
        clearMemoryCache()
    }

    func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    func cacheKey(for data: Data, pixelSize: Int) -> String {
        let digest = SHA256.hash(data: data)
        let hashString = digest.compactMap { String(format: "%02x", $0) }.joined()
        return "\(hashString)_\(pixelSize)"
    }

    func cachedImage(forKey key: String) -> UIImage? {
        return memoryCache.object(forKey: key as NSString)
    }

    func loadThumbnail(data: Data, pixelSize: Int, completion: @escaping (UIImage?) -> Void) {
        let key = cacheKey(for: data, pixelSize: pixelSize)

        // 1. Проверяем быструю RAM
        if let cached = memoryCache.object(forKey: key as NSString) {
            completion(cached)
            return
        }

        // 2. Фоновый поток: проверка дискового кэша и ImageIO downsampling
        cacheQueue.async { [weak self] in
            guard let self = self else { return }

            let diskURL = self.diskCacheDirectory.appendingPathComponent("\(key).jpg")
            if let diskData = try? Data(contentsOf: diskURL), let diskImg = UIImage(data: diskData) {
                let cost = Int(diskImg.size.width * diskImg.size.height * 4)
                self.memoryCache.setObject(diskImg, forKey: key as NSString, cost: cost)
                DispatchQueue.main.async {
                    completion(diskImg)
                }
                return
            }

            // Downsampling без декодирования полного 2000×2000 изображения в RAM
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize
            ]

            guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let thumbnail = UIImage(cgImage: cgThumb)
            let cost = Int(thumbnail.size.width * thumbnail.size.height * 4)
            self.memoryCache.setObject(thumbnail, forKey: key as NSString, cost: cost)

            // Сохраняем на диск в кэш
            if let jpegData = thumbnail.jpegData(compressionQuality: 0.85) {
                try? jpegData.write(to: diskURL, options: .atomic)
            }

            DispatchQueue.main.async {
                completion(thumbnail)
            }
        }
    }
}

/// Компонент отображения обложки трека или альбома с downsampling и поддержкой кастомной заглушки (iOS 16+)
struct ArtworkView: View {
    let data: Data?
    var cornerRadius: CGFloat = 8
    var targetPixelSize: Int = 120 // ~120 px для списков, ~800 px для плеера
    var placeholderBackground: Color? = nil
    var placeholderSymbolColor: Color? = nil
    var placeholderSymbol: String = "music.note"

    @State private var loadedImage: UIImage? = nil
    @State private var currentDataKey: String? = nil
    @ObservedObject private var themeManager = ThemeManager.shared

    init(
        data: Data?,
        cornerRadius: CGFloat = 8,
        targetPixelSize: Int = 120,
        placeholderBackground: Color? = nil,
        placeholderSymbolColor: Color? = nil,
        placeholderSymbol: String = "music.note"
    ) {
        self.data = data
        self.cornerRadius = cornerRadius
        self.targetPixelSize = targetPixelSize
        self.placeholderBackground = placeholderBackground
        self.placeholderSymbolColor = placeholderSymbolColor
        self.placeholderSymbol = placeholderSymbol

        if let data = data, !data.isEmpty {
            let key = ArtworkThumbnailCache.shared.cacheKey(for: data, pixelSize: targetPixelSize)
            let cached = ArtworkThumbnailCache.shared.cachedImage(forKey: key)
            self._loadedImage = State(initialValue: cached)
            self._currentDataKey = State(initialValue: key)
        } else {
            self._loadedImage = State(initialValue: nil)
            self._currentDataKey = State(initialValue: nil)
        }
    }

    private var activeImage: UIImage? {
        if let data = data, !data.isEmpty {
            let key = ArtworkThumbnailCache.shared.cacheKey(for: data, pixelSize: targetPixelSize)
            if let cached = ArtworkThumbnailCache.shared.cachedImage(forKey: key) {
                return cached
            }
        }
        return loadedImage
    }

    var body: some View {
        ZStack {
            if let image = activeImage {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .antialiased(true)
                    .aspectRatio(1, contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .transition(.opacity)
            } else {
                placeholderView
            }
        }
        .onAppear {
            let expectedKey = data.map { ArtworkThumbnailCache.shared.cacheKey(for: $0, pixelSize: targetPixelSize) }
            if currentDataKey != expectedKey || activeImage == nil {
                loadImage(for: data)
            }
        }
        .onChange(of: data) { newData in
            loadImage(for: newData)
        }
    }

    private func loadImage(for inputData: Data?) {
        guard let inputData = inputData, !inputData.isEmpty else {
            self.loadedImage = nil
            self.currentDataKey = nil
            return
        }

        let key = ArtworkThumbnailCache.shared.cacheKey(for: inputData, pixelSize: targetPixelSize)
        self.currentDataKey = key

        if let cached = ArtworkThumbnailCache.shared.cachedImage(forKey: key) {
            self.loadedImage = cached
            return
        }

        // Если в памяти нет, сбрасываем отображение старой обложки, чтобы не залипала
        self.loadedImage = nil

        ArtworkThumbnailCache.shared.loadThumbnail(data: inputData, pixelSize: targetPixelSize) { [expectedKey = key] img in
            guard let img = img, self.currentDataKey == expectedKey else { return }
            withAnimation(.easeIn(duration: 0.15)) {
                self.loadedImage = img
            }
        }
    }

    private var placeholderView: some View {
        ZStack {
            if let bg = placeholderBackground {
                bg
            } else {
                LinearGradient(
                    colors: [
                        themeManager.accentColor.opacity(0.85),
                        themeManager.accentColor.opacity(0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            Image(systemName: placeholderSymbol)
                .font(.system(size: cornerRadius * 2.2, weight: .semibold))
                .foregroundStyle(placeholderSymbolColor ?? themeManager.contrastForegroundColor)
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
