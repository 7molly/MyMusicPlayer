import SwiftUI
import UniformTypeIdentifiers

// MARK: - Разделы медиатеки
enum LibrarySection: String, CaseIterable, Identifiable {
    case tracks = "Песни"
    case playlists = "Плейлисты"
    var id: String { rawValue }
}

/// Экран «Медиатека» со списком треков, плейлистами, поиском, редактированием и меню импорта (iOS 16+)
struct LibraryView: View {
    @EnvironmentObject private var libraryStore: LibraryStore

    @ObservedObject var playerVM = PlayerViewModel.shared
    @ObservedObject var importService = ImportService.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var selectedSection: LibrarySection = .tracks
    @State private var searchText: String = ""
    @State private var debouncedSearchText: String = ""
    @State private var debouncedFilteredTracks: [Track] = []
    @State private var debouncedFilteredPlaylists: [Playlist] = []
    @State private var isSearchActive: Bool = false
    @FocusState private var isSearchFocused: Bool
    @State private var showErrorAlert: Bool = false
    @State private var alertErrorMessage: String = ""
    @State private var trackToEdit: Track? = nil
    @State private var showSoundCloudSheet: Bool = false
    @State private var showCreatePlaylistSheet: Bool = false
    @State private var trackForPlaylist: Track? = nil

    private let playlistColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    /// Список всех треков, отсортированных по дате добавления (новые вверху)
    var allTracks: [Track] {
        libraryStore.tracks.sorted { $0.dateAdded > $1.dateAdded }
    }

