import SwiftUI

/// Экран очереди воспроизведения «Далее» в стиле Apple Music (iOS 16+)
struct QueueView: View {
    @ObservedObject var playerVM = PlayerViewModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive

    var upcomingTracks: [Track] {
        if playerVM.queue.isEmpty { return [] }
        let nextIndex = playerVM.currentIndex + 1
        if nextIndex < playerVM.queue.count {
            return Array(playerVM.queue[nextIndex...])
        }
        return []
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.11, green: 0.11, blue: 0.13)
                    .ignoresSafeArea()

                List {
                    // Верхняя панель управления: Shuffle и Repeat (как в Apple Music)
                    Section {
                        HStack(spacing: 12) {
                            // Кнопка Перемешать
                            Button(action: {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                    playerVM.toggleShuffle()
                                }
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "shuffle")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("Перемешать")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                                .foregroundStyle(playerVM.isShuffleEnabled ? Color.black : Color.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(
                                    playerVM.isShuffleEnabled ?
                                    Color.white : Color.white.opacity(0.12)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            // Кнопка Повтор
                            Button(action: {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                    playerVM.cycleRepeatMode()
                                }
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: playerVM.repeatMode.iconName)
                                        .font(.system(size: 16, weight: .semibold))
                                    Text(repeatTitle)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                                .foregroundStyle(playerVM.repeatMode != .off ? Color.black : Color.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(
                                    playerVM.repeatMode != .off ?
                                    Color.white : Color.white.opacity(0.12)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                    }

                    // Текущий трек
                    if let current = playerVM.currentTrack {
                        Section {
                            HStack(spacing: 12) {
                                ArtworkView(
                                    data: current.resolvedArtworkData(),
                                    cornerRadius: 6,
                                    placeholderBackground: Color(white: 0.18),
                                    placeholderSymbolColor: Color.white.opacity(0.60)
                                )
                                .id(current.id)
                                .frame(width: 44, height: 44)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(current.title)
                                        .font(.body)
                                        .fontWeight(.bold)
                                        .foregroundStyle(.white)
                                        .lineLimit(1)

                                    Text(current.artist)
                                        .font(.subheadline)
                                        .foregroundStyle(.white.opacity(0.60))
                                        .lineLimit(1)
                                }

                                Spacer()

                                Image(systemName: playerVM.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }
                            .padding(.vertical, 4)
                        } header: {
                            Text("Сейчас играет")
                                .font(.footnote)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white.opacity(0.60))
                        }
                    }

                    // Список предстоящих треков «Далее»
                    Section {
                        if upcomingTracks.isEmpty {
                            Text("Очередь пуста")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.50))
                                .padding(.vertical, 8)
                        } else {
                            ForEach(Array(upcomingTracks.enumerated()), id: \.element.id) { offset, track in
                                let actualIndex = playerVM.currentIndex + 1 + offset
                                HStack(spacing: 12) {
                                    ArtworkView(
                                        data: track.resolvedArtworkData(),
                                        cornerRadius: 6,
                                        placeholderBackground: Color(white: 0.18),
                                        placeholderSymbolColor: Color.white.opacity(0.60)
                                    )
                                    .id(track.id)
                                    .frame(width: 44, height: 44)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title)
                                            .font(.body)
                                            .fontWeight(.medium)
                                            .foregroundStyle(.white)
                                            .lineLimit(1)

                                        Text(track.artist)
                                            .font(.subheadline)
                                            .foregroundStyle(.white.opacity(0.60))
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Text(track.formattedDuration)
                                        .font(.footnote)
                                        .foregroundStyle(.white.opacity(0.50))
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    playerVM.play(track: track, at: actualIndex, startPosition: 0.0, autoPlay: true)
                                }
                            }
                            .onMove { source, destination in
                                let adjustedSource = IndexSet(source.map { $0 + playerVM.currentIndex + 1 })
                                let adjustedDestination = destination + playerVM.currentIndex + 1
                                playerVM.moveQueueItem(from: adjustedSource, to: adjustedDestination)
                            }
                            .onDelete { offsets in
                                let adjustedOffsets = IndexSet(offsets.map { $0 + playerVM.currentIndex + 1 })
                                playerVM.removeQueueItems(at: adjustedOffsets)
                            }
                        }
                    } header: {
                        HStack {
                            Text("Далее")
                                .font(.footnote)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white.opacity(0.60))

                            Spacer()

                            if !upcomingTracks.isEmpty {
                                Button("Очистить") {
                                    playerVM.clearQueue()
                                }
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.80))
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .environment(\.editMode, $editMode)
            }
            .navigationTitle("Далее")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: {
                        withAnimation {
                            editMode = editMode.isEditing ? .inactive : .active
                        }
                    }) {
                        Text(editMode.isEditing ? "Готово" : "Править")
                            .foregroundStyle(.white)
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.60))
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var repeatTitle: String {
        switch playerVM.repeatMode {
        case .off: return "Повтор"
        case .all: return "Все"
        case .one: return "Один"
        }
    }
}
