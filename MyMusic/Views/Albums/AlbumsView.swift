import SwiftUI

/// Экран «Альбомы» с сеткой обложек в 2 колонки (iOS 16+)
struct AlbumsView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @ObservedObject var playerVM = PlayerViewModel.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var searchText: String = ""

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var allAlbums: [Album] {
        libraryStore.albums.sorted { $0.dateAdded > $1.dateAdded }
    }

    var filteredAlbums: [Album] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return allAlbums
        } else {
            return allAlbums.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.artist.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if allAlbums.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "square.stack.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(themeManager.accentColor)

                        Text("Нет альбомов")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("Импортируйте папку с треками или аудиофайлы в медиатеке, и альбомы сформируются автоматически.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(filteredAlbums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                AlbumCardView(album: album)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(action: {
                                    playerVM.playAlbum(album, shuffle: false)
                                }) {
                                    Label("Слушать", systemImage: "play.fill")
                                }

                                Button(action: {
                                    playerVM.playAlbum(album, shuffle: true)
                                }) {
                                    Label("Перемешать", systemImage: "shuffle")
                                }

                                Button(role: .destructive, action: {
                                    deleteAlbum(album)
                                }) {
                                    Label("Удалить альбом", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 60)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: playerVM.currentTrack != nil ? 144 : 76)
            }
            .navigationTitle("Альбомы")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Поиск по альбомам")
        }
    }

    private func deleteAlbum(_ album: Album) {
        if let current = playerVM.currentTrack, album.tracks.contains(where: { $0.id == current.id }) {
            playerVM.pause()
            playerVM.currentTrack = nil
        }
        libraryStore.deleteAlbum(album)
    }
}
