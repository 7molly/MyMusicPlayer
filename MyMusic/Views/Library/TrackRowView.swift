import SwiftUI

/// Строка отображения трека в списке медиатеки с поддержкой свайпов и контекстного меню (iOS 16+)
struct TrackRowView: View {
    let track: Track
    var showTrackNumber: Bool = false
    var trackIndex: Int = 1
    var isCurrentTrack: Bool = false
    var isPlaying: Bool = false
    var onPlay: () -> Void
    var onEdit: (() -> Void)? = nil
    var onAddToQueue: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    var onDelete: () -> Void

    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                if showTrackNumber {
                    Text("\(trackIndex)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .center)
                } else {
                    ArtworkView(data: track.resolvedArtworkData(), cornerRadius: 6)
                        .id(track.id)
                        .frame(width: 44, height: 44)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.body)
                        .fontWeight(isCurrentTrack ? .bold : .medium)
                        .foregroundStyle(isCurrentTrack ? themeManager.accentColor : .primary)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isCurrentTrack {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.caption)
                        .foregroundStyle(themeManager.accentColor)
                }

                Text(track.formattedDuration)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Свайп слева для быстрого редактирования
        .swipeActions(edge: .leading) {
            if let onEdit = onEdit {
                Button(action: onEdit) {
                    Label("Изменить", systemImage: "pencil")
                }
                .tint(.blue)
            }
        }
        // Контекстное меню по долгому нажатию
        .contextMenu {
            Button(action: onPlay) {
                Label("Слушать", systemImage: "play.fill")
            }

            if let onEdit = onEdit {
                Button(action: onEdit) {
                    Label("Изменить информацию", systemImage: "pencil")
                }
            }

            if let onAddToQueue = onAddToQueue {
                Button(action: onAddToQueue) {
                    Label("Добавить в очередь", systemImage: "text.badge.plus")
                }
            }

            if let onAddToPlaylist = onAddToPlaylist {
                Button(action: onAddToPlaylist) {
                    Label("Добавить в плейлист…", systemImage: "music.note.list")
                }
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label("Удалить из медиатеки", systemImage: "trash")
            }
        }
    }
}
