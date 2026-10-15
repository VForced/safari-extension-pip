import Cocoa
import SafariServices

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let server = ExtensionServer()
    var panel: FloatingPanel?
    var statusItem: NSStatusItem?
    let freeItem = NSMenuItem(title: "Free PiP (resizable, opacity)", action: #selector(pickFree), keyEquivalent: "")
    let appleItem = NSMenuItem(title: "Apple PiP (system window)", action: #selector(pickApple), keyEquivalent: "")
    let lockItem = NSMenuItem(title: "Lock Free PiP window (click-through)", action: #selector(toggleLock), keyEquivalent: "l")
    private var lastWake = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        server.onStart = { [weak self] w, h, _ in DispatchQueue.main.async { self?.openPanel(w: w, h: h) } }
        server.onFrame = { [weak self] data, paused in DispatchQueue.main.async { self?.panel?.show(frame: data, paused: paused) } }
        server.onState = { [weak self] paused in DispatchQueue.main.async { self?.panel?.setPaused(paused) } }
        server.onStop = { [weak self] in DispatchQueue.main.async { self?.closePanel(notify: false) } }
        server.onNeedWake = { [weak self] in DispatchQueue.main.async { self?.wakeExtension() } }
        // A windowless menu-bar app is a candidate for macOS automatic termination; the OS was
        // quietly killing us while idle, which dropped the extension's socket.
        ProcessInfo.processInfo.disableAutomaticTermination("Serving the Safari extension")
        ProcessInfo.processInfo.disableSuddenTermination()
        server.start()
        setupStatusItem()
        // Menu-bar agent: no Dock icon, and no window at launch (Settings… opens it on demand).
        DispatchQueue.main.async { NSApp.windows.filter { !($0 is NSPanel) }.forEach { $0.orderOut(nil) } }
        NotificationCenter.default.addObserver(forName: .anypipSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.server.pushSettings(); self?.refreshModeChecks()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {} // anypip://start just launches us

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pip", accessibilityDescription: "AnyPiP")
        let menu = NSMenu()
        for i in [freeItem, appleItem] { i.target = self; menu.addItem(i) }
        menu.addItem(.separator())
        lockItem.target = self
        menu.addItem(lockItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit AnyPiP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshModeChecks()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        lockItem.isEnabled = panel != nil
        lockItem.state = panel?.isLocked == true ? .on : .off
    }
    @objc func toggleLock() { guard let p = panel else { return }; p.setLocked(!p.isLocked) }
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { item === lockItem ? panel != nil : true }

    /// Safari unloads an idle extension background page, and nothing on its side wakes it while the
    /// video is paused in an inactive Safari. Poke it from here; it reconnects and gets the queued command.
    func wakeExtension() {
        guard Date().timeIntervalSince(lastWake) > 2 else { return }
        lastWake = Date()
        SFSafariApplication.dispatchMessage(withName: "wake", toExtensionWithIdentifier: extensionBundleIdentifier, userInfo: nil) { _ in }
    }

    func refreshModeChecks() {
        freeItem.state = Settings.mode == "free" ? .on : .off
        appleItem.state = Settings.mode == "free" ? .off : .on
    }
    func setMode(_ m: String) {
        Settings.mode = m
        refreshModeChecks()
        NotificationCenter.default.post(name: .anypipSettingsChanged, object: nil)
    }
    @objc func pickFree() { setMode("free") }
    @objc func pickApple() { setMode("apple") }
    @objc func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { !($0 is NSPanel) }) { w.makeKeyAndOrderFront(nil) }
    }

    func openPanel(w: Int, h: Int) {
        closePanel(notify: false)
        let p = FloatingPanel(videoSize: NSSize(width: w, height: h))
        p.onCommand = { [weak self] a, d in self?.server.command(a, delta: d) }
        p.onClose = { [weak self] in NSLog("AnyPiP: panel closed by user, notifying extension"); self?.panel = nil; self?.server.notifyClosed() }
        panel = p
        p.orderFrontRegardless()
    }

    func closePanel(notify: Bool) {
        guard let p = panel else { return }
        p.onClose = nil
        panel = nil
        p.close()
        if notify { server.notifyClosed() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

extension Notification.Name { static let anypipSettingsChanged = Notification.Name("anypipSettingsChanged") }
