import SwiftUI
import MediaPlayer
import AVKit

/// Калькулятор эталонных координат и пропорций экрана (база: Apple Music на iPhone 8 Plus, 414×736 pt)
struct PlayerLayoutCalculator {
    let screenW: CGFloat
    let screenH: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat

    let scale: CGFloat
    let vScale: CGFloat
    let hasNotch: Bool

    /// Кэшированная раскладка экрана для исключения пересчётов GeometryReader на каждом кадре (60 fps)
    static let standard: PlayerLayoutCalculator = {
        let screen = UIScreen.main.bounds.size
        let insets = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.safeAreaInsets ?? .zero
        return PlayerLayoutCalculator(screenSize: screen, safeAreaInsets: insets)
    }()

    init(screenSize: CGSize, safeAreaInsets: UIEdgeInsets) {
        self.screenW = screenSize.width
        self.screenH = screenSize.height
        self.topInset = safeAreaInsets.top
        self.bottomInset = safeAreaInsets.bottom
        self.hasNotch = safeAreaInsets.top > 24

        // Масштаб ширины от эталона 414 pt
        self.scale = screenSize.width / 414.0

        if hasNotch {
            let availableH = screenH - topInset - bottomInset
            let refAvailableH: CGFloat = 716.0
            self.vScale = max(0.95, availableH / refAvailableH)
        } else {
            self.vScale = screenH / 736.0
        }
    }

    init(geometry: GeometryProxy) {
        self.init(screenSize: geometry.size, safeAreaInsets: UIEdgeInsets(top: geometry.safeAreaInsets.top, left: 0, bottom: geometry.safeAreaInsets.bottom, right: 0))
    }

    func s(_ val: CGFloat) -> CGFloat { val * scale }
    func x(_ val: CGFloat) -> CGFloat { (val / 414.0) * screenW }

    func y(_ refY: CGFloat) -> CGFloat {
        if hasNotch {
            return topInset + (refY - 20.0) * vScale
        } else {
            return (refY / 736.0) * screenH
        }
    }

    var textMaxWidth: CGFloat {
        x(368) - s(14) - s(12) - x(32)
    }

    var artworkSize: CGFloat {
        s(362)
    }

    // MARK: - Геометрия дока и смещения карточки (Apple Music 60 fps)
    var miniPlayerH: CGFloat { 60.0 }
    var tabBarH: CGFloat { 56.0 }

    /// Верхний край мини-плеера на экране (от верхней границы экрана)
    var topOfMiniPlayer: CGFloat {
        screenH - bottomInset - 8.0 - tabBarH - 8.0 - miniPlayerH // screenH - bottomInset - 132.0
    }

    /// Максимальное смещение карточки вниз: в точности до верхнего края мини-плеера
    var cardMaxOffsetY: CGFloat {
        topOfMiniPlayer
    }

    /// Фрейм обложки внутри карточки при t = 1 (полноэкранный плеер)
    var fullArtworkCardFrame: CGRect {
        let size = artworkSize
        return CGRect(
            x: x(207) - size / 2.0,
            y: y(249) - size / 2.0,
            width: size,
            height: size
        )
    }

    /// Фрейм обложки внутри карточки при t = 0 (мини-плеер)
    var miniArtworkCardFrame: CGRect {
        // x = 16 (padding MainTabView) + 10 (padding MiniPlayer) + 14 (padding HStack) = 40.0 pt
        // y = 8.0 pt от верхнего края мини-плеера (верхний край карточки при t=0 совпадает с мини-плеером)
        return CGRect(x: 40.0, y: 8.0, width: 44.0, height: 44.0)
    }
}

// MARK: - Линейная интерполяция для 60 FPS переходов
@inline(__always)
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    a + (b - a) * t
}

