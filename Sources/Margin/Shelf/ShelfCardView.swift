import AppKit
import MarginKit
import QuartzCore

/// One shot on the shelf. Layer-backed; every visual lives on `body`, a layer we own, so we can
/// spring it (move, hover, collapse, swipe) without fighting AppKit over the backing layer.
/// The view's frame is always the card's final slot, so hit testing never lags the animation.
@MainActor
final class ShelfCardView: NSView, NSTextFieldDelegate {
    weak var controller: ShelfController?
    private(set) var item: ShelfItem
    var id: UUID { item.id }

    let body = CALayer.shelfQuiet()
    private let ring = CALayer.shelfQuiet()
    private let imageLayer = CALayer.shelfQuiet()
    private let border = CALayer.shelfQuiet()
    private let chrome = CALayer.shelfQuiet()
    private let gradient = shelfQuiet(CAGradientLayer())
    private let metaText = shelfQuiet(CATextLayer())
    private let closeChip = CALayer.shelfQuiet()
    private let moreChip = CALayer.shelfQuiet()
    private let check = CALayer.shelfQuiet()
    private let pill = CALayer.shelfQuiet()
    private let pillText = shelfQuiet(CATextLayer())
    /// A recording's play glyph and length (bottom-left), there unless the hover chrome is (its meta line has the length).
    private let playBadge = CALayer.shelfQuiet()
    private let playGlyph = shelfQuiet(CAShapeLayer())
    private let playText = shelfQuiet(CATextLayer())

    private(set) var isHovered = false
    private(set) var isSelected = false
    private(set) var isMarked = false
    private(set) var isInPile = false
    private(set) var isDragging = false
    private var isNew = false
    private(set) var isLeaving = false
    private var placed = false
    /// False until the card has been put in a slot once (a fresh card never animates in from nowhere).
    var isPlaced: Bool { placed }
    private var swipeX: CGFloat = 0
    private var newRingTask: Task<Void, Never>?
    private var tracking: NSTrackingArea?
    /// ✕ and ••• for assistive apps (`ShelfAccessibility.swift`).
    private(set) lazy var accessibilityParts = [ShelfCardPart(card: self, kind: .close), ShelfCardPart(card: self, kind: .options)]