    /// Фильтрация треков по названию, исполнителю или альбому с 250 мс дебаунсом в фоне
    var filteredTracks: [Track] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return allTracks
        } else if debouncedSearchText == trimmed {
            return debouncedFilteredTracks
        } else {
            return debouncedFilteredTracks.isEmpty ? allTracks.filter {
                $0.title.localizedCaseInsensitiveContains(trimmed) ||
                $0.artist.localizedCaseInsensitiveContains(trimmed) ||
                $0.albumName.localizedCaseInsensitiveContains(trimmed)
            } : debouncedFilteredTracks
        }
    }

    /// Фильтрация и сортировка плейлистов: закреплённые всегда сверху, далее по дате создания
    var filteredPlaylists: [Playlist] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return libraryStore.playlists.sorted { p1, p2 in
                if p1.isPinned != p2.isPinned {
                    return p1.isPinned && !p2.isPinned
                }
                return p1.dateCreated > p2.dateCreated
            }
        } else if debouncedSearchText == trimmed {
            return debouncedFilteredPlaylists
        } else {
            return libraryStore.playlists.filter {
                $0.title.localizedCaseInsensitiveContains(trimmed) ||
                $0.playlistDescription.localizedCaseInsensitiveContains(trimmed)
            }.sorted { p1, p2 in
                if p1.isPinned != p2.isPinned {
                    return p1.isPinned && !p2.isPinned
                }
                return p1.dateCreated > p2.dateCreated
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Шапка: «Медиатека» на своём месте и кнопка «+» опущена вниз прямо напротив неё
                HStack(alignment: .center) {
                    Text("Медиатека")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Menu {
                        Button(action: { showCreatePlaylistSheet = true }) {
                            Label("Новый плейлист…", systemImage: "music.note.list")
                        }

                        Button(action: { showSoundCloudSheet = true }) {
                            Label("Импорт из SoundCloud (MP3 320)", systemImage: "arrow.down.circle")
                        }

                        Divider()

                        Button(action: triggerFilePicker) {
                            Label("Выбрать файлы…", systemImage: "doc.badge.plus")
                        }

                        Button(action: triggerFolderPicker) {
                            Label("Выбрать папку…", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(themeManager.accentColor)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

                // Верхний ряд управления: кнопка лупы + переключатель «Песни / Плейлисты»
                HStack(spacing: 10) {
                    if isSearchActive {
                        // Раскрытая поисковая строка на всю ширину
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)

                            TextField("Поиск по трекам…", text: $searchText)
                                .focused($isSearchFocused)
                                .font(.system(size: 15))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .submitLabel(.search)

                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(Color(uiColor: .secondarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        Button("Отмена") {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                searchText = ""
                                isSearchActive = false
                                isSearchFocused = false
                            }
                        }
                        .font(.system(size: 15))
                        .foregroundStyle(themeManager.accentColor)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        // Кнопка лупы слева
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                isSearchActive = true
                            }
                            isSearchFocused = true
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(uiColor: .secondarySystemFill))
                                    .frame(width: 34, height: 34)

                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))

                        // Переключатель «Песни» / «Плейлисты» (смещён правее)
                        Picker("Раздел", selection: $selectedSection) {
                            ForEach(LibrarySection.allCases) { section in
                                Text(section.rawValue).tag(section)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 8)

                ZStack {
                    if isSearchActive || selectedSection == .tracks {
                        tracksView
                    } else {
                        playlistsView
                    }

                    // Индикатор прогресса импорта поверх списка
                    if importService.isImporting {
                        importProgressOverlay
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationBarTitleDisplayMode(.inline)
            // Модальное окно редактирования трека
            .sheet(item: $trackToEdit) { track in
                EditTrackView(track: track)
                    .environmentObject(libraryStore)
            }
            // Модальное окно создания плейлиста
            .sheet(isPresented: $showCreatePlaylistSheet) {
                CreatePlaylistSheet()
                    .environmentObject(libraryStore)
            }
            // Модальное окно добавления трека в плейлист
            .sheet(item: $trackForPlaylist) { track in
                AddToPlaylistSheet(track: track)
                    .environmentObject(libraryStore)
            }
            // Модальное окно импорта из SoundCloud
            .sheet(isPresented: $showSoundCloudSheet) {
                SoundCloudImportSheet()
                    .environmentObject(libraryStore)
            }
            .alert("Ошибка импорта", isPresented: $showErrorAlert) {
                Button("Понятно", role: .cancel) {}
            } message: {
                Text(alertErrorMessage)
            }
            .task(id: searchText) {
                let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    debouncedSearchText = ""
                    debouncedFilteredTracks = []
                    debouncedFilteredPlaylists = []
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    let currentTracks = libraryStore.tracks
                    let currentPlaylists = libraryStore.playlists

                    let (t, p) = await Task.detached(priority: .userInitiated) {
                        let filteredT = currentTracks.filter { track in
                            track.title.localizedCaseInsensitiveContains(trimmed) ||
                            track.artist.localizedCaseInsensitiveContains(trimmed) ||
                            track.albumName.localizedCaseInsensitiveContains(trimmed)
                        }.sorted { $0.dateAdded > $1.dateAdded }

                        let filteredP = currentPlaylists.filter {
                            $0.title.localizedCaseInsensitiveContains(trimmed) ||
                            $0.playlistDescription.localizedCaseInsensitiveContains(trimmed)
                        }.sorted { p1, p2 in
                            if p1.isPinned != p2.isPinned { return p1.isPinned && !p2.isPinned }
                            return p1.dateCreated > p2.dateCreated
                        }

                        return (filteredT, filteredP)
                    }.value

                    debouncedSearchText = trimmed
                    debouncedFilteredTracks = t
                    debouncedFilteredPlaylists = p
                } catch {
                    // Пользователь ввел следующий символ
                }
            }
        }
    }

    // MARK: - Представление списка треков
    @ViewBuilder
    private var tracksView: some View {
        if allTracks.isEmpty && !importService.isImporting {
            emptyStateView
        } else if isSearchActive && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filteredTracks.isEmpty {
            noSearchResultsView
        } else {
            List {
                Section {
                    ForEach(filteredTracks) { track in
                        TrackRowView(
                            track: track,
                            showTrackNumber: false,
                            isCurrentTrack: playerVM.currentTrack?.id == track.id,
                            isPlaying: playerVM.isPlaying,
                            onPlay: {
                                if playerVM.currentTrack?.id == track.id {
                                    if playerVM.isPlaying {
                                        playerVM.pause()
                                    } else {
                                        playerVM.play()
                                    }
                                } else {
                                    playerVM.playTrack(track, in: filteredTracks)
                                }
                            },
                            onEdit: {
                                trackToEdit = track
                            },
                            onAddToQueue: {
                                playerVM.addToQueue(track)
                            },
                            onAddToPlaylist: {
                                trackForPlaylist = track
                            },
                            onDelete: {
                                deleteTrack(track)
                            }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteTrack(track)
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    if !filteredTracks.isEmpty {
                        Text(isSearchActive ? "Найдено: \(filteredTracks.count)" : "\(filteredTracks.count) треков")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: playerVM.currentTrack != nil ? 144 : 76)
            }
        }
    }

    // MARK: - Пустое состояние при отсутствии результатов поиска
    private var noSearchResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .padding(.top, 40)

            Text("Ничего не найдено")
                .font(.title3)
                .fontWeight(.bold)

            Text("По запросу «\(searchText)» треков не найдено.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Представление сетки плейлистов
    @ViewBuilder
    private var playlistsView: some View {
        ScrollView {
            LazyVGrid(columns: playlistColumns, spacing: 20) {
                // Карточка быстрого создания нового плейлиста
                Button {
                    showCreatePlaylistSheet = true
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(themeManager.accentColor.opacity(0.12))
                                .aspectRatio(1, contentMode: .fit)

                            VStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.system(size: 32, weight: .semibold))
                                    .foregroundStyle(themeManager.accentColor)
                                Text("Создать")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(themeManager.accentColor)
                            }
                        }

                        Text("Новый плейлист")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)

                        Text("Нажмите для добавления")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                ForEach(filteredPlaylists) { playlist in
                    NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                        PlaylistCardView(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                libraryStore.togglePin(playlist: playlist)
                            }
                        } label: {
                            Label(playlist.isPinned ? "Открепить" : "Закрепить",
                                  systemImage: playlist.isPinned ? "pin.slash.fill" : "pin.fill")
                        }

                        Button {
                            playerVM.playPlaylist(playlist, in: libraryStore, shuffle: false)
                        } label: {
                            Label("Слушать", systemImage: "play.fill")
                        }

                        Button {
                            playerVM.playPlaylist(playlist, in: libraryStore, shuffle: true)
                        } label: {
                            Label("Перемешать", systemImage: "shuffle")
                        }

                        Divider()

                        Button(role: .destructive) {
                            withAnimation {
                                libraryStore.deletePlaylist(playlist)
                            }
                        } label: {
                            Label("Удалить плейлист", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: playerVM.currentTrack != nil ? 144 : 76)
        }
    }

    // MARK: - Пустое состояние
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.list")
                .font(.system(size: 64))
                .foregroundStyle(themeManager.accentColor)

            Text("Здесь появится ваша музыка")
                .font(.title2)
                .fontWeight(.bold)

            Text("Выберите отдельные аудиофайлы (.mp3, .wav, .m4a) или добавьте целую папку с музыкой.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 12) {
                Button(action: triggerFilePicker) {
                    HStack {
                        Image(systemName: "doc.badge.plus")
                        Text("Выбрать файлы…")
                    }
                    .font(.headline)
                    .foregroundStyle(themeManager.contrastForegroundColor)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .frame(maxWidth: 260)
                    .background(themeManager.accentColor)
                    .clipShape(Capsule())
                }

                Button(action: triggerFolderPicker) {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text("Выбрать папку…")
                    }
                    .font(.headline)
                    .foregroundStyle(themeManager.accentColor)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .frame(maxWidth: 260)
                    .background(themeManager.accentColor.opacity(0.12))
                    .clipShape(Capsule())
                }

                Button(action: { showSoundCloudSheet = true }) {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                        Text("Импорт из SoundCloud (MP3 320)")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 260)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
                }
            }
            .padding(.top, 8)
        }
        .padding()
    }

    // MARK: - Вызов нативного диалога выбора файлов
    private func triggerFilePicker() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            DocumentPickerPresenter.shared.present(mode: .files) { urls in
                guard !urls.isEmpty else { return }
                Task {
                    await importService.importFiles(urls: urls, libraryStore: libraryStore)
                    if let error = importService.errorMessage {
                        alertErrorMessage = error
                        showErrorAlert = true
                    }
                }
            }
        }
    }

    // MARK: - Вызов нативного диалога выбора папки
    private func triggerFolderPicker() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            DocumentPickerPresenter.shared.present(mode: .folder) { urls in
                guard let folderURL = urls.first else { return }
                Task {
                    await importService.importFolder(url: folderURL, libraryStore: libraryStore)
                    if let error = importService.errorMessage {
                        alertErrorMessage = error
                        showErrorAlert = true
                    }
                }
            }
        }
    }

    // MARK: - Оверлей прогресса импорта
    private var importProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView(value: importService.importProgress)
                    .progressViewStyle(.linear)
                    .tint(themeManager.accentColor)

                Text(importService.statusText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 6)
            )
            .padding()
        }
    }

    // MARK: - Удаление трека
    private func deleteTrack(_ track: Track) {
        if playerVM.currentTrack?.id == track.id {
            playerVM.pause()
            playerVM.currentTrack = nil
        }
        libraryStore.deleteTrack(track)
    }
}

