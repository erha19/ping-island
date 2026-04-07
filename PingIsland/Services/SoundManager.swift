import AppKit
import Foundation

/// Plays 8-bit sound effects in response to hook events
@MainActor
class SoundManager {
    static let shared = SoundManager()

    private let defaults = UserDefaults.standard
    
    /// Sound event mappings
    struct SoundEvent {
        let event: String
        let sound: String
        let key: String
    }
    
    /// Map event names to 8-bit WAV file names (without extension)
    static let eventSounds: [SoundEvent] = [
        SoundEvent(event: "SessionStart", sound: "8bit_start", key: "soundSessionStart"),
        SoundEvent(event: "Stop", sound: "8bit_complete", key: "soundTaskComplete"),
        SoundEvent(event: "PostToolUseFailure", sound: "8bit_error", key: "soundTaskError"),
        SoundEvent(event: "PermissionRequest", sound: "8bit_approval", key: "soundApprovalNeeded"),
        SoundEvent(event: "UserPromptSubmit", sound: "8bit_submit", key: "soundPromptSubmit"),
    ]

    private var soundCache: [String: NSSound] = [:]

    private init() {
        // Pre-load all sounds into cache
        for entry in Self.eventSounds {
            if let sound = loadSound(entry.sound) {
                soundCache[entry.sound] = sound
            }
        }
        // Also load boot sound
        if let bootSound = loadSound("8bit_boot") {
            soundCache["8bit_boot"] = bootSound
        }
    }

    /// Called from AppState.handleEvent() to trigger appropriate sounds
    func handleEvent(_ eventName: String) {
        guard defaults.bool(forKey: "soundEnabled") else { return }
        guard let entry = Self.eventSounds.first(where: { $0.event == eventName }) else { return }
        guard defaults.bool(forKey: entry.key) else { return }
        play(entry.sound)
    }

    /// Play boot sound on app launch
    func playBoot() {
        guard defaults.bool(forKey: "soundEnabled") else { return }
        guard defaults.bool(forKey: "soundBoot") else { return }
        play("8bit_boot")
    }

    /// Preview a specific sound (used by settings UI play buttons)
    func preview(_ soundName: String) {
        play(soundName)
    }

    /// Play a named 8-bit WAV with volume control
    private func play(_ name: String) {
        guard let sound = soundCache[name] ?? loadSound(name) else {
            NSSound.beep()
            return
        }
        if sound.isPlaying { sound.stop() }
        let volume = defaults.integer(forKey: "soundVolume")
        sound.volume = Float(volume) / 100.0
        sound.play()
    }

    /// Load a WAV from the app bundle
    private func loadSound(_ name: String) -> NSSound? {
        // Try Resources/Sounds directory
        if let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds") {
            return NSSound(contentsOf: url, byReference: false)
        }
        // Fallback: try Resources directory
        if let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            return NSSound(contentsOf: url, byReference: false)
        }
        print("[SoundManager] Failed to load sound: \(name)")
        return nil
    }
}