    init(item: ShelfItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        buildLayers()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layers

    private func buildLayers() {
        guard let root = layer else { return }
        body.shadowColor = NSColor.black.cgColor
        body.shadowOpacity = 0.4
        body.shadowRadius = 12
        body.shadowOffset = CGSize(width: 0, height: -8)
        root.addSublayer(body)

        ring.borderWidth = 2
        ring.borderColor = ShelfStyle.ring.cgColor
        ring.cornerRadius = ShelfStyle.cornerRadius + 2
        ring.cornerCurve = .continuous
        ring.opacity = 0
        body.addSublayer(ring)

        imageLayer.cornerRadius = ShelfStyle.cornerRadius
        imageLayer.cornerCurve = .continuous
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        body.addSublayer(imageLayer)

        border.cornerRadius = ShelfStyle.cornerRadius
        border.cornerCurve = .continuous
        border.borderWidth = 1
        body.addSublayer(border)

        playBadge.cornerRadius = 6
        playBadge.backgroundColor = ShelfStyle.chip.cgColor
        playBadge.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        playBadge.borderWidth = 1
        let triangle = CGMutablePath()
        triangle.move(to: CGPoint(x: 0, y: 0)); triangle.addLine(to: CGPoint(x: 0, y: 8)); triangle.addLine(to: CGPoint(x: 7, y: 4))
        triangle.closeSubpath()
        playGlyph.path = triangle
        playGlyph.fillColor = NSColor.white.cgColor
        playBadge.addSublayer(playGlyph)
        playText.alignmentMode = .left
        playBadge.addSublayer(playText)
        playBadge.isHidden = true
        body.addSublayer(playBadge)

        // Selection check (top-left), under the hover chrome: on hover it gives way to the options button.
        check.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        check.cornerRadius = 9
        check.backgroundColor = ShelfStyle.accent.cgColor
        check.borderColor = NSColor.white.cgColor
        check.borderWidth = 2
        check.opacity = 0
        let tick = shelfQuiet(CAShapeLayer())
        let tp = CGMutablePath()
        tp.move(to: CGPoint(x: 5.2, y: 9.2)); tp.addLine(to: CGPoint(x: 7.9, y: 6.4)); tp.addLine(to: CGPoint(x: 12.8, y: 11.8))
        tick.path = tp
        tick.strokeColor = NSColor.white.cgColor
        tick.fillColor = nil
        tick.lineWidth = 1.8
        tick.lineCap = .round
        tick.lineJoin = .round
        tick.frame = check.bounds
        check.addSublayer(tick)
        body.addSublayer(check)

        // Hover chrome: bottom gradient + meta line, options (top-left) and ✕ (top-right). Faded as one.
        chrome.cornerRadius = ShelfStyle.cornerRadius
        chrome.cornerCurve = .continuous
        chrome.masksToBounds = true
        chrome.opacity = 0
        gradient.colors = [NSColor.black.withAlphaComponent(0.75).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        chrome.addSublayer(gradient)
        metaText.foregroundColor = NSColor.white.cgColor
        metaText.truncationMode = .end
        metaText.isWrapped = false
        chrome.addSublayer(metaText)

        // ✕ (dismiss): a red circle with a white cross. The white rim and shadow keep it legible on any shot.
        let d = Self.buttonDiameter
        styleChip(closeChip, size: CGSize(width: d, height: d))
        closeChip.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        let x = shelfQuiet(CAShapeLayer())
        let xp = CGMutablePath()
        let a = d / 2 - 3.4, b = d / 2 + 3.4
        xp.move(to: CGPoint(x: a, y: a)); xp.addLine(to: CGPoint(x: b, y: b))
        xp.move(to: CGPoint(x: a, y: b)); xp.addLine(to: CGPoint(x: b, y: a))
        x.path = xp
        x.strokeColor = NSColor.white.cgColor
        x.lineWidth = 2
        x.lineCap = .round
        x.frame = closeChip.bounds
        closeChip.addSublayer(x)
        chrome.addSublayer(closeChip)

        // Options: a dark circle with an ellipsis (like SF Symbols' ellipsis.circle.fill).
        styleChip(moreChip, size: CGSize(width: d, height: d))
        moreChip.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        let dots = shelfQuiet(CAShapeLayer())
        let dp = CGMutablePath()
        for cx in [d / 2 - 4.6, d / 2, d / 2 + 4.6] { dp.addEllipse(in: CGRect(x: cx - 1.4, y: d / 2 - 1.4, width: 2.8, height: 2.8)) }
        dots.path = dp
        dots.fillColor = NSColor.white.cgColor
        dots.frame = moreChip.bounds
        moreChip.addSublayer(dots)
        chrome.addSublayer(moreChip)
        body.addSublayer(chrome)

        // ⌘V pill (bottom-right), above everything.
        pill.cornerRadius = 6
        pill.backgroundColor = ShelfStyle.accent.cgColor
        pill.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        pill.borderWidth = 1
        pill.shadowColor = NSColor.black.cgColor
        pill.shadowOpacity = 0.35
        pill.shadowRadius = 3
        pill.shadowOffset = CGSize(width: 0, height: -2)
        pill.opacity = 0
        pill.transform = CATransform3DMakeScale(0.6, 0.6, 1)
        pillText.string = NSAttributedString(string: "⌘V", attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: NSColor.white,
        ])
        pillText.alignmentMode = .center
        pill.addSublayer(pillText)
        body.addSublayer(pill)

        updateMeta()
        updateAppearanceColors()
    }

    /// Visible size of the hover buttons; their hit areas are larger (`buttonHitSize`).
    private static let buttonDiameter: CGFloat = 20
    private static let buttonHitSize: CGFloat = 28
    /// Inset of the hover buttons (and the selection check) from the card's top corners.
    private static let buttonInset: CGFloat = 6

    private func styleChip(_ l: CALayer, size: CGSize) {
        l.bounds = CGRect(origin: .zero, size: size)
        l.cornerRadius = size.height / 2
        l.backgroundColor = ShelfStyle.chip.cgColor
        l.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        l.borderWidth = 1
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.3
        l.shadowRadius = 2
        l.shadowOffset = CGSize(width: 0, height: -1)
        l.shadowPath = CGPath(ellipseIn: l.bounds, transform: nil)
    }

    private func layoutLayers() {
        let b = bounds
        let w = b.width, h = b.height
        body.bounds = b
        body.position = CGPoint(x: b.midX, y: b.midY)
        body.shadowPath = CGPath(roundedRect: b, cornerWidth: ShelfStyle.cornerRadius, cornerHeight: ShelfStyle.cornerRadius, transform: nil)
        ring.frame = b.insetBy(dx: -2, dy: -2)
        imageLayer.frame = b
        border.frame = b
        chrome.frame = b
        gradient.frame = CGRect(x: 0, y: 0, width: w, height: min(42, h))
        metaText.frame = CGRect(x: 9, y: 5, width: w - 18, height: 14)
        closeChip.position = CGPoint(x: closeHitRect.midX, y: closeHitRect.midY)
        moreChip.position = CGPoint(x: moreHitRect.midX, y: moreHitRect.midY)
        check.position = moreChip.position
        let textW = ceil((pillText.string as? NSAttributedString)?.size().width ?? 14)
        let ps = CGSize(width: textW + 12, height: 16)
        pill.bounds = CGRect(origin: .zero, size: ps)
        pill.position = CGPoint(x: w - 6 - ps.width / 2, y: 6 + ps.height / 2)
        pill.shadowPath = CGPath(roundedRect: pill.bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        pillText.frame = CGRect(x: 0, y: (ps.height - 12) / 2, width: ps.width, height: 12)
        let playW = ceil((playText.string as? NSAttributedString)?.size().width ?? 22)
        let bs = CGSize(width: 7 + 4 + playW + 14, height: 18)
        playBadge.frame = CGRect(x: 6, y: 6, width: bs.width, height: bs.height)
        playGlyph.frame = CGRect(x: 7, y: 5, width: 7, height: 8)
        playText.frame = CGRect(x: 18, y: (bs.height - 13) / 2, width: playW + 2, height: 13)
        renameBox?.frame = renameFrame
        removeAllToolTips()
        addToolTip(moreHitRect, owner: self, userData: nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        for l in [metaText, pillText, playText] { l.contentsScale = s }
        for l in [body, imageLayer, chrome] { l.contentsScale = s }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    private func updateAppearanceColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        border.borderColor = (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.14)).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            closeChip.backgroundColor = NSColor.systemRed.cgColor
        }
    }

    // MARK: - Content

    func update(item: ShelfItem) {
        self.item = item
        updateMeta()
    }

    func setThumbnail(_ image: CGImage) {
        imageLayer.contents = image
    }

    var thumbnail: CGImage? {
        guard let c = imageLayer.contents else { return nil }
        return (c as! CGImage)
    }

    private func updateMeta() {
        let time = ShelfStyle.metaFormatter.string(from: item.createdAt)
        let size = "\(item.pixelWidth) × \(item.pixelHeight)"
        let recording = item.kind == .recording
        let length = RecordingFormat.cardDurationText(item.duration ?? 0)
        let text = recording ? "\(time) · \(length) · \(size)" : "\(time) · \(size)"
        metaText.string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.white,
        ])
        playBadge.isHidden = !recording
        if recording {
            playText.string = NSAttributedString(string: length, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            layoutLayers()
        }
    }

