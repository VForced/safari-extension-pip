import Cocoa
import SafariServices
import WebKit

let extensionBundleIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".Extension"

/// Settings window: PiP mode, default opacity, link to Safari's extension preferences.
class ViewController: NSViewController {
    @IBOutlet var webView: WKWebView!

    private let modePopup = NSPopUpButton()
    private let opacitySlider = NSSlider(value: Settings.opacity, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.isHidden = true
        preferredContentSize = NSSize(width: 420, height: 230)

        modePopup.addItems(withTitles: ["Free PiP (resizable, adjustable opacity)", "Apple PiP (system window)"])
        modePopup.selectItem(at: Settings.mode == "free" ? 0 : 1)
        modePopup.target = self; modePopup.action = #selector(modeChanged)

        opacitySlider.target = self; opacitySlider.action = #selector(opacityChanged)
        let open = NSButton(title: "Open Safari extension settings…", target: self, action: #selector(openPrefs))

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Mode:"), modePopup],
            [NSTextField(labelWithString: "Free PiP opacity:"), opacitySlider],
            [NSView(), open],
            [NSView(), status],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            opacitySlider.widthAnchor.constraint(equalToConstant: 220),
        ])
        refreshStatus()
    }

    private func refreshStatus() {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionBundleIdentifier) { state, _ in
            DispatchQueue.main.async {
                self.status.stringValue = (state?.isEnabled ?? false)
                    ? "Safari extension: enabled" : "Safari extension: not enabled yet"
            }
        }
    }

    @objc private func modeChanged() {
        Settings.mode = modePopup.indexOfSelectedItem == 0 ? "free" : "apple"
        NotificationCenter.default.post(name: .anypipSettingsChanged, object: nil)
    }
    @objc private func opacityChanged() { Settings.opacity = opacitySlider.doubleValue }
    @objc private func openPrefs() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleIdentifier) { _ in }
    }
}
