import Foundation
import Combine
import SwiftUI
import AVFoundation
import UIKit
import os

// MARK: - Легковесный поток прогресса воспроизведения (iOS 16+)
/// Изолирует высокочастотные тики времени от рендера всего дерева плеера.
/// На этот объект подписывается ТОЛЬКО скруббер и метки времени.
final class PlaybackProgress: ObservableObject {
    static let shared = PlaybackProgress()

    @Published var currentTime: TimeInterval = 0.0
    @Published var duration: TimeInterval = 0.0
    @Published var isScrubbing: Bool = false
    @Published var scrubTime: TimeInterval = 0.0

    private init() {}

    /// Форматирование секунд в строку MM:SS
    static func formatTime(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Главная ViewModel управления воспроизведением и очередью треков (iOS 16+)
@MainActor
final class PlayerViewModel: ObservableObject {
    static let shared = PlayerViewModel()

    private let audioEngine = AudioEngineManager.shared
    private let nowPlaying = NowPlayingManager.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.timuraliev.mymusic", category: "PlayerViewModel")
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Состояние воспроизведения
    @Published var currentTrack: Track?
    @Published var queue: [Track] = []
    @Published var currentIndex: Int = 0

    @Published var isPlaying: Bool = false
    @Published var showFullScreenPlayer: Bool = false

    @Published var isShuffleEnabled: Bool = false
    @Published var repeatMode: RepeatMode = .off

    @Published var volume: Double = 1.0 {
        didSet {
            audioEngine.volume = Float(volume)
        }
    }

    /// Прокси для обратной совместимости
    var currentTime: TimeInterval {
        get { PlaybackProgress.shared.currentTime }
        set { PlaybackProgress.shared.currentTime = newValue }
    }

    var duration: TimeInterval {
        get { PlaybackProgress.shared.duration }
        set { PlaybackProgress.shared.duration = newValue }
    }

    var isScrubbing: Bool {
        get { PlaybackProgress.shared.isScrubbing }
        set { PlaybackProgress.shared.isScrubbing = newValue }
    }

    var scrubTime: TimeInterval {
        get { PlaybackProgress.shared.scrubTime }
        set { PlaybackProgress.shared.scrubTime = newValue }
    }

    private var originalQueue: [Track] = []
    private var periodicSaveTimer: Timer?

    // Предзагрузка следующего трека
    private var preloadedFileURL: URL?
    private var preloadedTrackID: UUID?

    private init() {
        bindAudioEngine()
        configureRemoteCommands()
    }

    // MARK: - Связывание с AudioEngineManager
    private func bindAudioEngine() {
        audioEngine.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                guard let self = self else { return }
                self.isPlaying = playing
                self.syncNowPlaying()
                if playing {
                    self.startPeriodicSaveTimer()
                } else {
                    self.stopPeriodicSaveTimer()
                    self.savePlaybackState()
                }
            }
            .store(in: &cancellables)

        audioEngine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dur in
                self?.syncNowPlaying()
            }
            .store(in: &cancellables)

        // Обработка автоматического завершения трека
        audioEngine.onPlaybackEnded = { [weak self] in
            self?.handleTrackEnded()
        }

        // Предварительная подготовка следующего трека за 4 секунды до конца текущего
        audioEngine.onNearEnd = { [weak self] in
            self?.preloadNextTrackIfNeeded()
        }
    }

    // MARK: - Системные команды гарнитуры и Lock Screen
    private func configureRemoteCommands() {
        nowPlaying.configureRemoteCommands(
            onPlay: { [weak self] in self?.play() },
            onPause: { [weak self] in self?.pause() },
            onTogglePlayPause: { [weak self] in self?.togglePlayPause() },
            onNext: { [weak self] in self?.playNext() },
            onPrevious: { [weak self] in self?.playPrevious() },
            onSeek: { [weak self] time in self?.seek(to: time) }
        )
    }

    func syncNowPlaying() {
        guard let track = currentTrack else {
            nowPlaying.clearNowPlaying()
            return
        }

        let dur = PlaybackProgress.shared.duration > 0 ? PlaybackProgress.shared.duration : track.duration
        let cur = PlaybackProgress.shared.currentTime

        nowPlaying.updateNowPlaying(
            title: track.title,
            artist: track.artist,
            albumTitle: track.albumName,
            duration: dur,
            currentTime: cur,
            isPlaying: isPlaying,
            artworkData: track.resolvedArtworkData()
        )
    }