    // MARK: - State

    /// Puts the card in its slot. Springs from the previous slot when `animated` (not while its fly-in is
    /// in the air: the flyer heads for the new slot, and the card must be there when it lands).
    func setSlot(_ frame: CGRect, animated: Bool) {
        let old = self.frame
        self.frame = frame
        if animated, placed, !isInPile, !isAwaitingFlyIn {
            ShelfMotion.slide(body, from: CGPoint(x: old.midX - frame.midX, y: old.midY - frame.midY))
        }
        placed = true
    }

    func setInPile(_ inPile: Bool, animated: Bool) {
        guard inPile != isInPile else { return }
        // Folding away mid-rename (a new shot pushed it up): keep what was typed, as clicking elsewhere does,
        // rather than leave an invisible field taking the keys, and give the keys back, as tucking does.
        if inPile, isRenaming {
            endRename(commit: true)
            controller?.releaseKeys()
        }
        isInPile = inPile
        if inPile, isHovered { isHovered = false; ShelfMotion.fade(chrome, to: 0, duration: 0) }
        if !inPile { isHidden = false }
        applyBody(animated: animated, duration: 0.35)
        if inPile {
            if animated && !ShelfStyle.reduceMotion {
                ShelfMotion.after(0.36) { [weak self] in if let self, self.isInPile { self.isHidden = true } }
            } else {
                isHidden = true
            }
        }
    }