@inline(__always)
func lerpRect(_ r1: CGRect, _ r2: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(
        x: lerp(r1.origin.x, r2.origin.x, t),
        y: lerp(r1.origin.y, r2.origin.y, t),
        width: lerp(r1.size.width, r2.size.width, t),
        height: lerp(r1.size.height, r2.size.height, t)
    )
}

// MARK: - Глобальное состояние раскрытия плеера (Один источник правды: expansion 0...1)
final class PlayerSheetState: ObservableObject {
    static let shared = PlayerSheetState()

    /// Текущий прогресс раскрытия: 0.0 (свёрнут в мини-плеер) ... 1.0 (полностью развёрнут)
    @Published var expansion: CGFloat = 0.0

    /// Флаг выполнения программной анимации пружины (во время неё жесты блокируются)
    @Published var isAnimating: Bool = false

    private init() {}

    /// Плавная анимация к целевому состоянию с эталонной пружиной Apple Music
    func animate(to target: CGFloat, completion: (() -> Void)? = nil) {
        let clampedTarget = min(max(target, 0.0), 1.0)
        guard !isAnimating else { return }

        isAnimating = true
        AudioEngineManager.shared.isTransitioning = true

        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            self.expansion = clampedTarget
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.44) {
            self.isAnimating = false
            AudioEngineManager.shared.isTransitioning = false
            AudioEngineManager.shared.updateCurrentTime()
            PlayerViewModel.shared.showFullScreenPlayer = (clampedTarget > 0.5)
            completion?()
        }
    }

    /// Прямая установка значения во время интерактивного жеста (без анимации)
    func setDirect(_ value: CGFloat) {
        guard !isAnimating else { return }
        if !AudioEngineManager.shared.isTransitioning {
            AudioEngineManager.shared.isTransitioning = true
        }
        self.expansion = min(max(value, 0.0), 1.0)
    }

    /// Завершение жеста смахивания полноэкранного плеера вниз
    func endDrag(translationH: CGFloat, predictedH: CGFloat) {
        guard !isAnimating else { return }
        let target: CGFloat = (translationH > 120.0 || predictedH > 300.0) ? 0.0 : 1.0
        animate(to: target)
    }

    /// Завершение жеста вытягивания мини-плеера вверх
    func endDragUp(dy: CGFloat, predictedDy: CGFloat) {
        guard !isAnimating else { return }
        let target: CGFloat = (dy > 60.0 || predictedDy > 150.0) ? 1.0 : 0.0
        animate(to: target)
    }
}

/// Полноэкранный плеер в аутентичном стиле Apple Music (iOS 16+)
/// Точная копия нативного плеера Apple Music один в один
struct FullScreenPlayerView: View {
    @ObservedObject var playerVM = PlayerViewModel.shared
    @ObservedObject var sheetState = PlayerSheetState.shared
    @ObservedObject private var coverManager = AnimatedCoverManager.shared
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(\.scenePhase) private var scenePhase

    var onClose: () -> Void

    // Модальные экраны
    @State private var showEditTrackSheet: Bool = false
    @State private var showQueueSheet: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var showSoundCloudSheet: Bool = false
    @State private var showAddToPlaylistSheet: Bool = false
    @State private var showSpeedAndPitchSheet: Bool = false
    @State private var targetAlbum: Album? = nil

