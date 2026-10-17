import AudioToolbox
import Foundation

/// The system "Screen Capture" sound at the alert volume. Silent when UI sound effects are off.
/// (The caller checks `Preferences.shutterSound`.)
public enum ShutterSound {
    private static let soundsFolder = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"

    /// "Screen Capture.aif" is what macOS plays for screenshots; "Shutter.aif" is a fallback if it's ever renamed.
    static var url: URL? {
        ["Screen Capture.aif", "Shutter.aif"]
            .map { URL(fileURLWithPath: soundsFolder + $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Created once. A system sound ID plays through the system sound server at the alert volume, and
    /// (`kAudioServicesPropertyIsUISound` defaults to 1) is muted when UI sound effects are off.
    @MainActor private static let soundID: SystemSoundID? = {
        guard let url else { return nil }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return nil }
        return id
    }()

    /// "Play user interface sound effects" (System Settings › Sound). A missing key means on.
    public static var uiSoundsEnabled: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let v = CFPreferencesCopyAppValue("com.apple.sound.uiaudio.enabled" as CFString, kCFPreferencesAnyApplication) as? NSNumber
        return v?.boolValue ?? true
    }

    @MainActor public static func play() {
        guard uiSoundsEnabled, let soundID else { return }
        AudioServicesPlaySystemSound(soundID)
    }

    /// The short tick a screen recording starts with (macOS's own "begin_record"), instead of the shutter. Silent when UI
    /// sound effects are off, like the shutter.
    @MainActor public static func playRecordingStart() {
        guard uiSoundsEnabled, let recordingStartID else { return }
        AudioServicesPlaySystemSound(recordingStartID)
    }

    @MainActor private static let recordingStartID: SystemSoundID? = {
        let url = URL(fileURLWithPath: soundsFolder + "begin_record.caf")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return nil }
        return id
    }()
}
