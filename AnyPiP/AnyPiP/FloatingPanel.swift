import Cocoa

/// Always-on-top, freely resizable window that shows the streamed video frames.
///
/// Modes (both toggled from the top-right buttons, which fade in with the other controls):
/// - **Lock** (click-through): the window ignores the mouse so you can work with whatever is under it.
///   A small lock badge stays clickable in the corner to unlock (also: menu bar → Unlock).
/// - **Crop** (fixed scale): resizing the window no longer scales the video — it reveals or hides part
///   of it, like a viewport. Drag to pan the video, scroll wheel (or pinch) to zoom, ⌘-drag moves the window.
final class FloatingPanel: NSPanel {
    private let content = PanelContent()
    private var lockBadge: LockBadge?
    var onClose: (() -> Void)?
    var onCommand: ((String, Double) -> Void)?
    var onLockChanged: ((Bool) -> Void)?

    private(set) var videoSize = NSSize(width: 16, height: 9)
    private(set) var isLocked = false
    var isCropping: Bool { content.cropRect != nil }

    init(videoSize: NSSize) {
        let w: CGFloat = 480
        let h = max(80, w * videoSize.height / max(1, videoSize.width))
        let saved = UserDefaults.standard.string(forKey: "panelFrame")
        let rect = saved.map { NSRectFromString($0) } ?? NSRect(
            x: (NSScreen.main?.visibleFrame.maxX ?? 800) - w - 24,
            y: (NSScreen.main?.visibleFrame.minY ?? 0) + 24, width: w, height: h)
        super.init(contentRect: rect,
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        setCloseVisible(false, animated: false)
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .black
        alphaValue = CGFloat(Settings.opacity)
        contentView = content
        content.panel = self
        acceptsMouseMovedEvents = true
        delegate = content
        fit(to: videoSize)
    }

    /// Close button is invisible (and unclickable) until the controls fade in.
    func setCloseVisible(_ visible: Bool, animated: Bool = true) {
        guard let b = standardWindowButton(.closeButton) else { return }
        if visible { b.isHidden = false }
        let target: CGFloat = visible ? 1 : 0
        if !animated { b.alphaValue = target; b.isHidden = !visible; return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; b.animator().alphaValue = target },
                                             completionHandler: { if !visible { b.isHidden = true } })
    }

    func setPaused(_ paused: Bool) { content.setPaused(paused) }

    func show(frame data: Data, paused: Bool) { content.show(jpeg: data); content.setPaused(paused) }

    /// Normal mode: lock the window to the video's aspect ratio (no letterboxing), keep the width.
    /// Crop mode: the window is a free viewport; only the video's own rect follows a ratio change.
    func fit(to size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        videoSize = size
        let ratio = size.width / size.height
        if var r = content.cropRect {
            if abs(r.width / r.height - ratio) > 0.01 { r.size.height = r.width / ratio; content.cropRect = r }
            return
        }
        // Min size must itself have the video's ratio, or the aspect lock breaks when squeezed.
        let short: CGFloat = 90
        contentMinSize = ratio >= 1 ? NSSize(width: short * ratio, height: short) : NSSize(width: short, height: short / ratio)
        if let cur = contentAspectRatio as NSSize?, abs(cur.width / max(cur.height, 1) - ratio) < 0.01 { return }
        contentAspectRatio = NSSize(width: size.width, height: size.height)
        let cw = contentRect(forFrameRect: frame).width
        setContentSize(NSSize(width: cw, height: cw / ratio))
    }

    func setOpacity(_ v: Double) {
        let c = min(1, max(0.1, v))
        alphaValue = CGFloat(c)
        Settings.opacity = c
        content.slider.doubleValue = c
    }

    // MARK: Lock (click-through)