// MARK: - Карточка плейлиста в сетке
struct PlaylistCardView: View {
    let playlist: Playlist
    @EnvironmentObject private var libraryStore: LibraryStore
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(
                data: playlist.resolvedArtwork(in: libraryStore),
                cornerRadius: 10,
                targetPixelSize: 500,
                placeholderBackground: Color(uiColor: .secondarySystemBackground),
                placeholderSymbol: "music.note.list"
            )
            .aspectRatio(1, contentMode: .fit)
            .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
            .overlay(alignment: .topTrailing) {
                if playlist.isPinned {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.65))
                            .frame(width: 26, height: 26)
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(themeManager.accentColor)
                    }
                    .padding(8)
                    .transition(.scale.combined(with: .opacity))
                }
            }

            HStack(spacing: 4) {
                if playlist.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(themeManager.accentColor)
                }

                Text(playlist.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }

            Text("\(playlist.trackIDs.count) треков")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Создание нового плейлиста
struct CreatePlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var libraryStore: LibraryStore
    @State private var title: String = ""
    @State private var description: String = ""

    var initialTrack: Track? = nil
    var onCreated: ((Playlist) -> Void)? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название плейлиста", text: $title)
                        .autocorrectionDisabled(false)
                    TextField("Описание (необязательно)", text: $description)
                } header: {
                    Text("Информация о плейлисте")
                }
            }
            .navigationTitle("Новый плейлист")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        let trackIDs = initialTrack != nil ? [initialTrack!.id] : []
                        let p = libraryStore.createPlaylist(title: title, description: description, initialTrackIDs: trackIDs)
                        onCreated?(p)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Шторка «Добавить в плейлист»