    // MARK: - Обновление метаданных трека без остановки воспроизведения
    func updateTrackMetadata(_ updatedTrack: Track) {
        if currentTrack?.id == updatedTrack.id {
            currentTrack = updatedTrack
            syncNowPlaying()
        }

        if let qIdx = queue.firstIndex(where: { $0.id == updatedTrack.id }) {
            queue[qIdx] = updatedTrack
        }
        if let origIdx = originalQueue.firstIndex(where: { $0.id == updatedTrack.id }) {
            originalQueue[origIdx] = updatedTrack
        }
    }

    // MARK: - Единая точка воспроизведения (Unified Play Pipeline)
    /// Главная и ЕДИНСТВЕННАЯ функция воспроизведения в приложении:
    /// тап по списку, кнопки next/previous, автопереход, выбор из очереди, экран блокировки.
    func play(
        track: Track,
        at index: Int? = nil,
        startPosition: TimeInterval = 0.0,
        autoPlay: Bool = true
    ) {
        logger.info("[PlayerVM.play(track:)] Запрос трека: '\(track.title)', index: \(String(describing: index)), autoPlay: \(autoPlay), queueCount: \(self.queue.count)")

        // 1. Проверяем наличие файла на диске. Если файл отсутствует — переходим к следующему
        guard let fileURL = track.resolvedFileURL() else {
            logger.error("[PlayerVM.play(track:)] Файл трека не найден на диске: \(track.relativeFilePath). Пропуск трека.")
            handleMissingTrack(track, at: index)
            return
        }

        // 2. Актуализируем индекс в очереди
        if let idx = index, idx >= 0 && idx < queue.count {
            self.currentIndex = idx
        } else if let foundIdx = queue.firstIndex(where: { $0.id == track.id }) {
            self.currentIndex = foundIdx
        }

        // 3. Синхронно обновляем текущий трек и прогресс
        self.currentTrack = track
        PlaybackProgress.shared.isScrubbing = false
        PlaybackProgress.shared.scrubTime = 0.0
        PlaybackProgress.shared.currentTime = startPosition
        PlaybackProgress.shared.duration = track.duration

        // 4. Предпрогрев миниатюр и фоновых цветов обложки
        prewarmArtworkAndColors(for: track)

        // 5. Подготовка аудиодвижка и запуск
        do {
            try audioEngine.prepare(url: fileURL, startPosition: startPosition)
            if autoPlay {
                self.isPlaying = true
                audioEngine.play()
            } else {
                self.isPlaying = false
            }
            syncNowPlaying()
            savePlaybackState()
            logger.info("[PlayerVM.play(track:)] Успешный запуск '\(track.title)' (idx: \(self.currentIndex)), gen=\(self.audioEngine.currentGeneration), isPlaying=\(self.isPlaying)")
        } catch {
            logger.error("[PlayerVM.play(track:)] Ошибка подготовки аудиодвижка: \(error.localizedDescription)")
            handleMissingTrack(track, at: index)
        }
    }

    private func handleMissingTrack(_ track: Track, at index: Int?) {
        guard !queue.isEmpty else {
            stop()
            currentTrack = nil
            return
        }
        let nextIdx = (index ?? currentIndex) + 1
        if nextIdx < queue.count {
            self.currentIndex = nextIdx
            logger.info("[PlayerVM.handleMissingTrack] Пропуск битого трека -> переходим к индексу \(nextIdx)")
            play(track: queue[nextIdx], at: nextIdx, startPosition: 0.0, autoPlay: true)
        } else {
            logger.info("[PlayerVM.handleMissingTrack] Битый трек был последним, остановка")
            stop()
        }
    }

    // MARK: - Управление воспроизведением треков и списков
    func playTrack(_ track: Track, in contextQueue: [Track] = []) {
        hapticFeedback()
        let resolvedQueue = contextQueue.isEmpty ? [track] : contextQueue
        self.originalQueue = resolvedQueue

        if isShuffleEnabled {
            var shuffled = resolvedQueue.filter { $0.id != track.id }.shuffled()
            shuffled.insert(track, at: 0)
            self.queue = shuffled
            self.currentIndex = 0
            play(track: track, at: 0, startPosition: 0.0, autoPlay: true)
        } else {
            self.queue = resolvedQueue
            let idx = resolvedQueue.firstIndex(where: { $0.id == track.id }) ?? 0
            self.currentIndex = idx
            play(track: track, at: idx, startPosition: 0.0, autoPlay: true)
        }
    }

