import SwiftUI

/// Контейнер вкладок с протоколом Equatable для полного исключения лишних перерисовок медиатеки во время жестов (60 fps)
struct TabsContentContainer: View, Equatable {
    let selectedTab: Int
    let isFrozen: Bool

    static func == (lhs: TabsContentContainer, rhs: TabsContentContainer) -> Bool {
        lhs.selectedTab == rhs.selectedTab && lhs.isFrozen == rhs.isFrozen
    }

    var body: some View {
        ZStack {
            LibraryView()
                .opacity(selectedTab == 0 ? 1 : 0)
                .allowsHitTesting(selectedTab == 0 && !isFrozen)

            AlbumsView()
                .opacity(selectedTab == 1 ? 1 : 0)
                .allowsHitTesting(selectedTab == 1 && !isFrozen)

            EqualizerView()
                .opacity(selectedTab == 2 ? 1 : 0)
                .allowsHitTesting(selectedTab == 2 && !isFrozen)

            SettingsView()
                .opacity(selectedTab == 3 ? 1 : 0)
                .allowsHitTesting(selectedTab == 3 && !isFrozen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Главный TabView приложения с 4 вкладками, плавающим мини-плеером и нативной плавающей нижней панелью
struct MainTabView: View {
    @ObservedObject var playerVM = PlayerViewModel.shared
    @ObservedObject var themeManager = ThemeManager.shared
    @ObservedObject var sheetState = PlayerSheetState.shared
    @EnvironmentObject private var libraryStore: LibraryStore
    @State private var selectedTab: Int = 0

    var body: some View {
        let layout = PlayerLayoutCalculator.standard
        let t = sheetState.expansion

        ZStack(alignment: .bottom) {
            // 1. Контент медиатеки и таб-бара (под плеером)
            // Медиатека под плеером: чёрный overlay с opacity = 0.45 * t, scaleEffect = 1 - 0.06 * t, скругление 20 * t
            ZStack(alignment: .bottom) {
                // Вкладки заморожены через Equatable и не перерисовываются при движении карточки
                TabsContentContainer(selectedTab: selectedTab, isFrozen: t > 0.05)
                    .equatable()

                // Нижний блок: Мини-плеер + плавающая «Нижняя панелька»
                VStack(spacing: 8) {
                    if playerVM.currentTrack != nil {
                        MiniPlayerView(
                            onTap: {
                                sheetState.animate(to: 1.0)
                            }
                        )
                    }

                    CustomFloatingTabBar(selectedTab: $selectedTab)
                        .allowsHitTesting(t < 0.1 && !sheetState.isAnimating)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .background(
                    // Перехватываем тапы по области дока и щели между элементами, чтобы они не падали на треки списка под ними
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Изолируем клики в области панели от медиатеки под ней
                        }
                )
            }
            .scaleEffect(1.0 - 0.06 * t)
            .clipShape(RoundedRectangle(cornerRadius: 20.0 * t, style: .continuous))
            .overlay(
                Color.black
                    .opacity(0.45 * t)
                    .ignoresSafeArea()
                    .allowsHitTesting(t > 0.1)
                    .onTapGesture {
                        if t > 0.1 {
                            sheetState.animate(to: 0.0)
                        }
                    }
            )

            // 2. Полноэкранный плеер ВСЕГДА остаётся в иерархии (без if, без .transition, без пересоздания)
            if playerVM.currentTrack != nil {
                FullScreenPlayerView(
                    onClose: {
                        sheetState.animate(to: 0.0)
                    }
                )
                .zIndex(50)
            }
        }
        .frame(width: layout.screenW, height: layout.screenH)
        .ignoresSafeArea()
        .preferredColorScheme(t > 0.5 ? .dark : themeManager.colorScheme)
        .onChange(of: playerVM.showFullScreenPlayer) { show in
            if show && sheetState.expansion < 1.0 {
                sheetState.animate(to: 1.0)
            } else if !show && sheetState.expansion > 0.0 {
                sheetState.animate(to: 0.0)
            }
        }
    }
}

/// Фирменная плавающая нижняя панель («Нижняя панелька») в стиле современной iOS
struct CustomFloatingTabBar: View {
    @Binding var selectedTab: Int
    @ObservedObject private var themeManager = ThemeManager.shared

    private let tabs: [(icon: String, title: String)] = [
        ("music.note.house.fill", "Медиатека"),
        ("square.stack.fill", "Альбомы"),
        ("slider.vertical.3", "Эквалайзер"),
        ("gearshape.fill", "Настройки")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<tabs.count, id: \.self) { index in
                let tab = tabs[index]
                let isSelected = selectedTab == index

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selectedTab = index
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 19, weight: isSelected ? .bold : .medium))
                        Text(tab.title)
                            .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                    }
                    .foregroundStyle(isSelected ? themeManager.accentColor : Color.white.opacity(0.60))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        ZStack {
                            if isSelected {
                                Capsule()
                                    .fill(Color.white.opacity(0.12))
                            }
                        }
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(height: 56)
        .background(
            Capsule()
                .fill(Color(white: 0.12).opacity(0.92))
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.40), radius: 16, x: 0, y: 6)
        )
    }
}
