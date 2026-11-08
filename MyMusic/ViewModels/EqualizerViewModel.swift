import Foundation
import Combine
import SwiftUI

/// ViewModel для управления 10-полосным эквалайзером и строем A4
@MainActor
final class EqualizerViewModel: ObservableObject {
    static let shared = EqualizerViewModel()

    private let audioEngine = AudioEngineManager.shared
    private var cancellables = Set<AnyCancellable>()

    @Published var isEQEnabled: Bool = true {
        didSet {
            audioEngine.isEQEnabled = isEQEnabled
        }
    }

    @Published var gains: [Float] = Array(repeating: 0.0, count: 10)

    @Published var selectedPresetName: String = "Flat"
    @Published var customPresets: [EQPreset] = []

    // MARK: - Скорость и Тональность
    @Published var playbackRate: Float = 1.0 {
        didSet {
            audioEngine.setPlaybackRate(playbackRate)
        }
    }

    @Published var pitchShift: Float = 0.0 {
        didSet {
            audioEngine.setPitchShift(pitchShift)
        }
    }

    var pitchShiftCents: Float {
        audioEngine.pitchShiftCents
    }

    private let customPresetsKey = "EQ_Custom_Presets_List"

    private init() {
        self.isEQEnabled = audioEngine.isEQEnabled
        self.gains = audioEngine.eqGains
        self.playbackRate = audioEngine.playbackRate
        self.pitchShift = audioEngine.pitchShift
        loadCustomPresets()
        detectCurrentPreset()

        // Подписка на обновления из движка
        audioEngine.$eqGains
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newGains in
                guard let self = self else { return }
                if self.gains != newGains {
                    self.gains = newGains
                    self.detectCurrentPreset()
                }
            }
            .store(in: &cancellables)

        audioEngine.$playbackRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newRate in
                guard let self = self else { return }
                if abs(self.playbackRate - newRate) > 0.001 {
                    self.playbackRate = newRate
                }
            }
            .store(in: &cancellables)

        audioEngine.$pitchShift
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newPitch in
                guard let self = self else { return }
                if abs(self.pitchShift - newPitch) > 0.01 {
                    self.pitchShift = newPitch
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Управление полосами эквалайзера
    func setGain(bandIndex: Int, gain: Float) {
        guard bandIndex >= 0 && bandIndex < 10 else { return }
        gains[bandIndex] = gain
        audioEngine.setEQGain(bandIndex: bandIndex, gain: gain)
        detectCurrentPreset()
    }

    func selectPreset(_ preset: EQPreset) {
        selectedPresetName = preset.name
        gains = preset.gains
        audioEngine.applyPreset(preset)
    }

    func resetEQ() {
        selectedPresetName = "Flat"
        audioEngine.resetEQ()
        gains = Array(repeating: 0.0, count: 10)
    }

    // MARK: - Пользовательские пресеты
    func saveCustomPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Если с таким именем уже есть, заменяем
        customPresets.removeAll { $0.name.lowercased() == trimmed.lowercased() }
        let newPreset = EQPreset(name: trimmed, gains: gains, isCustom: true)
        customPresets.append(newPreset)
        selectedPresetName = trimmed
        persistCustomPresets()
    }

    func deleteCustomPreset(_ preset: EQPreset) {
        customPresets.removeAll { $0.id == preset.id }
        persistCustomPresets()
        if selectedPresetName == preset.name {
            selectPreset(EQPreset.builtInPresets[0])
        }
    }

    private func persistCustomPresets() {
        if let encoded = try? JSONEncoder().encode(customPresets) {
            UserDefaults.standard.set(encoded, forKey: customPresetsKey)
        }
    }

    private func loadCustomPresets() {
        if let data = UserDefaults.standard.data(forKey: customPresetsKey),
           let list = try? JSONDecoder().decode([EQPreset].self, from: data) {
            self.customPresets = list
        }
    }

    private func detectCurrentPreset() {
        let all = EQPreset.builtInPresets + customPresets
        if let matched = all.first(where: { $0.gains == gains }) {
            selectedPresetName = matched.name
        } else {
            selectedPresetName = "Вручную"
        }
    }

    // MARK: - Управление скоростью и тональностью
    var speedPercent: Int {
        Int(round(playbackRate * 100))
    }

    func setRate(_ rate: Float) {
        audioEngine.setPlaybackRate(rate)
    }

    func setPitch(_ semitones: Float) {
        audioEngine.setPitchShift(semitones)
    }

    func incrementPitch() {
        audioEngine.incrementPitch()
    }

    func decrementPitch() {
        audioEngine.decrementPitch()
    }

    func resetPitch() {
        audioEngine.resetPitch()
    }

    func incrementSpeed(by percent: Int = 1) {
        let newRate = playbackRate + (Float(percent) / 100.0)
        audioEngine.setPlaybackRate(newRate)
    }

    func decrementSpeed(by percent: Int = 1) {
        let newRate = playbackRate - (Float(percent) / 100.0)
        audioEngine.setPlaybackRate(newRate)
    }

    func resetSpeed() {
        audioEngine.resetSpeed()
    }

    func resetSpeedAndPitch() {
        audioEngine.resetSpeedAndPitch()
    }

    func applyCombo(rate: Float, pitch: Float) {
        audioEngine.setPlaybackRate(rate)
        audioEngine.setPitchShift(pitch)
    }
}