    func playAlbum(_ album: Album, startingFrom track: Track? = nil, shuffle: Bool = false) {
        let sortedTracks = album.tracks.sorted {
            if $0.trackNumber != $1.trackNumber {
                return $0.trackNumber < $1.trackNumber
            }
            return $0.title < $1.title
        }
        guard !sortedTracks.isEmpty else { return }

        self.isShuffleEnabled = shuffle
        let first = track ?? (shuffle ? sortedTracks.randomElement()! : sortedTracks.first!)
        playTrack(first, in: sortedTracks)
    }

    func playPlaylist(_ playlist: Playlist, startingFrom track: Track? = nil, in store: LibraryStore, shuffle: Bool = false) {
        let tracks = playlist.resolvedTracks(in: store)
        guard !tracks.isEmpty else { return }

        self.isShuffleEnabled = shuffle
        let first = track ?? (shuffle ? tracks.randomElement()! : tracks.first!)
        playTrack(first, in: tracks)
    }

    func play() {
        hapticFeedback()
        logger.info("[PlayerVM.play] Нажатие кнопки Play/Resume")
        guard let track = currentTrack else {
            if let first = queue.first {
                play(track: first, at: 0, startPosition: 0.0, autoPlay: true)
            }
            return
        }

        if audioEngine.currentAudioFile == nil, let fileURL = track.resolvedFileURL() {
            logger.info("[PlayerVM.play] currentAudioFile == nil, подготовка перед запуском")
            try? audioEngine.prepare(url: fileURL, startPosition: PlaybackProgress.shared.currentTime)
        }

        self.isPlaying = true
        audioEngine.play()
        syncNowPlaying()
    }

    func pause() {
        hapticFeedback()
        logger.info("[PlayerVM.pause] Нажатие кнопки Pause")
        self.isPlaying = false
        audioEngine.pause()
        syncNowPlaying()
        savePlaybackState()
    }

    func stop() {
        audioEngine.stop()
        isPlaying = false
        PlaybackProgress.shared.currentTime = 0.0
        PlaybackProgress.shared.isScrubbing = false
        PlaybackProgress.shared.scrubTime = 0.0
        syncNowPlaying()
        savePlaybackState()
    }