    func setHovered(_ on: Bool) {
        guard on != isHovered, !isInPile, !isLeaving else { return }
        isHovered = on
        ShelfMotion.fade(chrome, to: on ? 1 : 0, duration: 0.2)
        if item.kind == .recording { ShelfMotion.fade(playBadge, to: on ? 0 : 1, duration: 0.2) }
        if isSelected { ShelfMotion.fade(check, to: on ? 0 : 1, duration: 0.2) }
        applyBody(animated: true)
    }

    func setSelected(_ on: Bool) {
        guard on != isSelected else { return }
        isSelected = on
        ShelfMotion.fade(check, to: on && !isHovered ? 1 : 0, duration: 0.2)
        updateRing()
    }

    func setMarked(_ on: Bool, animated: Bool) {
        guard on != isMarked else { return }
        isMarked = on
        let target = on ? CATransform3DIdentity : CATransform3DMakeScale(0.6, 0.6, 1)
        if animated && !ShelfStyle.reduceMotion {
            ShelfMotion.fade(pill, to: on ? 1 : 0, duration: 0.25)
            ShelfMotion.transform(pill, to: target, duration: 0.35, bounce: on ? 0.45 : 0)
        } else {
            pill.removeAllAnimations()
            pill.opacity = on ? 1 : 0
            pill.transform = target
        }
    }

    func setDragging(_ on: Bool) {
        guard on != isDragging else { return }
        isDragging = on
        if on, isHovered { isHovered = false; ShelfMotion.fade(chrome, to: 0, duration: 0.1) }
        applyBody(animated: true, duration: on ? 0.15 : 0.3)
    }

    /// 2 pt accent ring for 1.5 s.
    func flashNewRing() {
        isNew = true
        updateRing()
        newRingTask?.cancel()
        newRingTask = ShelfMotion.after(1.5) { [weak self] in
            self?.isNew = false
            self?.updateRing()
        }
    }

    private func updateRing() {
        ShelfMotion.fade(ring, to: (isNew || isSelected) ? 1 : 0, duration: 0.3)
    }

    /// Hidden while the fly-in is in the air (hover can't reveal it early); revealed at hand-off.
    private(set) var isAwaitingFlyIn = false

    func setAwaitingFlyIn(_ waiting: Bool) {
        isAwaitingFlyIn = waiting
        guard !isLeaving else { return }
        body.removeAnimation(forKey: "fade")
        body.removeAnimation(forKey: "opacity")
        body.opacity = targetOpacity
    }

    private var targetOpacity: Float { isAwaitingFlyIn || isInPile ? 0 : (isDragging ? 0.32 : 1) }

    private var targetTransform: CATransform3D {
        if isInPile {
            return CATransform3DConcat(CATransform3DMakeScale(0.9, 0.9, 1), CATransform3DMakeTranslation(0, 8, 0))
        }
        let s: CGFloat = isHovered ? 1.04 : 1
        return CATransform3DConcat(CATransform3DMakeScale(s, s, 1), CATransform3DMakeTranslation(swipeX, 0, 0))
    }

    private func applyBody(animated: Bool, duration: CFTimeInterval = 0.25) {
        if animated && !ShelfStyle.reduceMotion {
            ShelfMotion.transform(body, to: targetTransform, duration: 0.45, bounce: 0.25)
            ShelfMotion.fade(body, to: targetOpacity, duration: duration)
        } else {
            body.removeAnimation(forKey: "transform")
            body.transform = targetTransform
            ShelfMotion.fade(body, to: targetOpacity, duration: animated ? 0.15 : 0)
        }
    }

