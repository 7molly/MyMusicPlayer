import Foundation
import AVFoundation
import Combine
import UIKit
import QuartzCore
import os

/// Главный аудиодвижок приложения на базе AVAudioEngine.
/// Цепочка воспроизведения:
/// AVAudioPlayerNode -> AVAudioUnitEQ (10 полос) -> AVAudioUnitTimePitch (Строй A4) -> mainMixerNode -> outputNode
final class AudioEngineManager: NSObject, ObservableObject {
    static let shared = AudioEngineManager()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.timuraliev.mymusic", category: "AudioEngine")

    // MARK: - Аудио узлы (Audio Nodes)
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    let equalizerNode = AVAudioUnitEQ(numberOfBands: 10)
    let timePitchNode = AVAudioUnitTimePitch()

    // MARK: - Состояние воспроизведения
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0.0
    @Published var duration: TimeInterval = 0.0
    @Published var volume: Float = 1.0 {
        didSet {
            engine.mainMixerNode.outputVolume = volume
        }
    }

    // MARK: - Эквалайзер и строй A4
    @Published var isEQEnabled: Bool = true {
        didSet {
            applyEQEnabledState()
            UserDefaults.standard.set(isEQEnabled, forKey: "EQ_Enabled")
        }
    }

    /// Гейны 10 полос в дБ (-12 ... +12)
    @Published var eqGains: [Float] = Array(repeating: 0.0, count: 10) {
        didSet {
            applyEQGains()
            saveEQGains()
        }
    }

    // MARK: - Настройки скорости (Rate) и тональности (Pitch Shift)
    /// Скорость воспроизведения: 0.5x ... 2.0x (по умолчанию 1.0)
    @Published var playbackRate: Float = 1.0 {
        didSet {
            applyPlaybackRate()
            scheduleSaveSpeedAndPitch()
        }
    }

    /// Смещение тональности в полутонах: -12.0 ... +12.0 (по умолчанию 0.0)
    @Published var pitchShift: Float = 0.0 {
        didSet {
            applyPitchShift()
            scheduleSaveSpeedAndPitch()
        }
    }

    /// Смещение в центах (1 полутон = 100 центов)
    var pitchShiftCents: Float {
        return pitchShift * 100.0
    }

    private var saveSpeedPitchWorkItem: DispatchWorkItem?
    private func scheduleSaveSpeedAndPitch() {
        saveSpeedPitchWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            UserDefaults.standard.set(self.playbackRate, forKey: "Audio_PlaybackRate")
            UserDefaults.standard.set(self.pitchShift, forKey: "Audio_PitchShift")
        }
        saveSpeedPitchWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    // MARK: - Внутренние свойства
    private(set) var currentAudioFile: AVAudioFile?
    private var currentFormat: AVAudioFormat?
    private var currentFileLength: AVAudioFramePosition = 0
    private var currentSampleRate: Double = 44100.0

    /// Токен поколения воспроизведения (инкрементируется при любой смене трека, остановке или перемотке)
    private(set) var currentGeneration: Int = 0

    private var seekTimeOffset: TimeInterval = 0.0
    private var playStartHostTime: UInt64 = 0
    private var displayLink: CADisplayLink?
    private var currentPlaybackToken: UUID = UUID()
    private var wasPlayingBeforeInterruption = false
    private var hasTriggeredNearEnd = false

    /// Коллбэк окончания трека для автоперехода к следующему
    var onPlaybackEnded: (() -> Void)?
    /// Коллбэк приближения к окончанию (за 4 секунды) для предварительной подгрузки следующего трека
    var onNearEnd: (() -> Void)?

    // MARK: - Инициализация
    private override init() {
        super.init()
        setupAudioSession()
        setupAudioEngine()
        setupNotifications()
        loadSavedSettings()
    }