    var body: some View {
        let layout = PlayerLayoutCalculator.standard
        let screenH = layout.screenH
        let maxOffset = layout.cardMaxOffsetY

        // t = expansion: 0 (свёрнут) ... 1 (развёрнут)
        let t = min(max(sheetState.expansion, 0.0), 1.0)

        // 1. Карточка плеера:
        // В момент нажатия верхний край карточки совпадает с верхним краем мини-плеера
        // offsetY = (1 − t) × topOfMiniPlayer
        let cardOffsetY = (1.0 - t) * maxOffset

        // Скругление углов = 38 × (1 − t), стиль .continuous
        let cardRadius = 38.0 * (1.0 - t)

        // Содержимое карточки проявляется только во второй половине: clamp((t − 0.55) / 0.45, 0, 1)
        let controlsOpacity = min(max((t - 0.55) / 0.45, 0.0), 1.0)

        // 2. Обложка лежит ВНУТРИ карточки и едет вместе с ней:
        // frame = lerp(miniCardFrame, fullCardFrame, t)
        let currentArtworkFrame = lerpRect(layout.miniArtworkCardFrame, layout.fullArtworkCardFrame, t)
        let artworkCornerRadius = lerp(6.0, 12.0, t)

        let isPausedInFull = !playerVM.isPlaying && t > 0.95
        let playPauseScale: CGFloat = isPausedInFull ? 0.86 : 1.0

        let animatedCoverURL = playerVM.currentTrack?.resolvedAnimatedCoverURL(in: libraryStore)
        let showVideo = (t >= 0.99 && !sheetState.isAnimating && animatedCoverURL != nil && coverManager.canPlayAnimation)

        ZStack(alignment: .topLeading) {
            // 1. Верхний захватчик (pill/capsule 36×5 pt)
            grabberCapsule(layout: layout)
                .opacity(controlsOpacity)

            // 2. Обложка лежит ВНУТРИ карточки и едет вместе с ней (единый слой, без рассинхрона)
            ZStack {
                ArtworkView(
                    data: playerVM.currentTrack?.resolvedArtworkData(in: libraryStore),
                    cornerRadius: artworkCornerRadius,
                    targetPixelSize: 800,
                    placeholderBackground: Color(white: 0.18),
                    placeholderSymbolColor: Color.white.opacity(0.60)
                )
                .id(playerVM.currentTrack?.id)

                if showVideo, let url = animatedCoverURL {
                    AnimatedCoverPlayerView(
                        url: url,
                        cornerRadius: artworkCornerRadius,
                        isPlaying: playerVM.isPlaying
                    )
                    .transition(.opacity)
                }
            }
            .frame(width: currentArtworkFrame.width, height: currentArtworkFrame.height)
            .scaleEffect(playPauseScale)
            .animation(.spring(response: 0.42, dampingFraction: 0.88), value: playerVM.isPlaying)
            .shadow(
                color: Color.black.opacity(lerp(0.18, 0.30, t)),
                radius: lerp(4.0, 14.0, t),
                x: 0,
                y: lerp(2.0, 7.0, t)
            )
            .position(
                x: currentArtworkFrame.midX,
                y: currentArtworkFrame.midY
            )

            // Контролы, которые плавно проявляются во второй половине анимации: clamp((t − 0.55) / 0.45, 0, 1)
            Group {
                // 3. Название, исполнитель и круглая кнопка меню «•••»
                trackMetadataSection(layout: layout)

                // 4. Прогресс-бар и метки времени (изолирован от частых перерисовок плеера)
                IsolatedScrubberSection(layout: layout)

                // 5. Кнопки воспроизведения: назад, play/pause, вперёд
                controlsSection(layout: layout)

                // 6. Ползунок громкости со значками динамиков
                volumeSection(layout: layout)

                // 7. Нижний ряд: цитата/тональность, AirPlay, очередь
                bottomRowSection(layout: layout)
            }
            .compositingGroup()
            .opacity(controlsOpacity)
        }
        .frame(width: layout.screenW, height: layout.screenH)
        .background(
            ZStack {
                Color(red: 0.12, green: 0.12, blue: 0.14)
                BlurredArtworkBackground(
                    trackId: playerVM.currentTrack?.id,
                    artworkData: playerVM.currentTrack?.resolvedArtworkData(in: libraryStore)
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .offset(y: cardOffsetY)
        .shadow(color: Color.black.opacity(0.30 * t), radius: 12, x: 0, y: 6)
        .opacity(t > 0 ? 1.0 : 0.0)
        .allowsHitTesting(t > 0.5 && !sheetState.isAnimating)
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    guard !sheetState.isAnimating else { return }
                    if value.translation.height > 0 && abs(value.translation.height) > abs(value.translation.width) {
                        let dragProgress = min(max(value.translation.height / (screenH * 0.6), 0.0), 1.0)
                        sheetState.setDirect(1.0 - dragProgress)
                    }
                }
                .onEnded { value in
                    guard !sheetState.isAnimating else { return }
                    let translationH = value.translation.height
                    let predictedH = value.predictedEndTranslation.height
                    sheetState.endDrag(translationH: translationH, predictedH: predictedH)
                }
        )
        .ignoresSafeArea()
        // Модальное окно редактирования трека
        .sheet(isPresented: $showEditTrackSheet) {
            if let track = playerVM.currentTrack {
                EditTrackView(track: track)
                    .environmentObject(libraryStore)
            }
        }
        // Модальное окно очереди «Далее»
        .sheet(isPresented: $showQueueSheet) {
            QueueView()
        }
        // Модальное окно перехода к альбому
        .sheet(item: $targetAlbum) { album in
            NavigationStack {
                AlbumDetailView(album: album)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Закрыть") {
                                targetAlbum = nil
                            }
                        }
                    }
            }
        }
        // Подтверждение удаления трека
        .alert("Удалить из медиатеки?", isPresented: $showDeleteConfirmation) {
            Button("Удалить", role: .destructive) {
                if let track = playerVM.currentTrack {
                    libraryStore.deleteTrack(track)
                    if playerVM.queue.isEmpty {
                        dismissPlayer()
                    }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Песня «\(playerVM.currentTrack?.title ?? "")» будет удалена из медиатеки приложения.")
        }
        // Модальное окно импорта из SoundCloud
        .sheet(isPresented: $showSoundCloudSheet) {
            SoundCloudImportSheet()
                .environmentObject(libraryStore)
        }
        // Модальное окно добавления в плейлист
        .sheet(isPresented: $showAddToPlaylistSheet) {
            if let track = playerVM.currentTrack {
                AddToPlaylistSheet(track: track)
                    .environmentObject(libraryStore)
            }
        }
        // Модальное окно тональности и скорости
        .sheet(isPresented: $showSpeedAndPitchSheet) {
            SpeedAndPitchSheet()
        }
        .onDisappear {
            AnimatedCoverPlaybackCoordinator.shared.stopAndRelease()
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                AnimatedCoverPlaybackCoordinator.shared.stopAndRelease()
            }
        }
        .onChange(of: sheetState.expansion) { exp in
            if exp < 0.95 {
                AnimatedCoverPlaybackCoordinator.shared.stopAndRelease()
            }
        }
    }

    // MARK: - Подкомпоненты раскладки

    /// 2. Захватчик (capsule): ширина 36, высота 5, центр x=207, y=34.5, белый 35%
    private func grabberCapsule(layout: PlayerLayoutCalculator) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.35))
            .frame(width: layout.s(36), height: layout.s(5))
            .contentShape(Rectangle())
            .onTapGesture {
                onClose()
            }
            .position(x: layout.x(207), y: layout.y(34.5))
    }

    /// 4. Название трека, исполнитель и кнопка «•••»
    @ViewBuilder
    private func trackMetadataSection(layout: PlayerLayoutCalculator) -> some View {
        let maxW = layout.textMaxWidth

        // Название: x=32, Y центра ≈ 466, 22 pt bold, белый 100%
        MarqueeText(
            text: playerVM.currentTrack?.title ?? "Нет трека",
            font: .system(size: layout.s(22), weight: .bold),
            color: .white,
            maxWidth: maxW
        )
        .frame(width: maxW, height: layout.s(28), alignment: .leading)
        .position(x: layout.x(32) + maxW / 2.0, y: layout.y(466))

        // Исполнитель: x=32, Y центра ≈ 492, 20 pt regular, белый 60%
        Text(playerVM.currentTrack?.artist ?? "Неизвестный исполнитель")
            .font(.system(size: layout.s(20), weight: .regular))
            .foregroundStyle(Color.white.opacity(0.60))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: maxW, height: layout.s(26), alignment: .leading)
            .position(x: layout.x(32) + maxW / 2.0, y: layout.y(492))

        // Кнопка «•••»: диаметр 28, центр x=368, y=478, полупрозрачный фон белый 20%
        Menu {
            if let track = playerVM.currentTrack {
                let isFav = libraryStore.isTrackFavorite(track)
                Button(action: {
                    _ = libraryStore.toggleFavorite(for: track)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }) {
                    Label(
                        isFav ? "Удалить из избранного" : "Добавить в избранное",
                        systemImage: isFav ? "heart.slash" : "heart"
                    )
                }

                Button(action: { showSpeedAndPitchSheet = true }) {
                    Label("Тональность и скорость", systemImage: "slider.horizontal.2.square")
                }

                Button(action: { showEditTrackSheet = true }) {
                    Label("Изменить информацию", systemImage: "pencil")
                }

                Button(action: { openCurrentAlbum() }) {
                    Label("Перейти к альбому", systemImage: "square.stack")
                }

                Button(action: { playerVM.addToQueue(track) }) {
                    Label("Добавить в очередь", systemImage: "text.badge.plus")
                }

                Button(action: { showAddToPlaylistSheet = true }) {
                    Label("Добавить в плейлист…", systemImage: "music.note.list")
                }

                Button(action: { showSoundCloudSheet = true }) {
                    Label("Импорт из SoundCloud (MP3 320)", systemImage: "arrow.down.circle")
                }

                Divider()

                Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                    Label("Удалить из медиатеки", systemImage: "trash")
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.20))
                    .frame(width: layout.s(28), height: layout.s(28))

                Image(systemName: "ellipsis")
                    .font(.system(size: layout.s(13), weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: layout.s(44), height: layout.s(44))
            .contentShape(Rectangle())
        }
        .position(x: layout.x(368), y: layout.y(478))
    }

    /// 6. Кнопки управления (центры Y ≈ 582)
    @ViewBuilder
    private func controlsSection(layout: PlayerLayoutCalculator) -> some View {
        // Назад (x ≈ 108, 32 pt)
        HoldableSeekButton(
            iconName: "backward.fill",
            fontSize: layout.s(32),
            circleSize: layout.s(56),
            isForward: false,
            onTap: { playerVM.playPrevious() }
        )
        .position(x: layout.x(108), y: layout.y(582))

        // Play / Pause (x ≈ 207, 40 pt)
        Button(action: { playerVM.togglePlayPause() }) {
            Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: layout.s(40), weight: .bold))
                .foregroundStyle(.white)
                .frame(width: layout.s(68), height: layout.s(68))
        }
        .buttonStyle(AppleMusicTransportButtonStyle(size: layout.s(68)))
        .position(x: layout.x(207), y: layout.y(582))

        // Вперёд (x ≈ 306, 32 pt)
        HoldableSeekButton(
            iconName: "forward.fill",
            fontSize: layout.s(32),
            circleSize: layout.s(56),
            isForward: true,
            onTap: { playerVM.playNext() }
        )
        .position(x: layout.x(306), y: layout.y(582))
    }

    /// 7. Громкость, Y центра ≈ 644
    @ViewBuilder
    private func volumeSection(layout: PlayerLayoutCalculator) -> some View {
        // Иконка динамика слева (центр x ≈ 39, 16 pt, белый 50%)
        Image(systemName: "speaker.fill")
            .font(.system(size: layout.s(16)))
            .foregroundStyle(Color.white.opacity(0.50))
            .frame(width: layout.s(24), height: layout.s(24))
            .position(x: layout.x(39), y: layout.y(644))

        // Полоса громкости (от x=63 до x=348, ширина 285, центр 205.5)
        AppleMusicVolumeSlider(
            height: layout.s(7),
            expandedHeight: layout.s(11)
        )
        .frame(width: layout.s(285), height: layout.s(28))
        .position(x: layout.x(205.5), y: layout.y(644))

        // Иконка динамика справа (центр x ≈ 369, 16 pt, белый 50%)
        Image(systemName: "speaker.wave.3.fill")
            .font(.system(size: layout.s(16)))
            .foregroundStyle(Color.white.opacity(0.50))
            .frame(width: layout.s(24), height: layout.s(24))
            .position(x: layout.x(369), y: layout.y(644))
    }

    /// 8. Нижний ряд иконок, Y центра ≈ 692, белый 50%
    @ViewBuilder
    private func bottomRowSection(layout: PlayerLayoutCalculator) -> some View {
        // Слева (x ≈ 105): Избранное («Нравится») — сердце
        let isFavorite = playerVM.currentTrack.map { libraryStore.isTrackFavorite($0) } ?? false
        Button(action: {
            guard let track = playerVM.currentTrack else { return }
            let isNowLiked = libraryStore.toggleFavorite(for: track)
            UIImpactFeedbackGenerator(style: isNowLiked ? .medium : .light).impactOccurred()
        }) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: layout.s(22), weight: .semibold))
                .foregroundStyle(isFavorite ? Color.red : Color.white.opacity(0.50))
                .frame(width: layout.s(44), height: layout.s(44))
                .scaleEffect(isFavorite ? 1.05 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isFavorite)
        }
        .position(x: layout.x(105), y: layout.y(692))

        // По центру (x ≈ 207): AirPlay
        AirPlayButtonView(
            tintColor: UIColor.white.withAlphaComponent(0.50),
            activeTintColor: .white
        )
        .frame(width: layout.s(44), height: layout.s(44))
        .position(x: layout.x(207), y: layout.y(692))

        // Справа (x ≈ 309): очередь «Далее» (list.bullet)
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showQueueSheet = true
        }) {
            Image(systemName: "list.bullet")
                .font(.system(size: layout.s(24), weight: .medium))
                .foregroundStyle(Color.white.opacity(0.50))
                .frame(width: layout.s(44), height: layout.s(44))
        }
        .position(x: layout.x(309), y: layout.y(692))
    }

    private func dismissPlayer() {
        onClose()
    }

    private func openCurrentAlbum() {
        guard let current = playerVM.currentTrack else { return }
        if let found = libraryStore.albums.first(where: {
            $0.title.caseInsensitiveCompare(current.albumName) == .orderedSame
        }) {
            targetAlbum = found
        }
    }
}