    /// Fades/springs in a card that was restored or came out of the pile.
    func appear() {
        isHidden = false
        guard !ShelfStyle.reduceMotion else { return }
        body.add(ShelfMotion.basic("opacity", from: 0, to: body.opacity, duration: 0.25), forKey: "appear")
        let from = CATransform3DMakeScale(0.9, 0.9, 1)
        body.add(ShelfMotion.spring("transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: body.transform), duration: 0.45, bounce: 0.25), forKey: "transform")
    }

    enum Exit { case collapse, swipe, fade }

    /// Animates the card out; the caller removes it from the hierarchy after `duration`.
    @discardableResult
    func leave(_ exit: Exit) -> Double {
        isLeaving = true
        isHovered = false
        newRingTask?.cancel()
        let style: Exit = ShelfStyle.reduceMotion ? .fade : exit
        switch style {
        case .collapse:
            let t = CATransform3DMakeScale(0.82, 0.82, 1)
            let from = body.presentation()?.transform ?? body.transform
            body.transform = t
            body.add(ShelfMotion.basic("transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: t), duration: 0.24, curve: .easeIn), forKey: "transform")
            ShelfMotion.fade(body, to: 0, duration: 0.22)
            return 0.24
        case .swipe:
            swipeX = bounds.width + 60
            let from = body.presentation()?.transform ?? body.transform
            let t = CATransform3DMakeTranslation(swipeX, 0, 0)
            body.transform = t
            body.add(ShelfMotion.basic("transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: t), duration: 0.25, curve: .easeIn), forKey: "transform")
            ShelfMotion.fade(body, to: 0, duration: 0.25)
            return 0.25
        case .fade:
            ShelfMotion.fade(body, to: 0, duration: 0.15)
            return 0.15
        }
    }

    // MARK: - Hit areas

    /// ✕, top-right. Each hit area is a square centered on its button, larger than the button.
    var closeHitRect: CGRect {
        let s = Self.buttonHitSize, edge = Self.buttonInset + Self.buttonDiameter / 2 + s / 2
        return CGRect(x: bounds.width - edge, y: bounds.height - edge, width: s, height: s)
    }

    /// Options, top-left.
    var moreHitRect: CGRect {
        let s = Self.buttonHitSize, edge = Self.buttonInset + Self.buttonDiameter / 2 + s / 2
        return CGRect(x: edge - s, y: bounds.height - edge, width: s, height: s)
    }

    /// Where the options menu pops up (its top-left corner), in this view's coordinates: just below the button.
    var moreMenuAnchor: CGPoint { CGPoint(x: Self.buttonInset, y: bounds.height - Self.buttonInset - Self.buttonDiameter - 4) }

    // MARK: - Mouse

    private enum Press { case none, card, close, more }
    private var press: Press = .none
    private var downEvent: NSEvent?
    /// The press moved past the drag threshold: it's a drag from then on, never a click.
    private var didDrag = false
    /// A drag that crossed the threshold before the shot's file was written: the latest drag event, kept until
    /// the drag can start (`fileDidLand`, or the next mouse move once the file is there).
    private var dragAwaitingFile: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// A press never makes the panel key: on mouse-up the controller decides (`focusShelf`), and only for the
    /// clicks whose next step is a shelf key. A click (copy), a double-click (open) or a drag into another app
    /// leaves that app's typing focus alone.
    override var needsPanelToBecomeKey: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { controller?.cardHover(self, inside: true) }
    override func mouseExited(with event: NSEvent) { controller?.cardHover(self, inside: false) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            if let menu = controller?.menu(for: self) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            press = .none
            return
        }
        downEvent = event
        didDrag = false
        dragAwaitingFile = nil
        // Spec §4 "check when a drag starts": the background check usually lands before the drag begins.
        controller?.refreshFiles()
        let p = convert(event.locationInWindow, from: nil)
        if isHovered, closeHitRect.contains(p) { press = .close }
        else if isHovered, moreHitRect.contains(p) { press = .more }
        else { press = .card }
    }

    override func mouseDragged(with event: NSEvent) {
        guard press == .card, let down = downEvent else { return }
        if !didDrag {
            let a = down.locationInWindow, b = event.locationInWindow
            guard hypot(b.x - a.x, b.y - a.y) >= 4 else { return }
            didDrag = true
        } else if dragAwaitingFile == nil {
            return   // the drag has started (or can't)
        }
        startDrag(event)
    }

    /// Starts the drag, unless the shot is still being written (a fresh capture: a busy encode can take a
    /// second). Then the gesture isn't lost: the drag starts on the next mouse move once the file is there, or
    /// as soon as it lands (`fileDidLand`) if the button is still down. A release before that does nothing.
    private func startDrag(_ event: NSEvent) {
        guard let controller else { return }
        if controller.pending.contains(id) {
            dragAwaitingFile = event
            return
        }
        dragAwaitingFile = nil
        controller.beginDrag(from: self, event: event)
    }

    /// The shot's file is on disk (`ShelfController.markReady`): a drag that was waiting for it starts now.
    func fileDidLand() {
        guard let event = dragAwaitingFile else { return }
        guard press == .card, NSEvent.pressedMouseButtons & 1 != 0 else {
            dragAwaitingFile = nil
            return
        }
        startDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil; press = .none; dragAwaitingFile = nil }
        guard !didDrag else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.insetBy(dx: -4, dy: -4).contains(p), press != .none else { return }
        // Only ✕ and ⌘-click take the keys (⌘Z, ⌫, Space, ⌘C come next); the menu's Rename… and Move to Trash
        // take them when chosen. A click copies and a double-click opens: the keyboard stays with the user's app.
        switch press {
        case .none:
            return
        case .close:
            controller?.removeFromShelf(id)
        case .more:
            if let menu = controller?.menu(for: self) {
                menu.popUp(positioning: nil, at: moreMenuAnchor, in: self)
            }
        case .card:
            if event.modifierFlags.contains(.command) {
                controller?.focusShelf()
                controller?.toggleSelection(id)
            } else if event.clickCount == 2 {
                controller?.open(id)
            } else if event.clickCount == 1 {
                controller?.click(id)
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { controller?.menu(for: self) }

    // MARK: - Two-finger swipe right → dismiss

    private var swipeTracking = false
    private var swipeDecided = false
    private var swipeAccum = CGSize.zero

    override func scrollWheel(with event: NSEvent) {
        // Only trackpad gestures (with phases); momentum is ignored.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty, !isInPile, !isLeaving else {
            if !swipeTracking { super.scrollWheel(with: event) }
            return
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            swipeTracking = true
            swipeDecided = false
            swipeAccum = .zero
            swipeX = 0
        }
        guard swipeTracking else { super.scrollWheel(with: event); return }
        // Physical finger direction, independent of natural scrolling.
        let fingerX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        let fingerY = event.scrollingDeltaY
        swipeAccum.width += fingerX
        swipeAccum.height += abs(fingerY)
        if !swipeDecided, abs(swipeAccum.width) + swipeAccum.height > 6 {
            swipeDecided = true
            if abs(swipeAccum.width) < swipeAccum.height * 1.2 { swipeTracking = false; return }
        }
        if swipeDecided {
            swipeX = max(0, swipeAccum.width) * 0.9
            body.removeAnimation(forKey: "transform")
            body.transform = targetTransform
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            swipeTracking = false
            if swipeDecided, swipeX > 56, !event.phase.contains(.cancelled) {
                controller?.dismiss([id], exit: .swipe)
            } else {
                swipeX = 0
                applyBody(animated: true)
            }
        }
    }

    // MARK: - Rename (inline)

    private var renameField: NSTextField?
    private var renameBox: NSView?
    private var renameCommit: ((String?) -> Void)?
    private var renameFrame: CGRect { CGRect(x: 6, y: 6, width: bounds.width - 12, height: 22) }

    func beginRename(initial: String, commit: @escaping (String?) -> Void) {
        endRename(commit: false)
        // A rounded dark box with the accent ring; the borderless field sits inside it with padding.
        let box = NSView(frame: renameFrame)
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.cornerCurve = .continuous
        box.layer?.backgroundColor = ShelfStyle.chip.cgColor
        box.layer?.borderColor = ShelfStyle.ring.cgColor
        box.layer?.borderWidth = 1.5
        let f = NSTextField(string: initial)
        f.font = .systemFont(ofSize: 11, weight: .medium)
        f.textColor = .white
        f.drawsBackground = false
        f.isBordered = false
        f.isBezeled = false
        f.focusRingType = .none
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.sizeToFit()
        let fh = f.frame.height
        f.frame = CGRect(x: 6, y: (box.bounds.height - fh) / 2, width: box.bounds.width - 12, height: fh)
        f.autoresizingMask = [.width]
        box.addSubview(f)
        f.delegate = self
        addSubview(box)
        renameBox = box
        renameField = f
        renameCommit = commit
        window?.makeKey()
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }

    var isRenaming: Bool { renameField != nil }

    func endRename(commit: Bool) {
        guard let f = renameField else { return }
        let text = f.stringValue
        let done = renameCommit
        renameField = nil
        renameCommit = nil
        f.delegate = nil
        renameBox?.removeFromSuperview()
        renameBox = nil
        window?.makeFirstResponder(window?.contentView)
        done?(commit ? text : nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { endRename(commit: true); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { endRename(commit: false); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Focus left the field (e.g. a click in another app): keep what was typed, like Finder.
        if renameField != nil { endRename(commit: true) }
    }
}

/// The options button's tooltip (registered over its hit area in `layoutLayers`).
extension ShelfCardView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        "Options"
    }
}
