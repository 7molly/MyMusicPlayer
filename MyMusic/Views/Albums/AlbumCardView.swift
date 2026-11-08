import SwiftUI

/// Карточка альбома в сетке
struct AlbumCardView: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(data: album.resolvedArtworkData, cornerRadius: 10, targetPixelSize: 500)
                .aspectRatio(1.0, contentMode: .fit)
                .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)

            Text(album.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(album.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
