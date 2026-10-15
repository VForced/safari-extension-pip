const api = typeof browser !== "undefined" ? browser : chrome;
const WS_URL = "ws://127.0.0.1:48721";
const action = api.action || api.browserAction; // MV2 manifest → browserAction

let ws = null;
let mode = "free"; // "apple" | "free"; same default as the app, which pushes the real value
// The background page can be unloaded between messages, so keep the Free-PiP tab in storage.
let freeTabId = null;
const setFreeTab = (id) => { freeTabId = id; api.storage.local.set({ freeTab: id }).catch(() => {}); };
const getFreeTab = async () => {
  if (freeTabId != null) return freeTabId;
  try { const r = await api.storage.local.get("freeTab"); freeTabId = r.freeTab ?? null; } catch (_) {}
  return freeTabId;
};

// Don't rely on remembering the tab: tell the remembered one first, then every tab (only the one streaming reacts).
async function toActiveTabs(msg) {
  const ids = new Set();
  const known = await getFreeTab();
  if (known != null) ids.add(known);
  try { (await api.tabs.query({})).forEach((t) => t.id != null && ids.add(t.id)); } catch (_) {}
  ids.forEach((id) => api.tabs.sendMessage(id, msg).catch(() => {}));
}

// The click that wakes this page can arrive before storage is read — toggle() awaits this.
const modeReady = api.storage.local.get("mode").then((r) => { if (r && r.mode) mode = r.mode; }).catch(() => {});

function connect() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;
  try { ws = new WebSocket(WS_URL); } catch (_) { return; }
  ws.onopen = () => action.setBadgeText({ text: "" });
  ws.onmessage = async (e) => {
    let m; try { m = JSON.parse(e.data); } catch (_) { return; }
    if (m.t === "settings") {
      mode = m.mode === "free" ? "free" : "apple";
      api.storage.local.set({ mode });
    } else if (m.t === "cmd") {
      toActiveTabs({ type: "free-cmd", a: m.a, d: m.d });
    } else if (m.t === "closed") {
      setFreeTab(null);
      toActiveTabs({ type: "free-stop" });
    }
  };
  ws.onclose = () => { ws = null; };
  ws.onerror = () => {};
}
connect();
setInterval(connect, 3000);

// The app can wake us (SFSafariApplication.dispatchMessage) when it has a command and no socket.
try {
  const port = api.runtime.connectNative("application.id");
  port.onMessage.addListener(() => connect());
} catch (_) {}

const wsOpen = () => ws && ws.readyState === WebSocket.OPEN;
// Diagnostics go to the app's log (Safari's background console is hard to reach).
const log = (m) => { if (wsOpen()) ws.send(JSON.stringify({ t: "log", m: String(m) })); };

async function frames(tabId) {
  try { return (await api.webNavigation.getAllFrames({ tabId })) || [{ frameId: 0 }]; }
  catch (_) { return [{ frameId: 0 }]; }
}

// Free PiP needs the app; start it in the background if it isn't running.
async function ensureApp() {
  connect();
  if (wsOpen()) return true;
  try { await api.runtime.sendNativeMessage("application.id", { cmd: "launch" }); } catch (_) {}
  for (let i = 0; i < 20 && !wsOpen(); i++) { await new Promise((r) => setTimeout(r, 250)); connect(); }
  return wsOpen();
}

async function toggle(tab) {
  if (!tab || tab.id == null) return;
  await modeReady;
  connect();
  if (mode === "free") await ensureApp();
  log(`toggle: mode=${mode} ws=${wsOpen()}`);
  let type = "pip-toggle";
  if (mode === "free") {
    if (wsOpen()) type = "free-toggle";
    else action.setBadgeText({ text: "!" }); // app not running -> fall back to Apple PiP
  }
  for (const f of await frames(tab.id)) {
    try {
      const r = await api.tabs.sendMessage(tab.id, { type }, { frameId: f.frameId });
      log(`frame ${f.frameId} ${type} -> ${JSON.stringify(r)}`);
      if (r && r.ok) { if (type === "free-toggle") setFreeTab(r.active ? tab.id : null); return; }
    } catch (e) { log(`frame ${f.frameId} ${type} threw ${e}`); }
  }
}

api.runtime.onMessage.addListener((msg, sender) => {
  if (!msg) return;
  if (msg.type === "free-start" && sender.tab) setFreeTab(sender.tab.id);
  if (msg.type === "frame") {
    connect();
    // Compact wire format "F<paused>|<base64 jpeg>" — no JSON parsing per frame on the app side.
    if (wsOpen() && ws.bufferedAmount < 1_000_000) ws.send("F" + (msg.p ? "1" : "0") + "|" + msg.d);
    return Promise.resolve();
  }
  if (msg.type === "ping") { connect(); return Promise.resolve(); } // keeps us loaded + socket up while paused
  if (msg.type === "state") {
    connect();
    if (wsOpen()) ws.send("S" + (msg.p ? "1" : "0"));
    return Promise.resolve();
  }
  if (msg.type === "free-start" || msg.type === "free-stop") {
    connect();
    if (!wsOpen()) return;
    ws.send(JSON.stringify({ t: msg.type, w: msg.w, h: msg.h, title: msg.title }));
    if (msg.type === "free-stop") setFreeTab(null);
  }
});

action.onClicked.addListener(toggle);
api.commands.onCommand.addListener(async (cmd) => {
  if (cmd !== "toggle-pip") return;
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  toggle(tab);
});