// MARK: - Изолированная секция скруббера (100% плавная, без задержек и лагов)
struct IsolatedScrubberSection: View {
    @ObservedObject private var progress = PlaybackProgress.shared
    let layout: PlayerLayoutCalculator

    var body: some View {
        AppleMusicScrubber(
            currentTime: progress.currentTime,
            duration: max(1.0, progress.duration),
            barHeight: layout.s(7),
            expandedBarHeight: layout.s(11),
            width: layout.s(350),
            onSeek: { targetTime in
                progress.isScrubbing = false
                progress.currentTime = targetTime
                PlayerViewModel.shared.seek(to: targetTime)
            }
        )
        .frame(width: layout.s(350), height: layout.s(42))
        .position(x: layout.x(207), y: layout.y(525))
    }
}

// MARK: - Бегущая строка (MarqueeText)
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let maxWidth: CGFloat

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var isAnimating: Bool = false
    @State private var timer: Timer? = nil

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: MarqueeTextWidthKey.self, value: geo.size.width)
                    }
                )
                .hidden()

            if textWidth > maxWidth && maxWidth > 0 {
                HStack(spacing: 48) {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()

                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()
                }
                .offset(x: offset)
            } else {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .frame(width: maxWidth, alignment: .leading)
            }
        }
        .frame(width: maxWidth, alignment: .leading)
        .clipped()
        .onPreferenceChange(MarqueeTextWidthKey.self) { newWidth in
            textWidth = newWidth
            restartMarquee()
        }
        .onChange(of: text) { _ in
            restartMarquee()
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func restartMarquee() {
        timer?.invalidate()
        timer = nil
        offset = 0
        isAnimating = false

        guard textWidth > maxWidth && maxWidth > 0 else { return }

        let distance = textWidth + 48
        let duration = Double(distance) / 28.0

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            isAnimating = true
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                offset = -distance
            }
        }
    }
}