    func setLocked(_ on: Bool) {
        guard on != isLocked else { return }
        isLocked = on
        ignoresMouseEvents = on
        content.hideControls()
        if on {
            let badge = LockBadge { [weak self] in self?.setLocked(false) }
            addChildWindow(badge, ordered: .above) // moves with the panel
            lockBadge = badge
            positionLockBadge()
        } else if let badge = lockBadge {
            removeChildWindow(badge)
            badge.orderOut(nil)
            lockBadge = nil
        }
        content.syncModeButtons()
        onLockChanged?(on)
    }

    func positionLockBadge() {
        guard let b = lockBadge else { return }
        let s = b.frame.size
        b.setFrameOrigin(NSPoint(x: frame.maxX - s.width - 8, y: frame.maxY - s.height - 8))
    }

    // MARK: Crop (fixed scale viewport)

    func setCropping(_ on: Bool) {
        guard on != isCropping else { return }
        if on {
            // The video currently fills the window exactly; freeze it there in screen space.
            content.cropRect = frame
            isMovableByWindowBackground = false // drags pan the video now; ⌘-drag moves the window
            contentResizeIncrements = NSSize(width: 1, height: 1) // clears the aspect-ratio lock
            contentMinSize = NSSize(width: 60, height: 60)
        } else {
            // Back to "the window is the video": keep the current width, restore the ratio lock.
            content.cropRect = nil
            isMovableByWindowBackground = true
            contentAspectRatio = videoSize
            let short: CGFloat = 90, ratio = videoSize.width / videoSize.height
            contentMinSize = ratio >= 1 ? NSSize(width: short * ratio, height: short) : NSSize(width: short, height: short / ratio)
            let cw = contentRect(forFrameRect: frame).width
            setContentSize(NSSize(width: cw, height: cw / ratio))
        }
        content.needsLayout = true
        content.syncModeButtons()
    }

    override var canBecomeKey: Bool { true }
    override func close() {
        if let b = lockBadge { removeChildWindow(b); b.orderOut(nil) }
        onClose?()
        super.close()
    }
}

