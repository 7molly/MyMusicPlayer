import SwiftUI
import AVFoundation

// MARK: - UIView с прикреплённым AVPlayerLayer
final class AnimatedCoverPlayerUIView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

// MARK: - Представление анимированной обложки для полноэкранного плеера
/// Использует единый AVQueuePlayer + AVPlayerLooper из AnimatedCoverPlaybackCoordinator
struct AnimatedCoverPlayerView: View {
    let url: URL
    let cornerRadius: CGFloat
    let isPlaying: Bool

    @ObservedObject private var coordinator = AnimatedCoverPlaybackCoordinator.shared
    @ObservedObject private var manager = AnimatedCoverManager.shared

    var body: some View {
        Representable(url: url, isPlaying: isPlaying)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onAppear {
                if manager.canPlayAnimation {
                    coordinator.play(url: url)
                    if !isPlaying {
                        coordinator.pause()
                    }
                }
            }
            .onChange(of: isPlaying) { playing in
                if playing {
                    if manager.canPlayAnimation {
                        coordinator.play(url: url)
                    }
                } else {
                    coordinator.pause()
                }
            }
            .onChange(of: url) { newURL in
                if manager.canPlayAnimation {
                    coordinator.play(url: newURL)
                    if !isPlaying {
                        coordinator.pause()
                    }
                }
            }
            .onDisappear {
                coordinator.stopAndRelease()
            }
    }

    private struct Representable: UIViewRepresentable {
        let url: URL
        let isPlaying: Bool

        func makeUIView(context: Context) -> AnimatedCoverPlayerUIView {
            let view = AnimatedCoverPlayerUIView(frame: .zero)
            if let p = AnimatedCoverPlaybackCoordinator.shared.player {
                view.playerLayer.player = p
            }
            return view
        }

        func updateUIView(_ uiView: AnimatedCoverPlayerUIView, context: Context) {
            if uiView.playerLayer.player !== AnimatedCoverPlaybackCoordinator.shared.player {
                uiView.playerLayer.player = AnimatedCoverPlaybackCoordinator.shared.player
            }
        }
    }
}

// MARK: - Локальное зацикленное превью для экранов редактирования
/// Изолированный плеер для предпросмотра выбранного видео в EditTrackView / EditAlbumView
struct MiniAnimatedCoverPreviewView: View {
    let url: URL
    var cornerRadius: CGFloat = 10
    var size: CGFloat = 80

    @State private var localPlayer: AVQueuePlayer?
    @State private var localLooper: AVPlayerLooper?

    var body: some View {
        LocalPlayerRepresentable(player: localPlayer)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onAppear {
                setupPlayer()
            }
            .onDisappear {
                tearDownPlayer()
            }
            .onChange(of: url) { _ in
                tearDownPlayer()
                setupPlayer()
            }
    }

    private func setupPlayer() {
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .none

        self.localLooper = AVPlayerLooper(player: player, templateItem: item)
        self.localPlayer = player
        player.play()
    }

    private func tearDownPlayer() {
        localPlayer?.pause()
        localLooper?.disableLooping()
        localLooper = nil
        localPlayer?.removeAllItems()
        localPlayer = nil
    }

    private struct LocalPlayerRepresentable: UIViewRepresentable {
        let player: AVQueuePlayer?

        func makeUIView(context: Context) -> AnimatedCoverPlayerUIView {
            let view = AnimatedCoverPlayerUIView(frame: .zero)
            view.playerLayer.player = player
            return view
        }

        func updateUIView(_ uiView: AnimatedCoverPlayerUIView, context: Context) {
            if uiView.playerLayer.player !== player {
                uiView.playerLayer.player = player
            }
        }
    }
}