private struct MarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Прогресс-бар в стиле Apple Music (capsule, 7 pt -> 11 pt при касании, 60/120 FPS, 0 лагов)
struct AppleMusicScrubber: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let barHeight: CGFloat
    let expandedBarHeight: CGFloat
    let width: CGFloat
    let onSeek: (TimeInterval) -> Void

    @State private var isDragging: Bool = false
    @State private var dragProgress: Double? = nil
    @State private var dragTime: TimeInterval? = nil

    var body: some View {
        let activeProgress = dragProgress ?? (duration > 0 ? max(0.0, min(1.0, currentTime / duration)) : 0.0)
        let displayTime = dragTime ?? currentTime
        let currentBarHeight: CGFloat = isDragging ? expandedBarHeight : barHeight

        VStack(spacing: 6) {
            // 1. Полоса
            ZStack(alignment: .leading) {
                // Подложка 25%
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: width, height: currentBarHeight)

                // Заполнение 70% (100% при перетаскивании)
                let fillWidth = max(0.0, min(width, width * CGFloat(activeProgress)))
                Capsule()
                    .fill(Color.white.opacity(isDragging ? 1.0 : 0.70))
                    .frame(width: max(currentBarHeight, fillWidth), height: currentBarHeight)
                    .opacity(fillWidth > 0 ? 1.0 : 0.0)
                    .animation(nil, value: fillWidth)
            }
            .frame(width: width, height: expandedBarHeight)
            .animation(.spring(response: 0.20, dampingFraction: 0.75), value: isDragging)
            .contentShape(Rectangle().inset(by: -10))
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        let clampedX = max(0.0, min(width, gesture.location.x))
                        let percent = Double(clampedX / width)
                        dragProgress = percent
                        dragTime = percent * max(1.0, duration)
                    }
                    .onEnded { gesture in
                        let clampedX = max(0.0, min(width, gesture.location.x))
                        let percent = Double(clampedX / width)
                        let finalTime = percent * max(1.0, duration)

                        isDragging = false
                        dragProgress = nil
                        dragTime = nil
                        onSeek(finalTime)
                    }
            )

            // 2. Метки времени
            HStack {
                Text(PlaybackProgress.formatTime(displayTime))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.50))

                Spacer()

                let rem = max(0, duration - displayTime)
                Text("−" + PlaybackProgress.formatTime(rem))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.50))
            }
            .frame(width: width, height: 16)
        }
        .frame(width: width, height: 42)
    }
}

