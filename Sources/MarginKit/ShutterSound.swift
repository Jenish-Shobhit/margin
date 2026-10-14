import AudioToolbox
import Foundation

/// The system "Screen Capture" sound at the alert volume. Silent when UI sound effects are off.
public enum ShutterSound {
    private static let url = URL(fileURLWithPath:
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif")

    @MainActor private static var soundID: SystemSoundID = {
        var id: SystemSoundID = 0
        AudioServicesCreateSystemSoundID(url as CFURL, &id)
        return id
    }()

    public static var uiSoundsEnabled: Bool {
        let v = CFPreferencesCopyAppValue("com.apple.sound.uiaudio.enabled" as CFString, kCFPreferencesAnyApplication) as? NSNumber
        return v?.boolValue ?? true
    }

    @MainActor public static func play() {
        guard uiSoundsEnabled else { return }
        AudioServicesPlaySystemSound(soundID)
    }
}