private final class PanelContent: NSView, NSWindowDelegate {
    weak var panel: FloatingPanel?
    let layerView = NSView()
    let videoLayer = CALayer()
    let bar = NSVisualEffectView()
    let slider = NSSlider(value: Settings.opacity, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private var tracking: NSTrackingArea?
    private var decoding = false
    private let playButton = RoundButton(symbol: "pause.fill", size: 56)
    private let cropButton = RoundButton(symbol: "crop", size: 30)
    private let lockButton = RoundButton(symbol: "lock.open", size: 30)
    private let controls = NSStackView()
    private let modeButtons = NSStackView()
    private var hideTimer: Timer?
    private var lastFrame = NSRect.zero

    /// Crop mode: where the whole video sits, in screen coordinates. nil = normal mode (video fills the window).
    var cropRect: NSRect? { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layerView.wantsLayer = true
        layerView.layer?.backgroundColor = NSColor.black.cgColor
        layerView.layer?.masksToBounds = true
        layerView.autoresizingMask = [.width, .height]
        layerView.frame = bounds
        videoLayer.contentsGravity = .resize
        videoLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        layerView.layer?.addSublayer(videoLayer)
        addSubview(layerView)

        bar.material = .hudWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 8
        let icon = NSImageView(image: NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Opacity")!)
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.controlSize = .small
        let stack = NSStackView(views: [icon, slider])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor), stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
        let back = RoundButton(symbol: "gobackward.15", size: 44)
        let fwd = RoundButton(symbol: "goforward.15", size: 44)
        back.target = self; back.action = #selector(seekBack)
        fwd.target = self; fwd.action = #selector(seekFwd)
        playButton.target = self; playButton.action = #selector(togglePlay)
        controls.setViews([back, playButton, fwd], in: .center)
        controls.spacing = 28
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.alphaValue = 0
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.centerXAnchor.constraint(equalTo: centerXAnchor),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        cropButton.target = self; cropButton.action = #selector(toggleCrop)
        cropButton.toolTip = "Crop: edges cut the video instead of scaling it. Drag = pan, wheel = zoom, ⌘-drag = move window"
        lockButton.target = self; lockButton.action = #selector(lock)
        lockButton.toolTip = "Lock: clicks pass through the window"
        modeButtons.setViews([cropButton, lockButton], in: .trailing)
        modeButtons.spacing = 8
        modeButtons.translatesAutoresizingMaskIntoConstraints = false
        modeButtons.alphaValue = 0
        addSubview(modeButtons)
        NSLayoutConstraint.activate([
            modeButtons.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            modeButtons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.alphaValue = 0
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            bar.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -20),
            bar.widthAnchor.constraint(equalToConstant: 220).withPriority(.defaultHigh),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func togglePlay() { panel?.onCommand?("toggle", 0); showControls() }
    @objc func seekBack() { panel?.onCommand?("seek", -15); showControls() }
    @objc func seekFwd() { panel?.onCommand?("seek", 15); showControls() }
    @objc func toggleCrop() { guard let p = panel else { return }; p.setCropping(!p.isCropping); showControls() }
    @objc func lock() { panel?.setLocked(true) }

    func syncModeButtons() {
        cropButton.setSymbol(panel?.isCropping == true ? "crop.rotate" : "crop")
        cropButton.layer?.backgroundColor = (panel?.isCropping == true
            ? NSColor.controlAccentColor.withAlphaComponent(0.8) : NSColor.black.withAlphaComponent(0.45)).cgColor
    }

    func setPaused(_ paused: Bool) {
        playButton.setSymbol(paused ? "play.fill" : "pause.fill")
    }

    /// iOS-style: controls fade in on hover/click and fade out after a moment.
    func showControls() {
        guard panel?.isLocked != true else { return }
        controls.animator().alphaValue = 1
        modeButtons.animator().alphaValue = 1
        bar.animator().alphaValue = 1
        panel?.setCloseVisible(true)
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in self?.hideControls() }
    }
    func hideControls() {
        hideTimer?.invalidate()
        controls.animator().alphaValue = 0
        modeButtons.animator().alphaValue = 0
        bar.animator().alphaValue = 0
        panel?.setCloseVisible(false)
    }
    override func mouseDown(with event: NSEvent) {
        showControls()
        if cropRect != nil, event.modifierFlags.contains(.command) { window?.performDrag(with: event); return }
        super.mouseDown(with: event)
    }
    // Crop mode: dragging pans the video inside the window.
    override func mouseDragged(with event: NSEvent) {
        guard var r = cropRect else { return super.mouseDragged(with: event) }
        r.origin.x += event.deltaX
        r.origin.y -= event.deltaY
        cropRect = r
        clampCrop()
    }
    override func mouseMoved(with event: NSEvent) { showControls() }

    @objc func sliderChanged() { panel?.setOpacity(slider.doubleValue) }

    func show(jpeg: Data) {
        guard !decoding else { return } // drop frames while busy
        decoding = true
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            var img: CGImage?
            if let src = CGImageSourceCreateWithData(jpeg as CFData, nil) { img = CGImageSourceCreateImageAtIndex(src, 0, nil) }
            DispatchQueue.main.async {
                self?.decoding = false
                if let img {
                    self?.videoLayer.contents = img
                    self?.panel?.fit(to: NSSize(width: img.width, height: img.height))
                }
            }
        }
    }

    // MARK: Layout — the video layer fills the window, or sits at `cropRect` (screen space) in crop mode.

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let r = cropRect, let win = window {
            videoLayer.frame = NSRect(x: r.minX - win.frame.minX, y: r.minY - win.frame.minY, width: r.width, height: r.height)
        } else {
            videoLayer.frame = layerView.bounds
        }
        CATransaction.commit()
    }