// MARK: - Ползунок громкости в стиле Apple Music (capsule, 7 pt -> 11 pt при касании, синхронизация с системой)
struct AppleMusicVolumeSlider: View {
    let height: CGFloat
    let expandedHeight: CGFloat

    @ObservedObject var playerVM = PlayerViewModel.shared
    @State private var isInteracting: Bool = false
    @State private var volumeSlider: UISlider?
    @State private var audioSessionObserver: NSKeyValueObservation?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = max(0.0, min(1.0, playerVM.volume))
            let currentBarHeight = isInteracting ? expandedHeight : height

            ZStack(alignment: .leading) {
                // Фоновый MPVolumeView для изменения реальной системной громкости
                HiddenSystemVolumeView(volumeSlider: $volumeSlider)
                    .frame(width: 1, height: 1)
                    .opacity(0.0001)

                // Трек белый 25%
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: currentBarHeight)

                // Заполнение белый 70% (100% при касании)
                let fillWidth = max(0.0, min(width, width * CGFloat(clamped)))
                if fillWidth > 0 {
                    Capsule()
                        .fill(Color.white.opacity(isInteracting ? 1.0 : 0.70))
                        .frame(width: max(currentBarHeight, fillWidth), height: currentBarHeight)
                }
            }
            .frame(height: currentBarHeight)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isInteracting {
                            isInteracting = true
                        }
                        let percent = max(0.0, min(1.0, gesture.location.x / width))
                        playerVM.volume = Double(percent)
                        volumeSlider?.setValue(Float(percent), animated: false)
                    }
                    .onEnded { _ in
                        isInteracting = false
                    }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isInteracting)
        }
        .onAppear {
            let sysVol = AVAudioSession.sharedInstance().outputVolume
            if sysVol > 0 {
                playerVM.volume = Double(sysVol)
            }
            audioSessionObserver = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { _, change in
                guard let newVol = change.newValue else { return }
                DispatchQueue.main.async {
                    if !isInteracting {
                        playerVM.volume = Double(newVol)
                    }
                }
            }
        }
        .onDisappear {
            audioSessionObserver?.invalidate()
            audioSessionObserver = nil
        }
    }
}

