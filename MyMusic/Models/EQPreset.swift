import Foundation

/// Модель пресета 10-полосного эквалайзера
struct EQPreset: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// Значения гейна в дБ для 10 полос (-12.0 ... +12.0 дБ)
    /// Частоты: [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] Гц
    var gains: [Float]
    var isCustom: Bool = false

    /// Стандартные встроенные пресеты
    static let builtInPresets: [EQPreset] = [
        EQPreset(name: "Flat", gains: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]),
        EQPreset(name: "Bass Boost", gains: [5.5, 5.0, 4.0, 2.5, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0]),
        EQPreset(name: "Treble Boost", gains: [0.0, 0.0, 0.0, 0.0, 0.5, 1.5, 3.0, 4.5, 5.5, 6.0]),
        EQPreset(name: "Vocal", gains: [-2.0, -1.0, 0.5, 2.5, 4.0, 3.5, 2.0, 0.5, -1.0, -2.0]),
        EQPreset(name: "Rock", gains: [4.5, 3.5, 2.0, 0.0, -1.0, 0.0, 2.0, 3.5, 4.5, 5.0]),
        EQPreset(name: "Pop", gains: [-1.0, 1.5, 3.0, 3.5, 2.5, 1.0, 0.5, 1.5, 2.5, 3.0]),
        EQPreset(name: "Jazz", gains: [3.0, 2.0, 1.0, 1.5, -1.0, -1.0, 0.0, 1.5, 2.5, 3.0]),
        EQPreset(name: "Classical", gains: [4.5, 3.5, 2.5, 1.5, -0.5, -0.5, 0.5, 2.0, 3.5, 4.0]),
        EQPreset(name: "Electronic", gains: [5.0, 4.5, 2.0, 0.0, -1.5, 1.5, 1.0, 2.0, 4.0, 4.5])
    ]

    /// Частоты 10 полос
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    /// Текстовые метки частот для интерфейса
    static let frequencyLabels: [String] = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
}
