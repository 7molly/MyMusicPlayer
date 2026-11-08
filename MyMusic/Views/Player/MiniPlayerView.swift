import SwiftUI

/// Компактный мини-плеер, закреплённый над нижним TabBar в стиле Apple Music
struct MiniPlayerView: View {
    let track: Track
    @ObservedObject var playerVM = PlayerViewModel.shared
    @ObservedObject var sheetState = PlayerSheetState.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @EnvironmentObject private var libraryStore: LibraryStore

    var onTap: () -> Void

    var body: some View {
        let t = sheetState.expansion
        // Мини-плеер плавно исчезает за первые 35% движения
        let miniBgOpacity = min(max((0.35 - t) / 0.35, 0.0), 1.0)
        let textOpacity = min(max((0.30 - t) / 0.30, 0.0), 1.0)

        HStack(spacing: 12) {
            // Миниатюра в мини-плеере видна ТОЛЬКО при t == 0, в первом же кадре анимации скрывается
            ArtworkView(
                data: track.resolvedArtworkData(in: libraryStore),
                cornerRadius: 6,
                targetPixelSize: 120
            )
            .id(track.id)
            .frame(width: 44, height: 44)
            .opacity(t == 0.0 ? 1.0 : 0.0)

            // Название и исполнитель: гаснут за первые 30% анимации
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .opacity(textOpacity)

                Spacer(minLength: 8)

                // Кнопка Play/Pause
                Button(action: {
                    playerVM.togglePlayPause()
                }) {
                    Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .opacity(textOpacity)

                // Кнопка Next
                Button(action: {
                    playerVM.playNext()
                }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .opacity(textOpacity)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 4)
                    .opacity(miniBgOpacity)
            )
            .contentShape(Rectangle())
            .allowsHitTesting(t < 0.1 && !sheetState.isAnimating)
            .onTapGesture {
                onTap()
            }
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        guard !sheetState.isAnimating else { return }
                        if value.translation.height < 0 && abs(value.translation.height) > abs(value.translation.width) {
                            let screenH = PlayerLayoutCalculator.standard.screenH
                            let dragProgress = min(max(-value.translation.height / (screenH * 0.5), 0.0), 1.0)
                            sheetState.setDirect(dragProgress)
                        }
                    }
                    .onEnded { value in
                        guard !sheetState.isAnimating else { return }
                        let dy = -value.translation.height
                        let predictedDy = -value.predictedEndTranslation.height
                        sheetState.endDragUp(dy: dy, predictedDy: predictedDy)
                    }
            )
            .padding(.horizontal, 10)
    }
}
