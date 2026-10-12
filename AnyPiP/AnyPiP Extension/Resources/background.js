const api = typeof browser !== "undefined" ? browser : chrome;
const WS_URL = "ws://127.0.0.1:48721";

let ws = null;
let mode = "apple"; // "apple" | "free"; the app pushes the real value
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

api.storage.local.get("mode").then((r) => { if (r && r.mode) mode = r.mode; }).catch(() => {});

function connect() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;
  try { ws = new WebSocket(WS_URL); } catch (_) { return; }
  ws.onopen = () => api.action.setBadgeText({ text: "" });
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

const wsOpen = () => ws && ws.readyState === WebSocket.OPEN;

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
  connect();
  if (mode === "free") await ensureApp();
  let type = "pip-toggle";
  if (mode === "free") {
    if (wsOpen()) type = "free-toggle";
    else api.action.setBadgeText({ text: "!" }); // app not running -> fall back to Apple PiP
  }
  for (const f of await frames(tab.id)) {
    try {
      const r = await api.tabs.sendMessage(tab.id, { type }, { frameId: f.frameId });
      if (r && r.ok) { if (type === "free-toggle") setFreeTab(r.active ? tab.id : null); return; }
    } catch (_) {}
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
  if (msg.type === "state") {
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

api.action.onClicked.addListener(toggle);
api.commands.onCommand.addListener(async (cmd) => {
  if (cmd !== "toggle-pip") return;
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  toggle(tab);
});