    deinit {
        displayLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Настройка AVAudioSession
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            logger.info("AVAudioSession успешно инициализирована в категории .playback")
        } catch {
            logger.error("Ошибка первоначальной настройки AVAudioSession: \(error.localizedDescription)")
        }
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func ensureEngineRunning() throws {
        try activateAudioSession()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
            logger.info("AVAudioEngine успешно запущен")
        }
    }

    // MARK: - Жизненный цикл фона и переднего плана (ScenePhase)
    func handleDidEnterBackground() {
        logger.info("Приложение ушло в фон: останавливаем CADisplayLink, чтобы не нагружать процессор и не вызвать watchdog jetsam")
        stopTimer()
    }

    func handleWillEnterForeground() {
        logger.info("Приложение возвращается на передний план: синхронизируем позицию из аудиоузла")
        if isPlaying {
            updateCurrentTime()
            startTimer()
        }
    }

    @objc private func handleMemoryWarning() {
        logger.warning("Получено системное предупреждение о памяти (didReceiveMemoryWarning) в AudioEngineManager")
        ArtworkThumbnailCache.shared.clearMemoryCache()
    }

    // MARK: - Настройка цепочки AVAudioEngine
    private func setupAudioEngine() {
        engine.attach(playerNode)
        engine.attach(equalizerNode)
        engine.attach(timePitchNode)

        // Инициализация 10 полос эквалайзера
        let frequencies = EQPreset.frequencies
        for (index, freq) in frequencies.enumerated() {
            let band = equalizerNode.bands[index]
            band.filterType = .parametric
            band.frequency = Float(freq)
            band.bandwidth = 1.0 // 1 октава
            band.gain = 0.0
            band.bypass = false
        }

        // Настройка TimePitch: максимальное качество сглаживания (overlap 32)
        timePitchNode.overlap = 32.0
        updateTimePitchState()

        // Начальное подключение со стандартным форматом
        if let standardFormat = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2) {
            connectNodes(with: standardFormat)
        }
    }

    private func connectNodes(with format: AVAudioFormat) {
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(equalizerNode)
        engine.disconnectNodeOutput(timePitchNode)

        engine.connect(playerNode, to: equalizerNode, format: format)
        engine.connect(equalizerNode, to: timePitchNode, format: format)
        engine.connect(timePitchNode, to: engine.mainMixerNode, format: nil)

        currentFormat = format
    }

    // MARK: - Уведомления системы (Interruption / Route Change / Configuration Change)
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSilenceSecondaryAudioHint(_:)),
            name: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.wasPlayingBeforeInterruption = self.isPlaying
                self.logger.info("AVAudioSession interruption began. wasPlaying: \(self.wasPlayingBeforeInterruption)")
                NowPlayingManager.shared.setPlaybackState(.interrupted)
                if self.isPlaying {
                    self.pauseInternal()
                }
            }
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
                wasPlayingBeforeInterruption = false
                return
            }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let shouldResume = self.wasPlayingBeforeInterruption && options.contains(.shouldResume)
                self.logger.info("AVAudioSession interruption ended. shouldResume: \(shouldResume)")
                self.wasPlayingBeforeInterruption = false

                if shouldResume {
                    if !AVAudioSession.sharedInstance().isOtherAudioPlaying {
                        try? self.activateAudioSession()
                        self.play()
                    }
                }
            }
        @unknown default:
            break
        }
    }

    @objc private func handleSilenceSecondaryAudioHint(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
              let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: typeValue) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if type == .begin {
                if self.isPlaying {
                    self.wasPlayingBeforeInterruption = true
                    self.pauseInternal()
                }
            } else if type == .end {
                let shouldResume = self.wasPlayingBeforeInterruption
                self.wasPlayingBeforeInterruption = false
                if shouldResume && !AVAudioSession.sharedInstance().isOtherAudioPlaying {
                    try? self.activateAudioSession()
                    self.play()
                }
            }
        }
    }

    @objc private func handleAudioSessionRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        logger.info("AVAudioSession route change reason: \(reasonValue)")

        // Если наушники отключены - ставим воспроизведение на паузу (стандарт Apple Music)
        if reason == .oldDeviceUnavailable {
            DispatchQueue.main.async { [weak self] in
                self?.logger.info("Наушники отключены (.oldDeviceUnavailable). Ставим паузу.")
                self?.wasPlayingBeforeInterruption = false
                self?.pause()
            }
        }
    }

    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        logger.info("Получено уведомление .AVAudioEngineConfigurationChange (смена оборудования/частоты дискретизации)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let wasPlaying = self.isPlaying
            let savedPosition = self.currentTime

            // Переподключаем узлы под актуальный формат оборудования/файла
            if let format = self.currentAudioFile?.processingFormat ?? self.currentFormat {
                self.connectNodes(with: format)
            }

            if wasPlaying {
                do {
                    try self.ensureEngineRunning()
                    if let file = self.currentAudioFile {
                        self.scheduleSegmentInternal(from: savedPosition, file: file, generation: self.currentGeneration)
                        self.playerNode.play()
                        self.isPlaying = true
                        self.startTimer()
                        self.logger.info("Успешно восстановлено воспроизведение после ConfigurationChange с позиции \(savedPosition)с")
                    }
                } catch {
                    self.logger.error("Ошибка перезапуска движка при ConfigurationChange: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Воспроизведение и потоковое чтение (Streaming)
    /// Подготовка аудиофайла к воспроизведению (загрузка, настройка узлов, планирование сегмента)
    func prepare(url: URL, startPosition: TimeInterval = 0.0) throws {
        // 1. Инкрементируем поколение, чтобы инвалидировать любые устаревшие completion-обработчики
        currentGeneration += 1
        let gen = currentGeneration
        logger.info("[AudioEngine.prepare] Старт подготовки gen=\(gen), file=\(url.lastPathComponent), pos=\(startPosition)s")

        // 2. Останавливаем playerNode перед сменой трека и планированием нового буфера
        if playerNode.isPlaying {
            playerNode.stop()
        } else {
            playerNode.reset()
        }
        stopTimer()

        // 3. Активируем аудиосессию
        try activateAudioSession()

        // 4. Открываем аудиофайл
        let audioFile = try AVAudioFile(forReading: url)
        self.currentAudioFile = audioFile
        self.currentFileLength = audioFile.length
        self.currentSampleRate = audioFile.processingFormat.sampleRate
        self.duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        self.hasTriggeredNearEnd = false

        let clampedPosition = max(0.0, min(startPosition, self.duration))
        self.seekTimeOffset = clampedPosition
        self.currentTime = clampedPosition

        // Обновляем выделенный ObservableObject прогресса
        PlaybackProgress.shared.duration = self.duration
        PlaybackProgress.shared.currentTime = clampedPosition

        // Переподключаем узлы, если формат отличается
        let needsReconnect = currentFormat?.sampleRate != audioFile.processingFormat.sampleRate ||
                             currentFormat?.channelCount != audioFile.processingFormat.channelCount

        if needsReconnect {
            if engine.isRunning {
                engine.stop()
            }
            connectNodes(with: audioFile.processingFormat)
        }

        try ensureEngineRunning()

        // 5. Планируем сегмент на узле playerNode с привязкой к gen
        scheduleSegmentInternal(from: clampedPosition, file: audioFile, generation: gen)

        self.isPlaying = false
        NowPlayingManager.shared.setPlaybackState(.paused)
        logger.info("[AudioEngine.prepare] Успешно подготовлен gen=\(gen), duration=\(self.duration)s")
    }

    func loadAndPlay(url: URL, startPosition: TimeInterval = 0.0) throws {
        try prepare(url: url, startPosition: startPosition)
        play()
    }

    func play() {
        guard let _ = currentAudioFile else {
            logger.warning("[AudioEngine.play] currentAudioFile == nil, запуск невозможен")
            return
        }

        do {
            try ensureEngineRunning()
        } catch {
            logger.error("[AudioEngine.play] Ошибка запуска AVAudioEngine: \(error.localizedDescription)")
            return
        }

        guard engine.isRunning else {
            logger.warning("[AudioEngine.play] engine.isRunning == false, отмена play()")
            return
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }

        isPlaying = true
        wasPlayingBeforeInterruption = false
        NowPlayingManager.shared.setPlaybackState(.playing)
        startTimer()
        logger.info("[AudioEngine.play] Воспроизведение запущено gen=\(self.currentGeneration)")
    }

    func pause() {
        pauseInternal()
    }

    private func pauseInternal() {
        wasPlayingBeforeInterruption = false
        if playerNode.isPlaying {
            playerNode.pause()
        }
        isPlaying = false
        NowPlayingManager.shared.setPlaybackState(.paused)
        stopTimer()
        logger.info("[AudioEngine.pause] Воспроизведение приостановлено gen=\(self.currentGeneration)")
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func stop() {
        currentGeneration += 1
        wasPlayingBeforeInterruption = false
        hasTriggeredNearEnd = false
        if playerNode.isPlaying {
            playerNode.stop()
        } else {
            playerNode.reset()
        }
        isPlaying = false
        currentTime = 0.0
        seekTimeOffset = 0.0
        PlaybackProgress.shared.currentTime = 0.0
        stopTimer()
        NowPlayingManager.shared.setPlaybackState(.stopped)
        logger.info("[AudioEngine.stop] Воспроизведение остановлено gen=\(self.currentGeneration)")
    }

    func seek(to time: TimeInterval) {
        guard let audioFile = currentAudioFile else { return }

        if duration > 0 && time >= (duration - 0.35) {
            seekToEndAndFinish()
            return
        }

        currentGeneration += 1
        let gen = currentGeneration

        let clampedTime = max(0.0, min(time, duration))
        seekTimeOffset = clampedTime
        currentTime = clampedTime
        PlaybackProgress.shared.currentTime = clampedTime

        let wasPlaying = isPlaying
        playerNode.stop()

        scheduleSegmentInternal(from: clampedTime, file: audioFile, generation: gen)

        if wasPlaying && engine.isRunning {
            playerNode.play()
            startTimer()
        }
        logger.info("[AudioEngine.seek] Перемотка на \(clampedTime)s gen=\(gen), wasPlaying=\(wasPlaying)")
    }

    /// Принудительное завершение трека при перемотке до упора
    func seekToEndAndFinish() {
        currentGeneration += 1
        let gen = currentGeneration
        playerNode.stop()
        seekTimeOffset = 0.0
        currentTime = 0.0
        PlaybackProgress.shared.currentTime = 0.0
        logger.info("[AudioEngine.seekToEndAndFinish] Достигнут конец трека gen=\(gen)")
        handlePlaybackEnded(generation: gen)
    }

    private func scheduleSegmentInternal(from time: TimeInterval, file: AVAudioFile, generation: Int) {
        let startFrame = AVAudioFramePosition(time * currentSampleRate)
        guard startFrame < file.length else {
            logger.info("[AudioEngine.scheduleSegment] startFrame (\(startFrame)) >= file.length (\(file.length)), завершение")
            handlePlaybackEnded(generation: generation)
            return
        }
        let frameCount = AVAudioFrameCount(file.length - startFrame)
        guard frameCount > 1000 else {
            logger.info("[AudioEngine.scheduleSegment] frameCount (\(frameCount)) <= 1000, завершение")
            handlePlaybackEnded(generation: generation)
            return
        }

        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self, capturedGen = generation] callbackType in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.logger.debug("[AudioEngine.completion] Callback gen=\(capturedGen) (текущий gen=\(self.currentGeneration)), type=\(callbackType.rawValue)")

                // Проверяем актуальность поколения: если трек уже сменился/остановлен — игнорируем
                guard capturedGen == self.currentGeneration else {
                    self.logger.info("[AudioEngine.completion] Отклонен устаревший callback gen=\(capturedGen) != current=\(self.currentGeneration)")
                    return
                }

                // Проверяем тип завершения: только реальное проигрывание данных через ЦАП
                guard callbackType == .dataPlayedBack else {
                    self.logger.info("[AudioEngine.completion] Отклонен callback != .dataPlayedBack")
                    return
                }

                guard self.isPlaying else {
                    self.logger.info("[AudioEngine.completion] Отклонен callback: плеер не в режиме воспроизведения")
                    return
                }

                self.logger.info("[AudioEngine.completion] Успешное воспроизведение до конца gen=\(capturedGen). Запуск автоперехода.")
                self.handlePlaybackEnded(generation: capturedGen)
            }
        }
    }

    private func handlePlaybackEnded(generation: Int) {
        guard generation == self.currentGeneration else { return }
        guard isPlaying else { return }

        logger.info("[AudioEngine.handlePlaybackEnded] Сигнал окончания трека gen=\(generation)")
        isPlaying = false
        stopTimer()
        seekTimeOffset = 0.0
        currentTime = 0.0
        hasTriggeredNearEnd = false
        PlaybackProgress.shared.currentTime = 0.0
        onPlaybackEnded?()
    }

    // MARK: - Синхронизация времени воспроизведения
    private func startTimer() {
        stopTimer()
        let proxy = AudioDisplayLinkProxy(target: self)
        let link = CADisplayLink(target: proxy, selector: #selector(AudioDisplayLinkProxy.onFrame))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 20)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    private func stopTimer() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Флаг перехода/жеста плеера для предотвращения лишних перерисовок UI во время анимаций (60 fps)
    var isTransitioning: Bool = false

    func updateCurrentTime() {
        if isTransitioning { return }
        guard isPlaying, let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return }

        let elapsed = Double(playerTime.sampleTime) / currentSampleRate
        let calculated = seekTimeOffset + elapsed
        if calculated >= 0 && calculated < duration {
            self.currentTime = calculated
            if !PlaybackProgress.shared.isScrubbing {
                PlaybackProgress.shared.currentTime = calculated
            }

            // Предварительная загрузка следующего трека за 4 секунды до конца
            if duration > 4.0 && (duration - calculated) <= 4.0 && !hasTriggeredNearEnd {
                hasTriggeredNearEnd = true
                onNearEnd?()
            }
        }
    }

    // MARK: - Логика эквалайзера (AVAudioUnitEQ)
    private func applyEQEnabledState() {
        equalizerNode.bypass = !isEQEnabled
    }

    func setEQGain(bandIndex: Int, gain: Float) {
        guard bandIndex >= 0 && bandIndex < 10 else { return }
        let clamped = max(-12.0, min(gain, 12.0))
        eqGains[bandIndex] = clamped
        equalizerNode.bands[bandIndex].gain = clamped
    }

    private func applyEQGains() {
        for (i, gain) in eqGains.enumerated() {
            if i < equalizerNode.bands.count {
                equalizerNode.bands[i].gain = gain
            }
        }
    }

    func applyPreset(_ preset: EQPreset) {
        guard preset.gains.count == 10 else { return }
        eqGains = preset.gains
        applyEQGains()
    }

    func resetEQ() {
        eqGains = Array(repeating: 0.0, count: 10)
        applyEQGains()
    }

    // MARK: - Логика управления скоростью и тональностью (AVAudioUnitTimePitch)
    func setPlaybackRate(_ rate: Float) {
        let clamped = max(0.5, min(rate, 2.0))
        playbackRate = (clamped * 100).rounded() / 100
    }

    func setPitchShift(_ semitones: Float) {
        let clamped = max(-12.0, min(semitones, 12.0))
        pitchShift = (clamped * 10).rounded() / 10
    }

    func incrementPitch() {
        setPitchShift(pitchShift + 1.0)
    }

    func decrementPitch() {
        setPitchShift(pitchShift - 1.0)
    }

    func resetPitch() {
        setPitchShift(0.0)
    }

    func incrementSpeed(by delta: Float = 0.05) {
        setPlaybackRate(playbackRate + delta)
    }

    func decrementSpeed(by delta: Float = 0.05) {
        setPlaybackRate(playbackRate - delta)
    }

    func resetSpeed() {
        setPlaybackRate(1.0)
    }

    func resetSpeedAndPitch() {
        playbackRate = 1.0
        pitchShift = 0.0
    }

    private func applyPlaybackRate() {
        updateTimePitchState()
    }

    private func applyPitchShift() {
        updateTimePitchState()
    }

    private func updateTimePitchState() {
        timePitchNode.overlap = 32.0
        timePitchNode.rate = playbackRate
        timePitchNode.pitch = pitchShiftCents
    }

    // MARK: - Сохранение и загрузка настроек
    private func saveEQGains() {
        let data = try? JSONEncoder().encode(eqGains)
        UserDefaults.standard.set(data, forKey: "EQ_Gains_Data")
    }

    private func loadSavedSettings() {
        if UserDefaults.standard.object(forKey: "EQ_Enabled") != nil {
            isEQEnabled = UserDefaults.standard.bool(forKey: "EQ_Enabled")
        } else {
            isEQEnabled = true
        }
        applyEQEnabledState()

        if let data = UserDefaults.standard.data(forKey: "EQ_Gains_Data"),
           let loaded = try? JSONDecoder().decode([Float].self, from: data),
           loaded.count == 10 {
            eqGains = loaded
            applyEQGains()
        }

        let savedRate = UserDefaults.standard.float(forKey: "Audio_PlaybackRate")
        if savedRate >= 0.5 && savedRate <= 2.0 {
            playbackRate = savedRate
        } else {
            playbackRate = 1.0
        }
        applyPlaybackRate()

        if UserDefaults.standard.object(forKey: "Audio_PitchShift") != nil {
            let savedPitch = UserDefaults.standard.float(forKey: "Audio_PitchShift")
            if savedPitch >= -12.0 && savedPitch <= 12.0 {
                pitchShift = savedPitch
            } else {
                pitchShift = 0.0
            }
        } else {
            pitchShift = 0.0
        }
        applyPitchShift()
    }
}

// MARK: - Proxy для безопасного вызова CADisplayLink без утечки памяти
private final class AudioDisplayLinkProxy {
    weak var target: AudioEngineManager?

    init(target: AudioEngineManager) {
        self.target = target
    }

    @objc func onFrame() {
        target?.updateCurrentTime()
    }
}

