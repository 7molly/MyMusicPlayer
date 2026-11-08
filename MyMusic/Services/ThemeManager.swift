import SwiftUI
import Combine
import UIKit

/// Вариант темы оформления
enum AppThemeMode: String, CaseIterable, Identifiable, Codable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Системная"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Модель RGBA цвета для надёжного сохранения в UserDefaults
struct RGBAColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1.0

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var uiColor: UIColor {
        UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    /// Воспринимаемая яркость (perceived luminance) по стандарту WCAG
    var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// Контрастный цвет текста (белый или чёрный) в зависимости от яркости фона
    var contrastTextColor: Color {
        luminance > 0.6 ? .black : .white
    }

    func isClose(to other: RGBAColor, tolerance: Double = 0.03) -> Bool {
        abs(red - other.red) < tolerance &&
        abs(green - other.green) < tolerance &&
        abs(blue - other.blue) < tolerance
    }
}

/// Пресеты готовых цветов акцента
struct ThemePresetColor: Identifiable, Equatable {
    let id: String
    let name: String
    let color: Color
    let rgba: RGBAColor

    static let red = ThemePresetColor(
        id: "red",
        name: "Красный",
        color: Color(red: 250/255, green: 45/255, blue: 72/255),
        rgba: RGBAColor(red: 250/255, green: 45/255, blue: 72/255, alpha: 1.0)
    )
    static let orange = ThemePresetColor(
        id: "orange",
        name: "Оранжевый",
        color: Color(red: 255/255, green: 149/255, blue: 0/255),
        rgba: RGBAColor(red: 255/255, green: 149/255, blue: 0/255, alpha: 1.0)
    )
    static let yellow = ThemePresetColor(
        id: "yellow",
        name: "Жёлтый",
        color: Color(red: 255/255, green: 204/255, blue: 0/255),
        rgba: RGBAColor(red: 255/255, green: 204/255, blue: 0/255, alpha: 1.0)
    )
    static let green = ThemePresetColor(
        id: "green",
        name: "Зелёный",
        color: Color(red: 52/255, green: 199/255, blue: 89/255),
        rgba: RGBAColor(red: 52/255, green: 199/255, blue: 89/255, alpha: 1.0)
    )
    static let teal = ThemePresetColor(
        id: "teal",
        name: "Бирюзовый",
        color: Color(red: 0/255, green: 199/255, blue: 190/255),
        rgba: RGBAColor(red: 0/255, green: 199/255, blue: 190/255, alpha: 1.0)
    )
    static let blue = ThemePresetColor(
        id: "blue",
        name: "Синий",
        color: Color(red: 0/255, green: 122/255, blue: 255/255),
        rgba: RGBAColor(red: 0/255, green: 122/255, blue: 255/255, alpha: 1.0)
    )
    static let purple = ThemePresetColor(
        id: "purple",
        name: "Фиолетовый",
        color: Color(red: 175/255, green: 82/255, blue: 222/255),
        rgba: RGBAColor(red: 175/255, green: 82/255, blue: 222/255, alpha: 1.0)
    )
    static let pink = ThemePresetColor(
        id: "pink",
        name: "Розовый",
        color: Color(red: 255/255, green: 45/255, blue: 85/255),
        rgba: RGBAColor(red: 255/255, green: 45/255, blue: 85/255, alpha: 1.0)
    )
    static let graphite = ThemePresetColor(
        id: "graphite",
        name: "Графитовый",
        color: Color(red: 72/255, green: 72/255, blue: 74/255),
        rgba: RGBAColor(red: 72/255, green: 72/255, blue: 74/255, alpha: 1.0)
    )

    static let allPresets: [ThemePresetColor] = [
        .red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .graphite
    ]
}

/// Главный менеджер оформления приложения (ObservableObject, совместим с iOS 16+)
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var accentColor: Color
    @Published var currentRGBA: RGBAColor

    @Published var colorSchemeOption: AppThemeMode {
        didSet {
            UserDefaults.standard.set(colorSchemeOption.rawValue, forKey: themeModeKey)
        }
    }

    var colorScheme: ColorScheme? {
        colorSchemeOption.colorScheme
    }

    /// Цвет текста для кнопок с цветным фоном (автоматически белый или чёрный)
    var contrastForegroundColor: Color {
        currentRGBA.contrastTextColor
    }

    /// Проверка, выбран ли пользовательский цвет вне пресетов
    var isCustomColorSelected: Bool {
        !ThemePresetColor.allPresets.contains { $0.rgba.isClose(to: currentRGBA) }
    }

    private let themeModeKey = "App_Theme_Mode_Setting"
    private let accentColorKey = "App_Accent_Color_RGBA_Data"

    private init() {
        // Загрузка сохранённой темы
        if let savedModeRaw = UserDefaults.standard.string(forKey: themeModeKey),
           let savedMode = AppThemeMode(rawValue: savedModeRaw) {
            self.colorSchemeOption = savedMode
        } else {
            self.colorSchemeOption = .system
        }

        // Загрузка сохранённого цвета акцента
        if let data = UserDefaults.standard.data(forKey: accentColorKey),
           let savedRGBA = try? JSONDecoder().decode(RGBAColor.self, from: data) {
            self.currentRGBA = savedRGBA
            self.accentColor = savedRGBA.color
        } else {
            let defaultRGBA = ThemePresetColor.red.rgba
            self.currentRGBA = defaultRGBA
            self.accentColor = defaultRGBA.color
        }

        updateUIKitAppearance()
    }

    func setAccentColor(_ color: Color) {
        let rgba = extractRGBA(from: color)
        self.currentRGBA = rgba
        self.accentColor = color
        saveAccentColor(rgba)
        updateUIKitAppearance()
    }

    func resetToDefaults() {
        self.colorSchemeOption = .system
        let defaultRGBA = ThemePresetColor.red.rgba
        self.currentRGBA = defaultRGBA
        self.accentColor = defaultRGBA.color
        saveAccentColor(defaultRGBA)
        updateUIKitAppearance()
    }

    func isMatchingPreset(_ preset: ThemePresetColor) -> Bool {
        preset.rgba.isClose(to: currentRGBA)
    }

    func contrastTextColor(for color: Color) -> Color {
        let rgba = extractRGBA(from: color)
        return rgba.contrastTextColor
    }

    private func saveAccentColor(_ rgba: RGBAColor) {
        if let encoded = try? JSONEncoder().encode(rgba) {
            UserDefaults.standard.set(encoded, forKey: accentColorKey)
        }
    }

    private func extractRGBA(from color: Color) -> RGBAColor {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return RGBAColor(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
        }
        var white: CGFloat = 0
        if uiColor.getWhite(&white, alpha: &a) {
            return RGBAColor(red: Double(white), green: Double(white), blue: Double(white), alpha: Double(a))
        }
        return ThemePresetColor.red.rgba
    }

    func updateUIKitAppearance() {
        let uiColor = currentRGBA.uiColor
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            for window in windowScene.windows {
                window.tintColor = uiColor
            }
        }
    }
}
