import SwiftUI

/// Экран деталей альбома в стиле Apple Music с возможностью редактирования (iOS 16+)
struct AlbumDetailView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let album: Album

    @ObservedObject var playerVM = PlayerViewModel.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var sheetState = PlayerSheetState.shared
    @ObservedObject private var coverManager = AnimatedCoverManager.shared

    @State private var showEditAlbumSheet: Bool = false
    @State private var trackToEdit: Track? = nil
    @State private var showDeleteConfirmation: Bool = false

    /// Динамическое получение актуального состояния альбома из хранилища
    var currentAlbum: Album {
        libraryStore.albums.first(where: { $0.id == album.id }) ?? album
    }

    var sortedTracks: [Track] {
        currentAlbum.tracks.sorted {
            if $0.trackNumber != $1.trackNumber {
                return $0.trackNumber < $1.trackNumber
            }
            return $0.title < $1.title
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Шапка альбома с обложкой
                VStack(spacing: 12) {
                    ZStack {
                        ArtworkView(data: currentAlbum.resolvedArtworkData, cornerRadius: 16, targetPixelSize: 1000)

                        if let url = currentAlbum.resolvedAnimatedCoverURL,
                           coverManager.canPlayAnimation,
                           sheetState.expansion < 0.1 {
                            AnimatedCoverPlayerView(
                                url: url,
                                cornerRadius: 16,
                                isPlaying: true
                            )
                        }
                    }
                    .frame(width: 220, height: 220)
                    .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 8)

                    Text(currentAlbum.title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Text(currentAlbum.artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    Text("\(currentAlbum.formattedTrackCount) • \(currentAlbum.formattedDuration)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)

                // Кнопки «Слушать» и «Перемешать»
                HStack(spacing: 16) {
                    Button(action: {
                        playerVM.logger.info("[AlbumDetailView] Нажатие «Слушать» для альбома '\(currentAlbum.title)'")
                        playerVM.playAlbum(currentAlbum, shuffle: false)
                    }) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Слушать")
                        }
                        .font(.headline)
                        .foregroundStyle(themeManager.contrastForegroundColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(themeManager.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    Button(action: {
                        playerVM.logger.info("[AlbumDetailView] Нажатие «Перемешать» для альбома '\(currentAlbum.title)'")
                        playerVM.playAlbum(currentAlbum, shuffle: true)
                    }) {
                        HStack {
                            Image(systemName: "shuffle")
                            Text("Перемешать")
                        }
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(uiColor: .secondarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.horizontal)

                Divider()
                    .padding(.horizontal)

                // Список треков альбома
                LazyVStack(spacing: 12) {
                    ForEach(Array(sortedTracks.enumerated()), id: \.element.id) { index, track in
                        TrackRowView(
                            track: track,
                            showTrackNumber: true,
                            trackIndex: index + 1,
                            isCurrentTrack: playerVM.currentTrack?.id == track.id,
                            isPlaying: playerVM.isPlaying,
                            onPlay: {
                                playerVM.logger.info("[AlbumDetailView] Тап по треку '\(track.title)', id=\(track.id)")
                                playerVM.playAlbum(currentAlbum, startingFrom: track, shuffle: false)
                            },
                            onEdit: {
                                trackToEdit = track
                            },
                            onAddToQueue: {
                                playerVM.addToQueue(track)
                            },
                            onDelete: {
                                deleteTrack(track)
                            }
                        )
                        .padding(.horizontal)

                        if index < sortedTracks.count - 1 {
                            Divider()
                                .padding(.leading, 50)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: playerVM.currentTrack != nil ? 144 : 76)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: { showEditAlbumSheet = true }) {
                        Label("Изменить альбом", systemImage: "pencil")
                    }

                    Divider()

                    Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                        Label("Удалить альбом", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(themeManager.accentColor)
                }
            }
        }
        // Модальное окно редактирования альбома
        .sheet(isPresented: $showEditAlbumSheet) {
            EditAlbumView(album: currentAlbum)
                .environmentObject(libraryStore)
        }
        // Модальное окно редактирования отдельного трека
        .sheet(item: $trackToEdit) { track in
            EditTrackView(track: track)
                .environmentObject(libraryStore)
        }
        // Подтверждение удаления альбома
        .alert("Удалить альбом?", isPresented: $showDeleteConfirmation) {
            Button("Удалить", role: .destructive) {
                libraryStore.deleteAlbum(currentAlbum)
                dismiss()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все треки альбома «\(currentAlbum.title)» будут удалены из медиатеки.")
        }
    }

    private func deleteTrack(_ track: Track) {
        if playerVM.currentTrack?.id == track.id {
            playerVM.pause()
            playerVM.currentTrack = nil
        }
        libraryStore.deleteTrack(track)
    }
}
