import SwiftUI

@main
struct MyMusicApp: App {
    /// Главное хранилище медиатеки с сохранением в JSON (iOS 16+)
    @StateObject private var libraryStore = LibraryStore.shared
    /// Менеджер темы и акцентного цвета (iOS 16+)
    @StateObject private var themeManager = ThemeManager.shared
    /// Главная ViewModel воспроизведения (создаётся один раз на уровне App)
    @StateObject private var playerVM = PlayerViewModel.shared

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(libraryStore)
                .environmentObject(themeManager)
                .environmentObject(playerVM)
                .preferredColorScheme(themeManager.colorScheme)
                .tint(themeManager.accentColor)
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .background:
                        // В фоне останавливаем отрисовку UI-таймеров и сохраняем состояние
                        AudioEngineManager.shared.handleDidEnterBackground()
                        playerVM.savePlaybackState()
                    case .active:
                        // При возврате на экран восстанавливаем точное время из узлов движка
                        AudioEngineManager.shared.handleWillEnterForeground()
                    default:
                        break
                    }
                }
        }
    }
}