struct AddToPlaylistSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var libraryStore: LibraryStore
    @State private var showCreateNew: Bool = false
    @State private var addedToPlaylistName: String? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showCreateNew = true
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.accentColor.opacity(0.15))
                                    .frame(width: 44, height: 44)
                                Image(systemName: "plus")
                                    .font(.headline)
                                    .foregroundStyle(Color.accentColor)
                            }
                            Text("Новый плейлист…")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }

                Section("Ваши плейлисты") {
                    let sortedPlaylists = libraryStore.playlists.sorted { p1, p2 in
                        if p1.isPinned != p2.isPinned {
                            return p1.isPinned && !p2.isPinned
                        }
                        return p1.dateCreated > p2.dateCreated
                    }
                    if sortedPlaylists.isEmpty {
                        Text("У вас пока нет созданных плейлистов")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(sortedPlaylists) { playlist in
                            let isAlreadyIn = playlist.trackIDs.contains(track.id)
                            Button {
                                if !isAlreadyIn {
                                    libraryStore.addTrack(track, to: playlist)
                                    addedToPlaylistName = playlist.title
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        dismiss()
                                    }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(
                                        data: playlist.resolvedArtwork(in: libraryStore),
                                        cornerRadius: 6,
                                        placeholderBackground: Color(uiColor: .secondarySystemBackground),
                                        placeholderSymbol: "music.note.list"
                                    )
                                    .frame(width: 44, height: 44)

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 4) {
                                            if playlist.isPinned {
                                                Image(systemName: "pin.fill")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundStyle(Color.accentColor)
                                            }
                                            Text(playlist.title)
                                                .font(.body)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                        }
                                        Text("\(playlist.trackIDs.count) треков")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if isAlreadyIn {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Добавить в плейлист")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .sheet(isPresented: $showCreateNew) {
                CreatePlaylistSheet(initialTrack: track) { _ in
                    dismiss()
                }
                .environmentObject(libraryStore)
            }
        }
    }
}

// MARK: - Экран детального просмотра плейлиста
struct PlaylistDetailView: View {
    let playlist: Playlist
    @EnvironmentObject private var libraryStore: LibraryStore
    @ObservedObject var playerVM = PlayerViewModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showEditSheet: Bool = false
    @State private var showDeleteAlert: Bool = false

