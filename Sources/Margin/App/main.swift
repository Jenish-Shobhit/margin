import AppKit

// Menu bar app: no Dock icon (LSUIElement in Info.plist; set here too for bare `swift run` builds).
let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