// MARK: - Скрытый MPVolumeView для получения ссылки на системный UISlider
private struct HiddenSystemVolumeView: UIViewRepresentable {
    @Binding var volumeSlider: UISlider?

    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 1, height: 1))
        volumeView.clipsToBounds = true
        volumeView.alpha = 0.0001
        DispatchQueue.main.async {
            for subview in volumeView.subviews {
                if let slider = subview as? UISlider {
                    self.volumeSlider = slider
                    break
                }
            }
        }
        return volumeView
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - ButtonStyle кнопок воспроизведения (scale 0.88 и круг-подсветка 15%)
struct AppleMusicTransportButtonStyle: ButtonStyle {
    var size: CGFloat = 64

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.15))
                .frame(width: size, height: size)
                .scaleEffect(configuration.isPressed ? 1.0 : 0.6)
                .opacity(configuration.isPressed ? 1.0 : 0.0)

            configuration.label
                .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
        }
        .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Кнопка с поддержкой перемотки при удержании (HoldableSeekButton)
struct HoldableSeekButton: View {
    let iconName: String
    let fontSize: CGFloat
    let circleSize: CGFloat
    let isForward: Bool
    let onTap: () -> Void

    @ObservedObject var playerVM = PlayerViewModel.shared
    @State private var isHolding: Bool = false
    @State private var holdTimer: Timer? = nil

    var body: some View {
        Button(action: {
            if !isHolding {
                onTap()
            }
        }) {
            Image(systemName: iconName)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: circleSize, height: circleSize)
        }
        .buttonStyle(AppleMusicTransportButtonStyle(size: circleSize))
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if holdTimer == nil {
                        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.40, repeats: false) { _ in
                            DispatchQueue.main.async {
                                self.isHolding = true
                                self.startContinuousSeeking()
                            }
                        }
                    }
                }
                .onEnded { _ in
                    stopSeeking()
                }
        )
    }

    private func startContinuousSeeking() {
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            DispatchQueue.main.async {
                let step: TimeInterval = self.isForward ? 1.5 : -1.5
                let newTime = max(0, min(PlaybackProgress.shared.duration, PlaybackProgress.shared.currentTime + step))
                self.playerVM.seek(to: newTime)
            }
        }
    }

    private func stopSeeking() {
        holdTimer?.invalidate()
        holdTimer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            self.isHolding = false
        }
    }
}
