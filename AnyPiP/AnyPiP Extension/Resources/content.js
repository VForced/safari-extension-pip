(() => {
  const api = typeof browser !== "undefined" ? browser : chrome;
  const MAX_W = 960, FPS = 30;

  function visibleArea(v) {
    const r = v.getBoundingClientRect();
    const w = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
    const h = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
    return w * h;
  }
  function collect(root, out) {
    root.querySelectorAll("video").forEach((v) => out.push(v));
    root.querySelectorAll("*").forEach((el) => { if (el.shadowRoot) collect(el.shadowRoot, out); });
  }
  function pickVideo() {
    const all = []; collect(document, all);
    const usable = all.filter((v) => v.readyState > 0 && visibleArea(v) > 0);
    const playing = usable.filter((v) => !v.paused && !v.ended);
    const pool = playing.length ? playing : usable;
    pool.sort((a, b) => visibleArea(b) - visibleArea(a));
    return pool[0] || null;
  }

  // ---- Apple PiP ----
  async function applePip() {
    if (document.pictureInPictureElement) { await document.exitPictureInPicture(); return { ok: true }; }
    const v = pickVideo();
    if (!v) return { ok: false };
    v.removeAttribute("disablepictureinpicture");
    v.disablePictureInPicture = false;
    if (v.webkitSetPresentationMode) v.webkitSetPresentationMode("picture-in-picture");
    else await v.requestPictureInPicture();
    return { ok: true };
  }

  // ---- Free PiP: video -> canvas -> JPEG frames -> app window ----
  let timer = null, video = null, savedVis = null, onState = null;
  function stopFree(notify) {
    if (timer) clearInterval(timer);
    if (video) { // closing Free PiP: pause and un-hide the page's own video
      try { video.pause(); } catch (_) {}
      if (onState) { video.removeEventListener("pause", onState); video.removeEventListener("play", onState); }
      if (savedVis && savedVis.value) video.style.setProperty("visibility", savedVis.value, savedVis.priority);
      else video.style.removeProperty("visibility");
    }
    timer = null; video = null; savedVis = null; onState = null;
    if (notify) api.runtime.sendMessage({ type: "free-stop" }).catch(() => {});
  }
  function startFree() {
    const v = pickVideo();
    if (!v || !v.videoWidth) return { ok: false };
    const scale = Math.min(1, MAX_W / v.videoWidth);
    const w = Math.round(v.videoWidth * scale), h = Math.round(v.videoHeight * scale);
    const c = document.createElement("canvas"); c.width = w; c.height = h;
    const g = c.getContext("2d");
    try { g.drawImage(v, 0, 0, w, h); c.toDataURL("image/jpeg", 0.7); }
    catch (_) { return { ok: false, error: "tainted" }; } // cross-origin: caller falls back
    video = v;
    // Hide the on-page picture (audio keeps playing, frames are still readable).
    savedVis = { value: v.style.getPropertyValue("visibility"), priority: v.style.getPropertyPriority("visibility") };
    v.style.setProperty("visibility", "hidden", "important");
    api.runtime.sendMessage({ type: "free-start", w, h, title: document.title }).catch(() => {});

    onState = () => api.runtime.sendMessage({ type: "state", p: v.paused ? 1 : 0 }).catch(() => {});
    v.addEventListener("pause", onState); v.addEventListener("play", onState);
    onState();

    // One capture per decoded video frame (no duplicates), at most 2 frames in flight so a slow
    // hop drops frames instead of queueing latency. JPEG encoding runs off the main thread (toBlob).
    let inflight = 0, last = 0;
    const pump = () => {
      if (!video || inflight >= 2 || video.readyState < 2) return;
      last = performance.now();
      try { g.drawImage(video, 0, 0, w, h); } catch (_) { return stopFree(true); }
      inflight++;
      c.toBlob((blob) => {
        if (!blob) { inflight--; return; }
        const fr = new FileReader();
        fr.onload = () => {
          const r = fr.result, d = r.slice(r.indexOf(",") + 1);
          api.runtime.sendMessage({ type: "frame", d, p: video && video.paused ? 1 : 0 })
            .catch(() => {}).finally(() => { inflight--; });
        };
        fr.onerror = () => { inflight--; };
        fr.readAsDataURL(blob);
      }, "image/jpeg", 0.65);
    };
    const tick = () => { if (!video) return; pump(); schedule(); };
    const schedule = () => {
      if (v.requestVideoFrameCallback) v.requestVideoFrameCallback(tick);
    };
    schedule();
    // Watchdog: if frame callbacks stall (hidden/throttled tab), fall back to polling.
    timer = setInterval(() => {
      if (!video) return;
      if (performance.now() - last > 250 && !video.paused) pump();
    }, 100);
    return { ok: true, active: true };
  }

  api.runtime.onMessage.addListener((msg, _s, sendResponse) => {
    if (!msg) return;
    if (msg.type === "free-stop") { stopFree(false); return; }
    if (msg.type === "free-cmd") {
      if (!video) return;
      if (msg.a === "toggle") { video.paused ? video.play() : video.pause(); }
      else if (msg.a === "seek") {
        const t = video.currentTime + (msg.d || 0);
        video.currentTime = Math.max(0, isFinite(video.duration) ? Math.min(video.duration, t) : t);
      }
      return;
    }
    if (msg.type !== "pip-toggle" && msg.type !== "free-toggle") return;
    (async () => {
      try {
        if (msg.type === "pip-toggle") return sendResponse(await applePip());
        if (timer) { stopFree(true); return sendResponse({ ok: true, active: false }); }
        let r = startFree();
        if (!r.ok && r.error === "tainted") r = await applePip(); // can't read pixels -> native PiP
        sendResponse(r);
      } catch (e) { sendResponse({ ok: false, error: String(e) }); }
    })();
    return true;
  });
})();
