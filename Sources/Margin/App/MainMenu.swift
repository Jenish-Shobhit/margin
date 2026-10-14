import AppKit

/// The app's main menu. Margin is an accessory app, so this menu bar is never shown, but AppKit still
/// matches key equivalents against it. That's what gives text fields (the shelf's rename field, Settings)
/// ⌘X ⌘C ⌘V ⌘A ⌘Z ⇧⌘Z, and Margin's windows ⌘W and ⌘Q; without a main menu those keys only beep.
///
/// It doesn't take keys away from the shelf. AppKit offers a key equivalent to the key window's views
/// (`performKeyEquivalent`) before the main menu, and the shelf's root view answers ⌘C ⌘Z ⌘A itself
/// unless its rename field is editing. Even if the menu did get there first, Copy/Undo/Select All send
/// `copy:`/`undo:`/`selectAll:` down the responder chain, which the shelf's root view also implements.
/// The reverse matters too: see `UndoTarget` for why ⌘Z in the rename field doesn't reach the shelf.
@MainActor
enum MainMenu {
    static func install() {
        NSApp.mainMenu = make()
    }

    private static func make() -> NSMenu {
        let main = NSMenu(title: "Main Menu")

        // The first item's submenu is the application menu.
        let app = NSMenu(title: "Margin")
        let quit = NSMenuItem(title: "Quit Margin", action: #selector(QuitTarget.quitIfActive(_:)), keyEquivalent: "q")
        quit.target = QuitTarget.shared
        app.addItem(quit)
        main.addItem(submenuItem(app))

        let file = NSMenu(title: "File")
        file.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(submenuItem(file))

        let edit = NSMenu(title: "Edit")
        let undo = NSMenuItem(title: "Undo", action: UndoTarget.undoAction, keyEquivalent: "z")
        undo.target = UndoTarget.shared
        edit.addItem(undo)
        // "Z" with ⌘ is ⇧⌘Z: a real ⇧⌘Z event's characters are "Z". ("z" with ⇧⌘ doesn't match it, and
        // matches a plain ⌘Z instead.)
        let redo = NSMenuItem(title: "Redo", action: UndoTarget.redoAction, keyEquivalent: "Z")
        redo.target = UndoTarget.shared
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(submenuItem(edit))

        return main
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// Undo and Redo. While a text view is first responder (the shelf's rename field, a Settings field), its
    /// own undo manager answers. A plain nil-targeted `undo:` would walk up from the field editor to the first
    /// responder that implements it: only `NSWindow` does among AppKit's classes, but the shelf's root view
    /// sits in between and its `undo:` restores a removed card. Everywhere else `undo:`/`redo:` go down the
    /// responder chain as usual, so the shelf still gets them.
    @MainActor
    final class UndoTarget: NSObject, NSMenuItemValidation {
        static let shared = UndoTarget()
        static let undoAction = #selector(UndoTarget.undo(_:))
        static let redoAction = #selector(UndoTarget.redo(_:))

        @objc func undo(_ sender: Any?) { perform(Self.undoAction, sender) }
        @objc func redo(_ sender: Any?) { perform(Self.redoAction, sender) }

        private var editedText: NSText? { NSApp.keyWindow?.firstResponder as? NSText }

        private func perform(_ action: Selector, _ sender: Any?) {
            if let text = editedText {
                guard let manager = text.undoManager else { return }
                if action == Self.undoAction {
                    if manager.canUndo { manager.undo() }
                } else if manager.canRedo {
                    manager.redo()
                }
                return
            }
            NSApp.sendAction(action, to: nil, from: sender)
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            guard let action = menuItem.action else { return false }
            if let text = editedText {
                guard let manager = text.undoManager else { return false }
                return action == Self.undoAction ? manager.canUndo : manager.canRedo
            }
            // Whoever would receive it in the responder chain decides (NSWindow checks its undo manager).
            guard let target = NSApp.target(forAction: action) as? NSObject, target !== self else { return false }
            return (target as? NSMenuItemValidation)?.validateMenuItem(menuItem) ?? true
        }
    }

    /// ⌘Q quits only while Margin is the frontmost app (Settings or the welcome window in front). The shelf
    /// becomes key *without* activating Margin, and the menu bar still shows the other app's menus: after a
    /// ⌘-click or ✕ on a card (which give the shelf the keys; a plain click doesn't), ⌘Q is meant for that
    /// app, so it must not quit Margin.
    ///
    /// `NSApp.isActive` can't tell these apart: it turns true as soon as the non-activating panel is key.
    /// `NSRunningApplication.current.isActive` stays false then (checked on macOS 27), and is true only
    /// when Margin is really frontmost.
    @MainActor
    final class QuitTarget: NSObject, NSMenuItemValidation {
        static let shared = QuitTarget()

        private var isFrontmost: Bool { NSRunningApplication.current.isActive }

        @objc func quitIfActive(_ sender: Any?) {
            guard isFrontmost else { return }
            NSApp.terminate(sender)
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isFrontmost }
    }
}
