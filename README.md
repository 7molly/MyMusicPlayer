# MyMusicPlayer 🎵

Аутентичный музыкальный плеер для iOS в эталонном дизайне Apple Music (SwiftUI, iOS 16+, `AVAudioEngine`).

## Основные возможности

- **Интерактивный плеер**: Плавная spring-анимация открытия и закрытия со смахиванием вниз (gesture follow-through) точно как в Apple Music (60 FPS на iPhone 8 Plus).
- **Плавающий мини-плеер**: Закреплён над навигационной панелью с быстрым управлением Play/Pause и переключением треков.
- **Аудиодвижок `AVAudioEngine`**: 
  - Высокая производительность и низкая задержка.
  - Токенизация поколений воспроизведения (`generation tokens`) для исключения гонок при быстром переключении треков.
  - Управление скоростью воспроизведения (Speed) и тональностью (Pitch).
  - 10-полосный эквалайзер с пресетами (Acoustic, Bass Booster, Electronic, Rock и др.).
- **Интеграция с системой**:
  - `MPRemoteCommandCenter` и `MPNowPlayingInfoCenter` (управление на экране блокировки, в Пункте управления и с наушников).
  - Фоновое воспроизведение через `AVAudioSession` (`.playback`).
  - Поддержка AirPlay.
- **Медиатека**:
  - Разделы: «Медиатека» (Песни), «Альбомы», «Эквалайзер», «Настройки».
  - Поддержка пользовательских плейлистов.
  - Встроенный импорт треков из SoundCloud.
  - Двухуровневый кэш обложек (RAM NSCache + Disk ImageIO downsampling) с разрешением до 2000×2000 px.

## Стек технологий

- **Язык**: Swift 5.9+
- **Интерфейс**: SwiftUI (iOS 16+)
- **Аудио**: AVFoundation (`AVAudioEngine`, `AVAudioPlayerNode`, `AVAudioUnitEQ`, `AVAudioUnitTimePitch`)
- **Система**: MediaPlayer (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`)
- **Кэширование**: CryptoKit (SHA-256), ImageIO, CoreGraphics

## Требования

- iOS 16.0+
- Xcode 15.0+
- Поддерживаются iPhone с кнопкой «Домой» (iPhone 8 / 8 Plus, iPhone SE) и устройства с вырезом / Dynamic Island (iPhone X ... iPhone 16 Pro).
