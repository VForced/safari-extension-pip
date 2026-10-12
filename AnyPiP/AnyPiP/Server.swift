import Foundation
import Network

/// Local WebSocket server the Safari extension's background script connects to.
final class ExtensionServer {
    static let port: NWEndpoint.Port = 48721

    var onStart: ((_ w: Int, _ h: Int, _ title: String) -> Void)?
    var onFrame: ((Data, Bool) -> Void)?
    var onStop: (() -> Void)?
    var onState: ((Bool) -> Void)?
    private var rxCount = 0, rxSince = Date()

    private var listener: NWListener?
    private var client: NWConnection?
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
        client?.cancel()
        client = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            if case .ready = state { self.pushSettings(); self.receive(conn) }
        }
        conn.start(queue: queue)
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
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
                default: break
                }
            }
            self.receive(conn)
        }
    }

    func send(_ obj: [String: Any]) {
        guard let conn = client, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "msg", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    func pushSettings() {
        send(["t": "settings", "mode": Settings.mode])
    }
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
