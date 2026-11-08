import SwiftUI
import UIKit
import CoreImage
import ImageIO

/// Кэш и фоновый вычислитель доминирующих цветов обложки для фона плеера Apple Music
final class ArtworkColorCache {
    static let shared = ArtworkColorCache()

    private let cache = NSCache<NSString, CachedColors>()
    private let computeQueue = DispatchQueue(label: "com.timuraliev.mymusic.colorcache", qos: .utility)

    final class CachedColors {
        let topColor: Color
        let bottomColor: Color
        init(topColor: Color, bottomColor: Color) {
            self.topColor = topColor
            self.bottomColor = bottomColor
        }
    }

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    @objc private func handleMemoryWarning() {
        cache.removeAllObjects()
    }

    func cachedColors(for trackId: UUID?) -> (topColor: Color, bottomColor: Color)? {
        guard let trackId = trackId else { return nil }
        if let cached = cache.object(forKey: trackId.uuidString as NSString) {
            return (cached.topColor, cached.bottomColor)
        }
        return nil
    }

    func getOrComputeColors(
        for trackId: UUID?,
        artworkData: Data?,
        completion: @escaping (Color, Color) -> Void
    ) {
        let fallbackTop = Color(red: 0.16, green: 0.16, blue: 0.18)
        let fallbackBottom = Color(red: 58.0 / 255.0, green: 58.0 / 255.0, blue: 60.0 / 255.0)

        guard let trackId = trackId else {
            completion(fallbackTop, fallbackBottom)
            return
        }

        let key = trackId.uuidString as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached.topColor, cached.bottomColor)
            return
        }

        guard let data = artworkData, !data.isEmpty else {
            completion(fallbackTop, fallbackBottom)
            return
        }

        computeQueue.async { [weak self] in
            guard let self = self else { return }

            let avgColor = self.extractAverageColorDownsampled(from: data) ?? UIColor(white: 0.25, alpha: 1.0)

            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0

            avgColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

            // Верх: затемнённый примерно до 55% яркости и насыщенности ~60%
            let targetSat = max(0.12, saturation * 0.60)
            let targetBri = min(0.55, max(0.18, brightness * 0.55))
            let topUiColor = UIColor(hue: hue, saturation: targetSat, brightness: targetBri, alpha: 1.0)
            let topColor = Color(topUiColor)

            // Низ: тёмно-серый ~ #3A3A3C (58, 58, 60) с лёгким оттенком
            var topR: CGFloat = 0, topG: CGFloat = 0, topB: CGFloat = 0
            topUiColor.getRed(&topR, green: &topG, blue: &topB, alpha: nil)

            let baseR: CGFloat = 58.0 / 255.0
            let baseG: CGFloat = 58.0 / 255.0
            let baseB: CGFloat = 60.0 / 255.0

            let bottomR = baseR * 0.82 + topR * 0.18
            let bottomG = baseG * 0.82 + topG * 0.18
            let bottomB = baseB * 0.82 + topB * 0.18

            let bottomColor = Color(red: Double(bottomR), green: Double(bottomG), blue: Double(bottomB))

            let entry = CachedColors(topColor: topColor, bottomColor: bottomColor)
            self.cache.setObject(entry, forKey: key)

            DispatchQueue.main.async {
                completion(topColor, bottomColor)
            }
        }
    }

    /// Сверхбыстрое и экономичное извлечение среднего цвета через 16px миниатюру без декодирования полного изображения
    private func extractAverageColorDownsampled(from data: Data) -> UIColor? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 16
        ]

        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let thumb = UIImage(cgImage: cgThumb)
        return extractAverageViaCG(thumb)
    }

    private func extractAverageViaCG(_ image: UIImage) -> UIColor? {
        let size = CGSize(width: 1, height: 1)
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: size))
        let pixel = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard let cg = pixel?.cgImage,
              let provider = cg.dataProvider,
              let data = provider.data,
              let ptr = CFDataGetBytePtr(data) else {
            return nil
        }

        return UIColor(
            red: CGFloat(ptr[0]) / 255.0,
            green: CGFloat(ptr[1]) / 255.0,
            blue: CGFloat(ptr[2]) / 255.0,
            alpha: 1.0
        )
    }
}

/// Аутентичный вертикальный градиент фона плеера с наложением .ultraThinMaterial
struct BlurredArtworkBackground: View {
    let trackId: UUID?
    let artworkData: Data?

    @State private var topColor: Color = Color(red: 0.16, green: 0.16, blue: 0.18)
    @State private var bottomColor: Color = Color(red: 58.0 / 255.0, green: 58.0 / 255.0, blue: 60.0 / 255.0)

    var body: some View {
        // Чистый непрозрачный градиент для максимальной производительности (60 fps на iPhone 8 Plus)
        ZStack {
            Color(red: 0.12, green: 0.12, blue: 0.14)

            LinearGradient(
                colors: [topColor, bottomColor],
                startPoint: .top,
                endPoint: .bottom
            )
            .overlay(
                Color.black.opacity(0.14)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            updateColors(animated: false)
        }
        .onChange(of: trackId) { _ in
            updateColors(animated: true)
        }
        .onChange(of: artworkData) { _ in
            updateColors(animated: true)
        }
    }

    private func updateColors(animated: Bool) {
        if let cached = ArtworkColorCache.shared.cachedColors(for: trackId) {
            applyColors(top: cached.topColor, bottom: cached.bottomColor, animated: animated)
            return
        }

        ArtworkColorCache.shared.getOrComputeColors(for: trackId, artworkData: artworkData) { top, bottom in
            self.applyColors(top: top, bottom: bottom, animated: animated)
        }
    }

    private func applyColors(top: Color, bottom: Color, animated: Bool) {
        if animated {
            withAnimation(.easeInOut(duration: 0.6)) {
                self.topColor = top
                self.bottomColor = bottom
            }
        } else {
            self.topColor = top
            self.bottomColor = bottom
        }
    }
}