    /// Keep at least part of the video inside the window so it can't be panned out of reach.
    private func clampCrop() {
        guard var r = cropRect, let win = window?.frame else { return }
        let keep: CGFloat = 40
        r.origin.x = min(max(r.origin.x, win.minX - r.width + keep), win.maxX - keep)
        r.origin.y = min(max(r.origin.y, win.minY - r.height + keep), win.maxY - keep)
        cropRect = r
    }

    // ⌥-scroll changes opacity; in crop mode the wheel zooms the video around the cursor.
    override func scrollWheel(with event: NSEvent) {
        guard let p = panel else { return super.scrollWheel(with: event) }
        if event.modifierFlags.contains(.option) {
            p.setOpacity(Double(p.alphaValue) + Double(event.scrollingDeltaY) * 0.005)
        } else if cropRect != nil {
            // Mouse wheel ticks are ±1 line; trackpads send fine pixel deltas.
            let step = event.hasPreciseScrollingDeltas ? 0.005 : 0.1
            zoom(by: 1 + event.scrollingDeltaY * step)
        } else {
            super.scrollWheel(with: event)
        }
    }

    // Pinch zooms too (trackpad).
    override func magnify(with event: NSEvent) {
        guard cropRect != nil else { return super.magnify(with: event) }
        zoom(by: 1 + event.magnification)
    }

    private func zoom(by f: CGFloat) {
        guard var r = cropRect, f > 0 else { return }
        let newW = r.width * f
        guard newW >= 80, newW <= 8000 else { return }
        let m = NSEvent.mouseLocation
        r = NSRect(x: m.x - (m.x - r.minX) * f, y: m.y - (m.y - r.minY) * f, width: newW, height: r.height * f)
        cropRect = r
        clampCrop()
    }

    override func updateTrackingAreas() {
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { showControls() }
    override func mouseExited(with event: NSEvent) { hideControls() }

    // MARK: Window delegate

    func windowDidMove(_ n: Notification) {
        guard let win = window else { return }
        // Dragging the window carries the video along; resizing from an edge (which also moves the
        // origin) leaves the video where it is on screen, so the edge crops instead of scaling.
        if var r = cropRect, !win.inLiveResize, lastFrame != .zero {
            r.origin.x += win.frame.minX - lastFrame.minX
            r.origin.y += win.frame.minY - lastFrame.minY
            cropRect = r
        }
        lastFrame = win.frame
        needsLayout = true
        panel?.positionLockBadge()
        save()
    }
    func windowDidResize(_ n: Notification) {
        if let win = window { lastFrame = win.frame }
        needsLayout = true
        panel?.positionLockBadge()
    }
    func windowDidEndLiveResize(_ n: Notification) { clampCrop(); save() }
    private func save() { if let f = panel?.frame { UserDefaults.standard.set(NSStringFromRect(f), forKey: "panelFrame") } }
}

/// Small always-clickable badge shown in the corner while the panel is locked (click-through).
private final class LockBadge: NSPanel {
    private let onUnlock: () -> Void

    init(onUnlock: @escaping () -> Void) {
        self.onUnlock = onUnlock
        super.init(contentRect: NSRect(x: 0, y: 0, width: 30, height: 30),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let button = RoundButton(symbol: "lock.fill", size: 30)
        button.target = self
        button.action = #selector(unlock)
        button.toolTip = "Unlock"
        let host = HoverView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        host.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        contentView = host
        alphaValue = 0.35
        host.onHover = { [weak self] inside in self?.animator().alphaValue = inside ? 1 : 0.35 }
    }

    @objc private func unlock() { onUnlock() }
}

private final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

private extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint { priority = p; return self }
}


/// Translucent circular button with an SF Symbol, like iOS player controls.
private final class RoundButton: NSButton {
    private let cfg: NSImage.SymbolConfiguration
    private var current = ""
    func setSymbol(_ name: String) {
        guard name != current else { return }
        current = name
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }
    init(symbol: String, size: CGFloat) {
        cfg = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        setSymbol(symbol)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .white
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        layer?.cornerRadius = size / 2
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
