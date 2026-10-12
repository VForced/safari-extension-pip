import Cocoa

/// Always-on-top, freely resizable window that shows the streamed video frames.
final class FloatingPanel: NSPanel {
    private let content = PanelContent()
    var onClose: (() -> Void)?
    var onCommand: ((String, Double) -> Void)?

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

    /// Lock the window to the video's aspect ratio (no letterboxing); keep the current width.
    func fit(to size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        let ratio = size.width / size.height
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

    override var canBecomeKey: Bool { true }
    override func close() { onClose?(); super.close() }
}

private final class PanelContent: NSView, NSWindowDelegate {
    weak var panel: FloatingPanel?
    let layerView = NSView()
    let bar = NSVisualEffectView()
    let slider = NSSlider(value: Settings.opacity, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private var tracking: NSTrackingArea?
    private var decoding = false
    private let playButton = RoundButton(symbol: "pause.fill", size: 56)
    private let controls = NSStackView()
    private var hideTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layerView.wantsLayer = true
        layerView.layer?.contentsGravity = .resize
        layerView.layer?.backgroundColor = NSColor.black.cgColor
        layerView.autoresizingMask = [.width, .height]
        layerView.frame = bounds
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

    func setPaused(_ paused: Bool) {
        playButton.setSymbol(paused ? "play.fill" : "pause.fill")
    }

    /// iOS-style: controls fade in on hover/click and fade out after a moment.
    func showControls() {
        controls.animator().alphaValue = 1
        bar.animator().alphaValue = 1
        panel?.setCloseVisible(true)
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in self?.hideControls() }
    }
    func hideControls() {
        hideTimer?.invalidate()
        controls.animator().alphaValue = 0
        bar.animator().alphaValue = 0
        panel?.setCloseVisible(false)
    }
    override func mouseDown(with event: NSEvent) { showControls(); super.mouseDown(with: event) }
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
                    self?.layerView.layer?.contents = img
                    self?.panel?.fit(to: NSSize(width: img.width, height: img.height))
                }
            }
        }
    }

    // ⌥-scroll changes opacity
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option), let p = panel else { return super.scrollWheel(with: event) }
        p.setOpacity(Double(p.alphaValue) + Double(event.scrollingDeltaY) * 0.005)
    }

    override func updateTrackingAreas() {
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { showControls() }
    override func mouseExited(with event: NSEvent) { hideControls() }

    func windowDidEndLiveResize(_ n: Notification) { save() }
    func windowDidMove(_ n: Notification) { save() }
    private func save() { if let f = panel?.frame { UserDefaults.standard.set(NSStringFromRect(f), forKey: "panelFrame") } }
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
