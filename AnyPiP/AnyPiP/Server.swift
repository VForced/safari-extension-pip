import Foundation
import Network

/// Local WebSocket server the Safari extension's background script connects to.
final class ExtensionServer {
    static let port: NWEndpoint.Port = 48721

    var onStart: ((_ w: Int, _ h: Int, _ title: String) -> Void)?
    var onFrame: ((Data, Bool) -> Void)?
    var onStop: (() -> Void)?
    var onState: ((Bool) -> Void)?
    var onNeedWake: (() -> Void)?
    private var rxCount = 0, rxSince = Date()

    private var listener: NWListener?
    private var client: NWConnection?   // only a client in .ready state; touched on `queue` only
    // Safari unloads the extension's background page when idle (e.g. video paused, no frames),
    // closing the socket. Messages sent meanwhile wait here and go out when it reconnects.
    private var pending: [[String: Any]] = []
    private let queue = DispatchQueue(label: "anypip.server")

    func start() {
        let ws = NWProtocolWebSocket.Options()
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: Self.port)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        listener = l
    }

    private func accept(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                NSLog("AnyPiP: extension connected")
                if self.client !== conn { self.client?.cancel() }
                self.client = conn
                self.write(["t": "settings", "mode": Settings.mode])
                let queued = self.pending; self.pending.removeAll()
                queued.forEach { self.write($0) }
                self.receive(conn)
            case .failed, .cancelled:
                self.drop(conn)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func drop(_ conn: NWConnection) {
        if client === conn { client = nil }
        conn.cancel()
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil { self.drop(conn); return }
            if let data, let first = data.first, first == 0x46 /* F */ || first == 0x53 /* S */ {
                if first == 0x53 { self.onState?(data.count > 1 && data[data.startIndex + 1] == 0x31) }
                else if let bar = data.firstIndex(of: 0x7C), let jpeg = Data(base64Encoded: data[(bar + 1)...]) {
                    self.onFrame?(jpeg, data[data.startIndex + 1] == 0x31)
                    self.rxCount += 1
                    let dt = Date().timeIntervalSince(self.rxSince)
                    if dt >= 3 { NSLog("AnyPiP: rx %.1f fps, last frame %d KB", Double(self.rxCount) / dt, jpeg.count / 1024); self.rxCount = 0; self.rxSince = Date() }
                }
            } else if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let t = obj["t"] as? String {
                switch t {
                case "frame":
                    if let b64 = obj["d"] as? String, let jpeg = Data(base64Encoded: b64) { self.onFrame?(jpeg, (obj["p"] as? Int ?? 0) == 1) }
                case "free-start":
                    self.onStart?(obj["w"] as? Int ?? 16, obj["h"] as? Int ?? 9, obj["title"] as? String ?? "")
                case "free-stop":
                    self.onStop?()
                case "log":
                    NSLog("AnyPiP ext: %@", obj["m"] as? String ?? "")
                default: break
                }
            }
            self.receive(conn)
        }
    }

    /// Queue-safe send; held until a client is connected (settings are always re-sent on connect).
    func send(_ obj: [String: Any], queueIfOffline: Bool = true) {
        queue.async {
            if self.client == nil {
                if queueIfOffline {
                    self.pending.append(obj); if self.pending.count > 20 { self.pending.removeFirst() }
                    self.onNeedWake?()
                }
                return
            }
            self.write(obj)
        }
    }

    private func write(_ obj: [String: Any]) {
        guard let conn = client, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "msg", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { [weak self] err in
            guard let self, err != nil else { return }
            self.pending.append(obj) // failed mid-reconnect: retry on next connect
            self.drop(conn)
        })
    }

    func pushSettings() { send(["t": "settings", "mode": Settings.mode], queueIfOffline: false) }
    func command(_ action: String, delta: Double = 0) { send(["t": "cmd", "a": action, "d": delta]) }
    func notifyClosed() { send(["t": "closed"]) }
}

enum Settings {
    static var mode: String {
        get { UserDefaults.standard.string(forKey: "mode") ?? "free" }
        set { UserDefaults.standard.set(newValue, forKey: "mode") }
    }
    static var opacity: Double {
        get { UserDefaults.standard.object(forKey: "opacity") as? Double ?? 1.0 }
        set { UserDefaults.standard.set(newValue, forKey: "opacity") }
    }
}