    var currentPlaylist: Playlist {
        libraryStore.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    var tracks: [Track] {
        currentPlaylist.resolvedTracks(in: libraryStore)
    }

    var body: some View {
        List {
            // Шапка плейлиста в стиле Apple Music
            Section {
                VStack(spacing: 16) {
                    ArtworkView(
                        data: currentPlaylist.resolvedArtwork(in: libraryStore),
                        cornerRadius: 12,
                        targetPixelSize: 1000,
                        placeholderBackground: Color(white: 0.15),
                        placeholderSymbolColor: .white.opacity(0.7),
                        placeholderSymbol: "music.note.list"
                    )
                    .frame(width: 200, height: 200)
                    .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 7)
                    .padding(.top, 12)

                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            if currentPlaylist.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Text(currentPlaylist.title)
                                .font(.title2)
                                .fontWeight(.bold)
                                .multilineTextAlignment(.center)
                        }

                        if !currentPlaylist.playlistDescription.isEmpty {
                            Text(currentPlaylist.playlistDescription)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        Text("\(tracks.count) песен • \(formatTotalDuration(currentPlaylist.totalDuration(in: libraryStore)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Кнопки Воспроизвести и Перемешать
                    if !tracks.isEmpty {
                        HStack(spacing: 14) {
                            Button {
                                playerVM.playPlaylist(currentPlaylist, in: libraryStore, shuffle: false)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "play.fill")
                                    Text("Слушать")
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }

                            Button {
                                playerVM.playPlaylist(currentPlaylist, in: libraryStore, shuffle: true)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "shuffle")
                                    Text("Перемешать")
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // Список треков
            if tracks.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Text("В плейлисте пока нет треков")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Добавляйте треки из медиатеки через контекстное меню «Добавить в плейлист»")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRowView(
                            track: track,
                            showTrackNumber: true,
                            trackIndex: index + 1,
                            isCurrentTrack: playerVM.currentTrack?.id == track.id,
                            isPlaying: playerVM.isPlaying,
                            onPlay: {
                                if playerVM.currentTrack?.id == track.id {
                                    if playerVM.isPlaying {
                                        playerVM.pause()
                                    } else {
                                        playerVM.play()
                                    }
                                } else {
                                    playerVM.playTrack(track, in: tracks)
                                }
                            },
                            onDelete: {
                                libraryStore.removeTrack(id: track.id, from: currentPlaylist)
                            }
                        )
                    }
                    .onDelete { indexSet in
                        for idx in indexSet {
                            let track = tracks[idx]
                            libraryStore.removeTrack(id: track.id, from: currentPlaylist)
                        }
                    }
                    .onMove { source, dest in
                        libraryStore.moveTracks(in: currentPlaylist, from: source, to: dest)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: playerVM.currentTrack != nil ? 144 : 76)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        withAnimation {
                            libraryStore.togglePin(playlist: currentPlaylist)
                        }
                    } label: {
                        Label(currentPlaylist.isPinned ? "Открепить плейлист" : "Закрепить плейлист",
                              systemImage: currentPlaylist.isPinned ? "pin.slash" : "pin")
                    }

                    Button {
                        showEditSheet = true
                    } label: {
                        Label("Изменить плейлист", systemImage: "pencil")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        Label("Удалить плейлист", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                }
            }
        }
        .alert("Удалить плейлист?", isPresented: $showDeleteAlert) {
            Button("Удалить", role: .destructive) {
                libraryStore.deletePlaylist(currentPlaylist)
                dismiss()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Плейлист «\(currentPlaylist.title)» будет удалён. Сами аудиофайлы останутся в медиатеке.")
        }
        .sheet(isPresented: $showEditSheet) {
            EditPlaylistSheet(playlist: currentPlaylist)
                .environmentObject(libraryStore)
        }
    }

    private func formatTotalDuration(_ duration: TimeInterval) -> String {
        let mins = Int(duration) / 60
        if mins < 60 {
            return "\(mins) мин."
        } else {
            let hours = mins / 60
            let remMins = mins % 60
            return "\(hours) ч. \(remMins) мин."
        }
    }
}

// MARK: - Редактирование информации о плейлисте
struct EditPlaylistSheet: View {
    let playlist: Playlist
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var libraryStore: LibraryStore

    @State private var title: String = ""
    @State private var description: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Название и описание") {
                    TextField("Название", text: $title)
                    TextField("Описание", text: $description)
                }
            }
            .navigationTitle("Изменить плейлист")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        var updated = playlist
                        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? playlist.title : title
                        updated.playlistDescription = description
                        libraryStore.updatePlaylist(updated)
                        dismiss()
                    }
                }
            }
            .onAppear {
                title = playlist.title
                description = playlist.playlistDescription
            }
        }
    }
}
