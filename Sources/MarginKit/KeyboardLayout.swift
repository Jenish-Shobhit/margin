import Carbon.HIToolbox
import Foundation
import Synchronization

/// What the character keys type on the user's keyboard layout, so a shortcut reads the way its keys are labelled:
/// key code 0x10 is Y on a US keyboard but Z on a German one, and 0x0C is Q in the US but A in France.
///
/// Text Input Sources may only be read on the main thread, so the app takes a snapshot (`update()`) at launch and
/// whenever the input source changes (`startObserving()`); naming a key only reads the snapshot, from any thread.
/// With no snapshot (tests, or before launch) every key has its US name.
public final class KeyboardLayout: Sendable {
    /// The layout the app names shortcuts with.
    public static let current = KeyboardLayout()
    /// Never reads a layout: every key keeps its US name.
    public static let us = KeyboardLayout()
    /// Posted on the main thread when `current` changed to another layout.
    public static let didChange = Notification.Name("MarginKeyboardLayoutDidChange")

    /// What a key types with no modifiers (`shift` false) or with ⇧; nil when it types nothing.
    public typealias Translate = @Sendable (_ keyCode: UInt32, _ shift: Bool) -> String?

    private struct Snapshot: Sendable {
        /// The input source ID, e.g. `com.apple.keylayout.German`.
        let id: String
        let translate: Translate
    }

    private let snapshot: Mutex<Snapshot?>
    private let isObserving = Mutex(false)

    /// No layout yet: every key has its US name until `update()`.
    public init() {
        snapshot = Mutex(nil)
    }

    /// A fixed layout, for tests.
    public init(id: String = "test", translate: @escaping Translate) {
        snapshot = Mutex(Snapshot(id: id, translate: translate))
    }

    /// An installed keyboard layout by input source ID (`com.apple.keylayout.French`), whether or not it's enabled.
    @MainActor
    public convenience init?(inputSourceID id: String) {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first, let snapshot = Self.snapshot(of: source) else { return nil }
        self.init(id: snapshot.id, translate: snapshot.translate)
    }

    /// The input source the snapshot came from; nil before `update()`.
    public var inputSourceID: String? { snapshot.withLock { $0?.id } }

    /// Re-reads the layout macOS names shortcuts with: the current input source when it types Latin letters,
    /// otherwise the last one that did (as menus do for a Russian or Greek layout). Main thread only.
    @MainActor
    public func update() {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let fresh = Self.snapshot(of: source) else { return }
        let changed = snapshot.withLock { current -> Bool in
            defer { current = fresh }
            return current?.id != fresh.id
        }
        if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    /// Takes a snapshot now and again whenever the user switches input source, for as long as the app runs.
    @MainActor
    public func startObserving() {
        update()
        guard !isObserving.withLock({ observing in defer { observing = true }; return observing }) else { return }
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        _ = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    /// The name of a character key on this layout: what it types, upper-cased ("Z", "Ö", "ß"). A key that types a
    /// symbol unshifted and a digit with ⇧ (the French digit row) is named by the digit, as macOS does. Nil when
    /// there's no snapshot or the key types nothing printable.
    public func characterName(for keyCode: UInt32) -> String? {
        guard let translate = snapshot.withLock({ $0?.translate }) else { return nil }
        guard let plain = translate(keyCode, false).flatMap(Self.printable) else { return nil }
        if !Self.isDigit(plain), let shifted = translate(keyCode, true).flatMap(Self.printable), Self.isDigit(shifted) {
            return shifted
        }
        let upper = plain.uppercased()
        return upper.count == 1 ? upper : plain
    }

    // MARK: Text Input Sources

    private static func snapshot(of source: TISInputSource) -> Snapshot? {
        guard let id = string(source, kTISPropertyInputSourceID),
              let dataRef = property(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(dataRef).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        return Snapshot(id: id) { keyCode, shift in translate(data, keyCode: keyCode, shift: shift, keyboardType: keyboardType) }
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> UnsafeMutableRawPointer? {
        TISGetInputSourceProperty(source, key)
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        property(source, key).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    }

    /// `UCKeyTranslate` with dead keys off, so ^ or ´ come back as themselves.
    private static func translate(_ layout: Data, keyCode: UInt32, shift: Bool, keyboardType: UInt32) -> String? {
        layout.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
            let status = UCKeyTranslate(base, UInt16(keyCode), UInt16(kUCKeyActionDisplay), modifiers, keyboardType,
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    /// One visible character: not a space, a control character or empty.
    private static func printable(_ s: String) -> String? {
        guard s.count == 1, let scalar = s.unicodeScalars.first,
              !scalar.properties.isWhitespace, scalar.properties.generalCategory != .control else { return nil }
        return s
    }

    private static func isDigit(_ s: String) -> Bool {
        s.count == 1 && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }
}