    func togglePlayPause() {
        hapticFeedback()
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func playNext() {
        hapticFeedback()
        logger.info("[PlayerVM.playNext] Запрос следующего трека (текущий: \(self.currentIndex)/\(self.queue.count), repeatMode: \(self.repeatMode.rawValue))")
        guard !queue.isEmpty else {
            logger.warning("[PlayerVM.playNext] Очередь пуста")
            return
        }

        if repeatMode == .one {
            if let current = currentTrack {
                play(track: current, at: currentIndex, startPosition: 0.0, autoPlay: true)
            }
            return
        }

        if currentIndex + 1 < queue.count {
            let nextIndex = currentIndex + 1
            play(track: queue[nextIndex], at: nextIndex, startPosition: 0.0, autoPlay: true)
        } else if repeatMode == .all {
            let nextIndex = 0
            play(track: queue[nextIndex], at: nextIndex, startPosition: 0.0, autoPlay: true)
        } else {
            // Очередь закончилась (.off)
            logger.info("[PlayerVM.playNext] Очередь воспроизведения завершена")
            audioEngine.stop()
            self.isPlaying = false
            PlaybackProgress.shared.currentTime = 0.0
            PlaybackProgress.shared.isScrubbing = false
            PlaybackProgress.shared.scrubTime = 0.0
            syncNowPlaying()
            savePlaybackState()
        }
    }

    func playPrevious() {
        hapticFeedback()
        logger.info("[PlayerVM.playPrevious] Запрос предыдущего трека (текущий: \(self.currentIndex), pos: \(PlaybackProgress.shared.currentTime)s)")
        guard !queue.isEmpty else { return }

        // Если прошло более 3 секунд от начала — перезапускаем текущий трек с начала (стандарт Apple Music)
        if PlaybackProgress.shared.currentTime > 3.0 {
            logger.info("[PlayerVM.playPrevious] currentTime > 3.0, перемотка текущего трека в 0")
            seek(to: 0.0)
            return
        }

        if currentIndex > 0 {
            let prevIndex = currentIndex - 1
            play(track: queue[prevIndex], at: prevIndex, startPosition: 0.0, autoPlay: true)
        } else if repeatMode == .all {
            let prevIndex = queue.count - 1
            play(track: queue[prevIndex], at: prevIndex, startPosition: 0.0, autoPlay: true)
        } else {
            logger.info("[PlayerVM.playPrevious] Первый трек очереди, перемотка в начало")
            seek(to: 0.0)
        }
    }

    func seek(to time: TimeInterval) {
        let dur = PlaybackProgress.shared.duration
        if dur > 0 && time >= (dur - 0.35) {
            PlaybackProgress.shared.isScrubbing = false
            PlaybackProgress.shared.scrubTime = 0.0
            PlaybackProgress.shared.currentTime = 0.0
            audioEngine.seekToEndAndFinish()
            return
        }
        audioEngine.seek(to: time)
        PlaybackProgress.shared.currentTime = time
        syncNowPlaying()
        savePlaybackState()
    }

    func toggleShuffle() {
        hapticFeedback()
        isShuffleEnabled.toggle()
        logger.info("[PlayerVM.toggleShuffle] Shuffle: \(self.isShuffleEnabled)")
        guard let current = currentTrack else { return }

        if isShuffleEnabled {
            var others = originalQueue.filter { $0.id != current.id }.shuffled()
            others.insert(current, at: 0)
            self.queue = others
            self.currentIndex = 0
        } else {
            self.queue = originalQueue
            self.currentIndex = originalQueue.firstIndex(where: { $0.id == current.id }) ?? 0
        }
        savePlaybackState()
    }

    func cycleRepeatMode() {
        hapticFeedback()
        repeatMode = repeatMode.next
        logger.info("[PlayerVM.cycleRepeatMode] Repeat: \(self.repeatMode.rawValue)")
        savePlaybackState()
    }

    private func handleTrackEnded() {
        logger.info("[PlayerVM.handleTrackEnded] Автоматический переход к следующему треку")
        playNext()
    }

    // MARK: - Управление очередью воспроизведения
    func addToQueue(_ track: Track) {
        queue.append(track)
        originalQueue.append(track)
        savePlaybackState()
    }

    func addToQueueNext(_ track: Track) {
        let insertIndex = min(currentIndex + 1, queue.count)
        queue.insert(track, at: insertIndex)
        originalQueue.insert(track, at: min(currentIndex + 1, originalQueue.count))
        savePlaybackState()
    }

    func moveQueueItem(from source: IndexSet, to destination: Int) {
        let currentID = currentTrack?.id
        queue.move(fromOffsets: source, toOffset: destination)
        if let currentID = currentID, let newIdx = queue.firstIndex(where: { $0.id == currentID }) {
            currentIndex = newIdx
        }
        savePlaybackState()
    }

    func removeQueueItems(at offsets: IndexSet) {
        let currentID = currentTrack?.id
        queue.remove(atOffsets: offsets)
        if let currentID = currentID, let newIdx = queue.firstIndex(where: { $0.id == currentID }) {
            currentIndex = newIdx
        }
        savePlaybackState()
    }

    func removeQueueTrack(withID id: UUID) {
        let currentID = currentTrack?.id
        queue.removeAll { $0.id == id }
        originalQueue.removeAll { $0.id == id }

        if let currentID = currentID, let newIdx = queue.firstIndex(where: { $0.id == currentID }) {
            currentIndex = newIdx
        } else if currentID == id {
            if !queue.isEmpty {
                let nextIdx = min(currentIndex, queue.count - 1)
                currentIndex = nextIdx
                play(track: queue[nextIdx], at: nextIdx, startPosition: 0.0, autoPlay: isPlaying)
            } else {
                stop()
                currentTrack = nil
            }
        }
        savePlaybackState()
    }

    func clearQueue() {
        if let current = currentTrack {
            queue = [current]
            originalQueue = [current]
            currentIndex = 0
        } else {
            queue.removeAll()
            originalQueue.removeAll()
            currentIndex = 0
        }
        savePlaybackState()
    }

    // MARK: - Прогрев обложки и цветов фона
    func prewarmArtworkAndColors(for track: Track) {
        let store = LibraryStore.shared
        let data = track.resolvedArtworkData(in: store)
        if let data = data, !data.isEmpty {
            ArtworkThumbnailCache.shared.loadThumbnail(data: data, pixelSize: 120) { _ in }
            ArtworkThumbnailCache.shared.loadThumbnail(data: data, pixelSize: 800) { _ in }
            ArtworkColorCache.shared.getOrComputeColors(for: track.id, artworkData: data) { _, _ in }
        }
    }

    // MARK: - Предзагрузка следующего трека
    private func preloadNextTrackIfNeeded() {
        guard !queue.isEmpty else { return }
        let nextIdx = currentIndex + 1 < queue.count ? currentIndex + 1 : (repeatMode == .all ? 0 : -1)
        guard nextIdx >= 0 && nextIdx < queue.count else { return }
        let nextTrack = queue[nextIdx]
        guard nextTrack.id != preloadedTrackID else { return }

        if let url = nextTrack.resolvedFileURL() {
            self.preloadedTrackID = nextTrack.id
            self.preloadedFileURL = url
            // Прогреваем кэш файловой системы для URL
            DispatchQueue.global(qos: .utility).async {
                _ = try? AVAudioFile(forReading: url)
            }
            prewarmArtworkAndColors(for: nextTrack)
        }
    }

    // MARK: - Сохранение и восстановление состояния плеера (UserDefaults + относительные пути)
    func savePlaybackState() {
        guard let track = currentTrack else {
            UserDefaults.standard.removeObject(forKey: "Player_SavedTrackPath")
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(track.relativeFilePath, forKey: "Player_SavedTrackPath")
        defaults.set(queue.map { $0.relativeFilePath }, forKey: "Player_SavedQueuePaths")
        defaults.set(currentIndex, forKey: "Player_SavedCurrentIndex")
        defaults.set(PlaybackProgress.shared.currentTime, forKey: "Player_SavedPosition")
        defaults.set(isShuffleEnabled, forKey: "Player_SavedShuffle")
        defaults.set(repeatMode.rawValue, forKey: "Player_SavedRepeat")
    }

    func restorePlaybackState(in store: LibraryStore) {
        guard currentTrack == nil else { return }
        let defaults = UserDefaults.standard
        guard let trackPath = defaults.string(forKey: "Player_SavedTrackPath"),
              let track = store.tracks.first(where: { $0.relativeFilePath == trackPath }) else {
            return
        }

        let savedQueuePaths = defaults.stringArray(forKey: "Player_SavedQueuePaths") ?? []
        let restoredQueue = savedQueuePaths.compactMap { path in
            store.tracks.first(where: { $0.relativeFilePath == path })
        }

        self.queue = restoredQueue.isEmpty ? [track] : restoredQueue
        self.originalQueue = self.queue
        self.currentIndex = defaults.integer(forKey: "Player_SavedCurrentIndex")
        if self.currentIndex >= self.queue.count {
            self.currentIndex = 0
        }
        self.currentTrack = track
        prewarmArtworkAndColors(for: track)
        self.isShuffleEnabled = defaults.bool(forKey: "Player_SavedShuffle")
        let repInt = defaults.integer(forKey: "Player_SavedRepeat")
        if let rep = RepeatMode(rawValue: repInt) {
            self.repeatMode = rep
        }

        let savedPos = defaults.double(forKey: "Player_SavedPosition")
        logger.info("[PlayerVM.restorePlaybackState] Восстановление состояния: '\(track.title)', pos: \(savedPos)s")
        play(track: track, at: self.currentIndex, startPosition: savedPos, autoPlay: false)
    }

    private func startPeriodicSaveTimer() {
        stopPeriodicSaveTimer()
        periodicSaveTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.savePlaybackState()
            }
        }
    }

    private func stopPeriodicSaveTimer() {
        periodicSaveTimer?.invalidate()
        periodicSaveTimer = nil
    }

    private func hapticFeedback() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
