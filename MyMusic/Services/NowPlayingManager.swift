import Foundation
import MediaPlayer
import UIKit
import ImageIO

/// Менеджер системных элементов управления (Lock Screen, Control Center, наушники)
final class NowPlayingManager {
    static let shared = NowPlayingManager()

    private let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()

    private var currentArtworkKey: String?
    private var currentMediaArtwork: MPMediaItemArtwork?

    private init() {}

    /// Настройка системных команд с экрана блокировки и кнопок гарнитуры
    func configureRemoteCommands(
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onTogglePlayPause: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.playCommand.addTarget { _ in
            onPlay()
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.pauseCommand.addTarget { _ in
            onPause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            onTogglePlayPause()
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.addTarget { _ in
            onNext()
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.addTarget { _ in
            onPrevious()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.addTarget { event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            onSeek(positionEvent.positionTime)
            return .success
        }
    }

    /// Обновление метаданных текущего трека в Центре уведомлений и на экране блокировки
    func updateNowPlaying(
        title: String,
        artist: String,
        albumTitle: String,
        duration: TimeInterval,
        currentTime: TimeInterval,
        isPlaying: Bool,
        artworkData: Data?
    ) {
        var info = [String: Any]()

        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = artist
        info[MPMediaItemPropertyAlbumTitle] = albumTitle
        info[MPMediaItemPropertyPlaybackDuration] = max(0, duration)
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, currentTime)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(AudioEngineManager.shared.playbackRate) : 0.0

        let trackKey = "\(title)_\(artist)_\(artworkData?.count ?? 0)"
        if trackKey == currentArtworkKey, let cached = currentMediaArtwork {
            info[MPMediaItemPropertyArtwork] = cached
        } else if let data = artworkData, !data.isEmpty {
            let thumb = makeDownsampledArtwork(from: data, targetPixelSize: 600)
            if let image = thumb {
                let mediaArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.currentArtworkKey = trackKey
                self.currentMediaArtwork = mediaArtwork
                info[MPMediaItemPropertyArtwork] = mediaArtwork
            }
        } else {
            currentArtworkKey = nil
            currentMediaArtwork = nil
        }

        nowPlayingInfoCenter.nowPlayingInfo = info
        nowPlayingInfoCenter.playbackState = isPlaying ? .playing : .paused
    }

    /// Прямая и немедленная установка состояния воспроизведения для исключения рассинхрона экрана блокировки
    func setPlaybackState(_ state: MPNowPlayingPlaybackState) {
        nowPlayingInfoCenter.playbackState = state
        if var info = nowPlayingInfoCenter.nowPlayingInfo {
            info[MPNowPlayingInfoPropertyPlaybackRate] = (state == .playing) ? Double(AudioEngineManager.shared.playbackRate) : 0.0
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, PlaybackProgress.shared.currentTime)
            nowPlayingInfoCenter.nowPlayingInfo = info
        }
    }

    /// Быстрый downsample обложки для Lock Screen без выделения 2000×2000 памяти
    private func makeDownsampledArtwork(from data: Data, targetPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Сброс информации о воспроизведении
    func clearNowPlaying() {
        currentArtworkKey = nil
        currentMediaArtwork = nil
        nowPlayingInfoCenter.nowPlayingInfo = nil
    }
}
