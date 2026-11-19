/* MediaGrid desktop UI */
const T = window.__TAURI__;
const invoke = T.core.invoke;
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];

let info = {};
let BASE = "";
let TOKEN = "";
let tracks = [];
let filtered = [];
let media = [];
let mediaKind = "";
let musicFilter = { q: "", chip: "all" };
let playlists = [];

const api = async (path, opts = {}) => {
  const r = await fetch(BASE + path, {
    ...opts,
    headers: { Authorization: "Bearer " + TOKEN, ...(opts.json ? { "Content-Type": "application/json" } : {}), ...(opts.headers || {}) },
    body: opts.json ? JSON.stringify(opts.json) : opts.body,
  });
  if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.statusText);
  return r.headers.get("content-type")?.includes("json") ? r.json() : r;
};
const url = (p) => `${BASE}${p}${p.includes("?") ? "&" : "?"}t=${TOKEN}`;
const fmtTime = (s) => { s = Math.max(0, Math.floor(s || 0)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; };
const fmtSize = (b) => { if (!b) return "0 B"; const u = ["B", "KB", "MB", "GB"]; let i = 0; while (b >= 1024 && i < 3) { b /= 1024; i++; } return `${b.toFixed(i ? 1 : 0)} ${u[i]}`; };
const ago = (ms) => { const s = (Date.now() - ms) / 1000; if (s < 60) return "just now"; if (s < 3600) return `${Math.floor(s / 60)} min ago`; if (s < 86400) return `${Math.floor(s / 3600)} h ago`; return new Date(ms).toLocaleDateString(); };
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
function toast(msg) { const t = $("#toast"); t.textContent = msg; t.classList.add("show"); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove("show"), 2400); }

const ICON = {
  note: '<svg viewBox="0 0 24 24"><path d="M9 18V5l11-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="17" cy="16" r="3"/></svg>',
  clip: '<svg viewBox="0 0 24 24"><rect x="8" y="8" width="12" height="12" rx="3"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/></svg>',
  file: '<svg viewBox="0 0 24 24"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/></svg>',
  copy: '<svg viewBox="0 0 24 24"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></svg>',
  folder: '<svg viewBox="0 0 24 24"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>',
  phone: '<svg viewBox="0 0 24 24"><rect x="6" y="2" width="12" height="20" rx="3"/><path d="M11 18h2"/></svg>',
  play: '<svg viewBox="0 0 24 24"><path d="M7 4l13 8-13 8z" class="fill"/></svg>',
  pause: '<svg viewBox="0 0 24 24"><rect x="6" y="4" width="4" height="16" rx="1" class="fill"/><rect x="14" y="4" width="4" height="16" rx="1" class="fill"/></svg>',
  prev: '<svg viewBox="0 0 24 24"><path d="M19 20L9 12l10-8z" class="fill"/><path d="M5 19V5"/></svg>',
  next: '<svg viewBox="0 0 24 24"><path d="M5 4l10 8-10 8z" class="fill"/><path d="M19 5v14"/></svg>',
  video: '<svg viewBox="0 0 24 24"><path d="M7 4l13 8-13 8z" class="fill"/></svg>',
  x: '<svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg>',
};

/* ---------------- appearance: system light/dark + accent ---------------- */
const store = { get: (k, d) => { try { return localStorage.getItem(k) ?? d; } catch { return d; } }, set: (k, v) => { try { localStorage.setItem(k, v); } catch {} } };
const darkQuery = matchMedia("(prefers-color-scheme: dark)");
function applyTheme() {
  const mode = store.get("mg.theme", "system");
  const root = document.documentElement;
  root.dataset.theme = mode === "system" ? (darkQuery.matches ? "dark" : "light") : mode;
  $$("#theme-seg button").forEach((b) => b.classList.toggle("active", b.dataset.m === mode));
}
$$("#theme-seg button").forEach((b) => (b.onclick = () => { store.set("mg.theme", b.dataset.m); applyTheme(); }));
darkQuery.addEventListener("change", applyTheme); // follow the system setting live
applyTheme();

/* ---------------- window chrome ---------------- */
const win = T.window.getCurrentWindow();
$("#w-min").onclick = () => win.minimize();
$("#w-max").onclick = () => win.toggleMaximize();
$("#w-close").onclick = () => win.hide();

/* ---------------- tabs ---------------- */
function showTab(name) {
  $$(".nav").forEach((b) => b.classList.toggle("active", b.dataset.tab === name));
  $$(".tab").forEach((t) => t.classList.toggle("active", t.id === "tab-" + name));
  $("#music-glow").style.display = name === "music" ? "block" : "none";
  if (name === "media" && !media.length) loadMedia();
  if (name === "mobile") loadDevices();
  if (name === "shared") loadShared();
}
$$(".nav").forEach((b) => { b.title = b.querySelector("span")?.textContent || ""; b.onclick = () => showTab(b.dataset.tab); });

/* ---------------- music ---------------- */
const greet = () => { const h = new Date().getHours(); return h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"; };
$("#greeting").textContent = greet();

/* recently played: remembered with time + position so you can continue */
/* shared with the iPhone through the PC server: /api/playback */
const DEVICE = "PC";
let playback = { recent: [], now: null };
const getRecent = () => (playback.recent || []).slice(0, 1); // only the last song
async function loadPlayback() { try { playback = await api("/api/playback"); } catch {} renderRecent(); }
let lastPost = 0;
function postPlayback(force = true) {
  if (!player.cur || (!force && Date.now() - lastPost < 10000)) return;
  lastPost = Date.now();
  api("/api/playback", { method: "POST", json: { id: player.cur.id, pos: audio.currentTime || 0, playing: !audio.paused, device: DEVICE } }).catch(() => {});
}
function applyPlayback(p) {
  playback = p; renderRecent();
  // another device started playing: pause here so only one plays
  const n = p.now;
  if (n && n.playing && n.device !== DEVICE && !audio.paused && Date.now() - n.at < 20000) audio.pause();
}
function renderRecent() {
  const items = getRecent().map((x) => ({ ...x, t: tracks.find((t) => t.id === x.id) })).filter((x) => x.t);
  $("#recent-wrap").hidden = !items.length;
  $("#recent-wrap h3").textContent = player.cur && !audio.paused ? "Currently playing" : "Recently played";
  const g = $("#music-glow"), first = items[0];
  g.style.backgroundImage = first && first.t.has_art ? `url('${url("/api/music/art/" + first.t.id)}')` : "none";
  $("#recent-row").innerHTML = items.map((x, i) => `
    <button class="recent glass" data-i="${i}">
      <div class="art" ${x.t.has_art ? `style="background-image:url('${url("/api/music/art/" + x.t.id)}')"` : ""}>${x.t.has_art ? "" : ICON.note}</div>
      <div class="r-body"><b>${esc(x.t.title)}</b><span>${esc(x.t.artist)}</span><small>${ago(x.at)}${x.pos > 3 ? " · resume " + fmtTime(x.pos) : ""}</small></div>
      <div class="r-play">${ICON.play}</div>
    </button>`).join("");
  $$("#recent-row .recent").forEach((b) => (b.onclick = () => {
    const x = items[+b.dataset.i], list = items.map((y) => y.t);
    if (player.cur && player.cur.id === x.t.id) { player.toggle(); return; }
    player.playList(list, +b.dataset.i);
    if (x.pos > 3) audio.addEventListener("loadedmetadata", () => (audio.currentTime = x.pos), { once: true });
  }));
}
async function loadTracks() {
  try { tracks = await api("/api/music/tracks"); } catch { tracks = []; }
  try { playlists = await api("/api/playlists"); } catch { playlists = []; }
  const artists = new Set(tracks.map((t) => t.artist)), albums = new Set(tracks.map((t) => t.album));
  const hours = tracks.reduce((a, t) => a + t.duration, 0) / 3600;
  $("#music-sub").textContent = tracks.length
    ? `${tracks.length} songs · ${artists.size} artists · ${albums.size} albums · ${hours.toFixed(1)} hours`
    : "No music yet — add your music folders in Settings.";
  const chips = [["all", "All songs"], ["recent", "Recently added"], ["long", "Long listens"], ...[...albums].slice(0, 0)];
  const topArtists = Object.entries(tracks.reduce((m, t) => ((m[t.artist] = (m[t.artist] || 0) + 1), m), {}))
    .sort((a, b) => b[1] - a[1]).slice(0, 8).map(([a]) => ["artist:" + a, a]);
  const plChips = playlists.map((p) => ["pl:" + p.id, "♪ " + p.name]);
  $("#music-chips").innerHTML = [...chips, ...plChips, ...topArtists]
    .map(([k, l]) => `<button class="chip ${musicFilter.chip === k ? "active" : ""}" data-k="${esc(k)}">${esc(l)}</button>`).join("");
  $$("#music-chips .chip").forEach((c) => (c.onclick = () => { musicFilter.chip = c.dataset.k; loadTracksView(); $$("#music-chips .chip").forEach((x) => x.classList.toggle("active", x === c)); }));
  loadTracksView();
  loadPlayback();
}

function loadTracksView() {
  const q = musicFilter.q.toLowerCase();
  let list = tracks.filter((t) => !q || `${t.title} ${t.artist} ${t.album}`.toLowerCase().includes(q));
  const c = musicFilter.chip;
  if (c === "recent") list = [...list].sort((a, b) => b.added - a.added).slice(0, 100);
  else if (c === "long") list = list.filter((t) => t.duration > 300);
  else if (c.startsWith("pl:")) { const pl = playlists.find((p) => p.id === c.slice(3)); list = (pl ? pl.trackIDs : []).map((id) => list.find((t) => t.id === id)).filter(Boolean); }
  else if (c.startsWith("artist:")) list = list.filter((t) => t.artist === c.slice(7));
  filtered = list;
  const el = $("#tracklist");
  if (!list.length) { el.innerHTML = `<div class="empty"><b>${tracks.length ? "No matches" : "Your library is empty"}</b>${tracks.length ? "Try another search." : "Open Settings and add the folders where your music lives."}</div>`; return; }
  el.innerHTML = list.map((t, i) => `
    <div class="trow ${player.cur?.id === t.id ? "playing" : ""}" data-id="${t.id}">
      <span class="idx">${i + 1}</span>
      <div class="art" ${t.has_art ? `style="background-image:url('${url("/api/music/art/" + t.id)}')"` : ""}>${t.has_art ? "" : ICON.note}</div>
      <div class="t-title">${esc(t.title)}</div>
      <div class="t-sub">${esc(t.artist)}</div>
      <div class="t-sub">${esc(t.album)}</div>
      <div class="t-dur">${fmtTime(t.duration)}</div>
    </div>`).join("");
  $$(".trow", el).forEach((r) => (r.ondblclick = r.onclick = () => player.playList(filtered, filtered.findIndex((t) => t.id === r.dataset.id))));
}
$("#music-search").oninput = (e) => { musicFilter.q = e.target.value; loadTracksView(); };
$("#music-rescan").onclick = async () => { await invoke("rescan"); toast("Rescanning your library…"); };
$("#music-shuffle").onclick = () => { player.shuffle = true; $("#p-shuffle").classList.add("on"); player.playList(tracks, -1); };

/* ---------------- player (smart shuffle: no repeats until the whole queue is heard) ---------------- */
const audio = $("#audio");
const player = {
  queue: [], order: [], pos: -1, cur: null, shuffle: false, repeat: false,
  playList(list, idx) {
    if (!list.length) return;
    this.queue = list.slice();
    this.buildOrder(idx < 0 ? Math.floor(Math.random() * list.length) : idx);
    this.pos = 0; this.load();
  },
  buildOrder(first) {
    const n = this.queue.length;
    let order = [...Array(n).keys()];
    if (this.shuffle) {
      order.splice(order.indexOf(first), 1);
      for (let i = order.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [order[i], order[j]] = [order[j], order[i]]; }
      // spread out same-artist runs
      for (let i = 1; i < order.length; i++) {
        if (this.queue[order[i]].artist === this.queue[order[i - 1]].artist) {
          const k = order.findIndex((x, j) => j > i && this.queue[x].artist !== this.queue[order[i - 1]].artist);
          if (k > 0) [order[i], order[k]] = [order[k], order[i]];
        }
      }
      order.unshift(first);
    } else {
      order = order.slice(first).concat(order.slice(0, first));
    }
    this.order = order;
  },
  load() {
    const t = this.queue[this.order[this.pos]];
    if (!t) return;
    this.cur = t;
    audio.src = url("/api/music/stream/" + t.id);
    audio.play().catch(() => {});
    $("#np-title").textContent = t.title;
    $("#np-artist").textContent = `${t.artist} — ${t.album}`;
    $("#np-art").style.backgroundImage = t.has_art ? `url('${url("/api/music/art/" + t.id)}')` : "";
    $$(".trow").forEach((r) => r.classList.toggle("playing", r.dataset.id === t.id));
    if ("mediaSession" in navigator) navigator.mediaSession.metadata = new MediaMetadata({ title: t.title, artist: t.artist, album: t.album });
    lyr.idx = -1; loadLyrics();
  },
  enqueue(list) { if (!this.cur) return this.playList(list, 0); for (const t of list) { this.queue.push(t); this.order.push(this.queue.length - 1); } },
  next() { if (!this.queue.length) return; this.pos++; if (this.pos >= this.order.length) { this.buildOrder(this.order[0]); this.pos = 0; if (this.shuffle) this.buildOrder(Math.floor(Math.random() * this.queue.length)); } this.load(); },
  prev() { if (audio.currentTime > 3) { audio.currentTime = 0; return; } this.pos = Math.max(0, this.pos - 1); this.load(); },
  toggle() { if (!this.cur) return tracks.length && this.playList(tracks, 0); audio.paused ? audio.play() : audio.pause(); },
};
audio.onended = () => (player.repeat ? (audio.currentTime = 0, audio.play()) : player.next());
audio.onplay = audio.onpause = () => { postPlayback(); $("#p-play").innerHTML = audio.paused ? ICON.play : ICON.pause; $("#player").classList.toggle("is-playing", !audio.paused); };
audio.ontimeupdate = () => { syncLyrics(); if (!audio.paused) postPlayback(false); $("#p-cur").textContent = fmtTime(audio.currentTime); $("#p-dur").textContent = fmtTime(audio.duration); if (!seeking) $("#p-seek").value = audio.duration ? (audio.currentTime / audio.duration) * 1000 : 0; };
let seeking = false;
$("#p-seek").oninput = () => (seeking = true);
$("#p-seek").onchange = (e) => { if (audio.duration) audio.currentTime = (e.target.value / 1000) * audio.duration; seeking = false; };
$("#p-vol").oninput = (e) => (audio.volume = e.target.value / 100);
audio.volume = 0.8;
$("#p-play").onclick = () => player.toggle();
$("#p-next").onclick = () => player.next();
$("#p-prev").onclick = () => player.prev();
$("#p-shuffle").onclick = (e) => { player.shuffle = !player.shuffle; e.currentTarget.classList.toggle("on", player.shuffle); if (player.cur) { player.buildOrder(player.order[player.pos]); player.pos = 0; } };
$("#p-repeat").onclick = (e) => { player.repeat = !player.repeat; e.currentTarget.classList.toggle("on", player.repeat); };
if ("mediaSession" in navigator) { navigator.mediaSession.setActionHandler("nexttrack", () => player.next()); navigator.mediaSession.setActionHandler("previoustrack", () => player.prev()); }
document.addEventListener("keydown", (e) => { if (e.target.matches("input, textarea")) return; if (e.code === "Space") { e.preventDefault(); player.toggle(); } });

/* ---------------- shared ---------------- */
async function loadShared() {
  let items = [];
  try { items = await api("/api/shared"); } catch {}
  const el = $("#shared-list");
  if (!items.length) { el.innerHTML = `<div class="empty"><b>Nothing shared yet</b>Copy something on your iPhone or PC.</div>`; return; }
  el.innerHTML = items.map(renderShared).join("");
  bindShared(el, items);
}
function renderShared(s) {
  const file = s.kind === "file";
  const from = s.from === "pc" ? "This PC" : s.from;
  return `<div class="sitem ${file ? "file" : ""}" data-id="${s.id}">
    <div class="s-ic">${file ? ICON.file : ICON.clip}</div>
    <div class="s-body"><div class="s-text">${esc(file ? s.name : s.text)}</div>
      <div class="s-meta">${s.kind === "clipboard" ? "Clipboard" : file ? fmtSize(s.size) : "Text"} · from ${esc(from)} · ${ago(s.at)}</div></div>
    <div class="s-act">${file ? `<button class="ic" data-act="reveal" title="Show in folder">${ICON.folder}</button>` : `<button class="ic" data-act="copy" title="Copy">${ICON.copy}</button>`}</div>
  </div>`;
}
function bindShared(el, items) {
  $$("[data-act]", el).forEach((b) => (b.onclick = async () => {
    const it = items.find((x) => x.id === b.closest(".sitem").dataset.id);
    if (!it) return;
    if (b.dataset.act === "copy") { await api("/api/clipboard/silent", { method: "POST", json: { text: it.text } }); toast("Copied"); }
    else if (it.path) invoke("reveal", { path: it.path });
  }));
}
async function sendFiles(files) {
  for (const f of files) {
    toast(`Sending ${f.name}…`);
    try { await api("/api/shared/file?name=" + encodeURIComponent(f.name), { method: "POST", body: f }); }
    catch (e) { toast("Failed: " + e.message); return; }
  }
  toast(files.length > 1 ? `${files.length} files shared` : "File shared with iPhone");
  loadShared();
}
const dz = $("#dropzone");
["dragenter", "dragover"].forEach((ev) => dz.addEventListener(ev, (e) => { e.preventDefault(); dz.classList.add("over"); }));
["dragleave", "drop"].forEach((ev) => dz.addEventListener(ev, (e) => { e.preventDefault(); dz.classList.remove("over"); }));
dz.addEventListener("drop", (e) => sendFiles([...e.dataTransfer.files]));
$("#pick-file").onclick = () => $("#file-input").click();
$("#file-input").onchange = (e) => sendFiles([...e.target.files]);
$("#open-inbox").onclick = () => invoke("open_folder", { path: info.inboxDir });
$("#clip-toggle").onchange = async (e) => { await invoke("save_settings", { s: { clipboardSync: e.target.checked } }); refreshInfo(); toast(e.target.checked ? "Universal clipboard on" : "Universal clipboard off"); };

/* ---------------- media ---------------- */
async function loadMedia() {
  try { media = await api("/api/media/items"); } catch { media = []; }
  const p = media.filter((m) => m.kind === "photo").length, v = media.length - p;
  $("#media-sub").textContent = `${p} photos · ${v} videos · ${media.filter((m) => m.from_iphone).length} from iPhone`;
  renderMedia();
}
const io = new IntersectionObserver((ents) => ents.forEach((e) => {
  if (!e.isIntersecting) return;
  const el = e.target; io.unobserve(el);
  const m = media.find((x) => x.id === el.dataset.id);
  if (!m) return;
  if (m.kind === "photo") {
    const img = new Image(); img.loading = "lazy"; img.onload = () => img.classList.add("loaded");
    img.onerror = () => { el.innerHTML += `<div class="empty" style="padding:30px 6px;font-size:11px">${esc(m.name)}</div>`; };
    img.src = url(`/api/media/thumb/${m.id}?s=360`); el.prepend(img);
  } else {
    const img = new Image(); img.onload = () => img.classList.add("loaded");
    img.onerror = () => {
      img.remove();
      const v = document.createElement("video"); v.muted = true; v.preload = "metadata";
      v.onloadeddata = () => v.classList.add("loaded");
      v.src = url(`/api/media/file/${m.id}`) + "#t=1"; el.prepend(v);
    };
    img.src = url(`/api/media/thumb/${m.id}?s=360`); el.prepend(img);
  }
}), { rootMargin: "400px" });
function renderMedia() {
  const list = media.filter((m) => !mediaKind || (mediaKind === "iphone" ? m.from_iphone : m.kind === mediaKind));
  const g = $("#media-grid");
  if (!list.length) { g.innerHTML = `<div class="empty" style="grid-column:1/-1"><b>No media here</b>Add photo and video folders in Settings, or sync from your iPhone.</div>`; return; }
  g.innerHTML = list.slice(0, 3000).map((m) => `<div class="tile" data-id="${m.id}">
    ${m.kind === "video" ? `<span class="badge">${ICON.video}Video</span>` : ""}${m.from_iphone ? `<span class="phone">${ICON.phone}</span>` : ""}</div>`).join("");
  $$(".tile", g).forEach((t) => { io.observe(t); t.onclick = () => openLightbox(media.find((m) => m.id === t.dataset.id), list); });
}
$$("#media-seg button").forEach((b) => (b.onclick = () => { mediaKind = b.dataset.k; $$("#media-seg button").forEach((x) => x.classList.toggle("active", x === b)); renderMedia(); }));
let lbList = [], lbIdx = 0;
function lbStep(d) { if (!lbList.length) return; lbIdx = (lbIdx + d + lbList.length) % lbList.length; openLightbox(lbList[lbIdx]); }
function openLightbox(m, list) {
  if (list) { lbList = list; }
  lbIdx = Math.max(0, lbList.findIndex((x) => x.id === m.id));
  const body = $("#lb-body");
  body.innerHTML = m.kind === "photo" ? `<img src="${url(`/api/media/thumb/${m.id}?s=1600`)}" onerror="this.src='${url(`/api/media/file/${m.id}`)}'"/>` : `<video src="${url(`/api/media/file/${m.id}`)}" controls autoplay></video>`;
  $("#lightbox").classList.add("open");
}
$("#lb-prev").onclick = (e) => { e.stopPropagation(); lbStep(-1); };
$("#lb-next").onclick = (e) => { e.stopPropagation(); lbStep(1); };
document.addEventListener("keydown", (e) => {
  if (!$("#lightbox").classList.contains("open")) return;
  if (e.key === "ArrowLeft") lbStep(-1); else if (e.key === "ArrowRight") lbStep(1);
  else if (e.key === "Escape") { $("#lightbox").classList.remove("open"); $("#lb-body").innerHTML = ""; }
});
$("#lb-close").onclick = $("#lightbox").onclick = (e) => { if (e.target.closest("img,video")) return; $("#lightbox").classList.remove("open"); $("#lb-body").innerHTML = ""; };

/* ---------------- mobile ---------------- */
async function loadDevices() {
  let list = [];
  try { list = await api("/api/devices"); } catch {}
  const el = $("#devices");
  if (!list.length) {
    el.innerHTML = `<div class="card glass empty" style="grid-column:1/-1"><b>No iPhone paired yet</b>Install MediaGrid on your iPhone and sign in with your account from the Profile tab.</div>`;
    return;
  }
  try { callState = await api("/api/call"); } catch {}
  renderCalls();
  el.innerHTML = list.map((d) => {
    const s = d.status || {};
    const np = s.now_playing;
    const bat = s.battery >= 0 ? Math.round(s.battery * 100) : null;
    return `<div class="device glass" data-tok="${d.token}">
      <div class="d-head"><div class="d-ic">${ICON.phone}</div>
        <div style="flex:1"><div class="d-name">${esc(d.name)}</div>
          <div class="d-state"><span class="dot ${s.connected ? "on" : ""}"></span>${s.connected ? "Connected" : s.last_seen ? "Last seen " + ago(s.last_seen) : "Not connected"}${s.model ? ` · ${esc(s.model)}` : ""}</div></div>
        ${bat !== null ? `<div class="bat-ring" style="--p:${bat}"><b>${bat}%</b><small>${s.charging ? "charging" : "battery"}</small></div>` : ""}</div>
      ${np ? `<div class="d-np"><div class="art">${ICON.note}</div><div class="meta"><b>${esc(np.title)}</b><span>${esc(np.artist || "")}</span></div>
        <button class="ic" data-cmd="prev">${ICON.prev}</button><button class="ic" data-cmd="toggle">${np.playing ? ICON.pause : ICON.play}</button><button class="ic" data-cmd="next">${ICON.next}</button></div>` : ""}
      <div class="tiles">
        <button class="tile-btn" data-cmd="find"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3"/></svg>Find iPhone</button>
        <button class="tile-btn" data-cmd="syncPhotos"><svg viewBox="0 0 24 24"><rect x="3" y="3" width="18" height="18" rx="4"/><circle cx="9" cy="9" r="2"/><path d="M21 15l-5-5L5 21"/></svg>Sync photos</button>
        <button class="tile-btn" data-cmd="shuffle"><svg viewBox="0 0 24 24"><path d="M16 3h5v5M4 20L21 3M21 16v5h-5M15 15l6 6M4 4l5 5"/></svg>Shuffle music</button>
        <button class="tile-btn danger" data-revoke="${d.token}"><svg viewBox="0 0 24 24"><path d="M10 13a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-1 1M14 11a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l1-1"/></svg>Unpair</button>
      </div></div>`;
  }).join("");
  $$("[data-cmd]", el).forEach((b) => (b.onclick = async () => {
    const c = b.dataset.cmd;
    const cmd = ["prev", "toggle", "next", "shuffle"].includes(c) ? { cmd: "player", action: c } : { cmd: c };
    await api("/api/phone", { method: "POST", json: cmd });
    toast(c === "find" ? "Ringing your iPhone…" : c === "syncPhotos" ? "Asked iPhone to sync photos" : "Sent");
  }));
  $$("[data-revoke]", el).forEach((b) => (b.onclick = async () => { await invoke("revoke_device", { prefix: b.dataset.revoke }); loadDevices(); }));
}
/* calls reported by the iPhone (state only: iOS does not share who is calling, SMS or contacts) */
let callState = { current: null, log: [] };
const dur = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
function renderCalls() {
  const c = callState.current, log = callState.log || [];
  const label = { ringing: "Incoming call", dialing: "Calling…", active: "On a call" };
  const live = c ? `<div class="call-live ${c.state}"><div class="cl-ic">${ICON.phone}</div><div><b>${label[c.state] || "Call"}</b><span>${c.state === "active" ? "Talking on your iPhone" : "Your iPhone"}</span></div></div>` : "";
  const rows = log.map((x) => {
    const missed = !x.answered && x.direction !== "outgoing";
    const kind = x.direction === "outgoing" ? "Outgoing" : missed ? "Missed" : "Incoming";
    return `<div class="call-row ${missed ? "missed" : ""}"><div class="cr-ic">${ICON.phone}</div><div class="cr-body"><b>${kind} call</b><span>${ago(x.at)}</span></div><div class="cr-dur">${x.answered ? dur(x.duration || 0) : "—"}</div></div>`;
  }).join("");
  $("#calls").innerHTML = `<h3>Calls</h3>${live}${rows || `<div class="muted">No calls yet. A floating bubble appears here on your PC while your iPhone is in a call.</div>`}
    <div class="hint"><div><b>Messages & contacts</b>iPhone does not let apps read SMS or contacts, so they can't appear here.</div></div>`;
}
$("#req-sync").onclick = async () => { await api("/api/phone", { method: "POST", json: { cmd: "syncPhotos" } }); toast("Asked iPhone to sync new photos"); };

/* ---------------- profile ---------------- */
function renderProfile() {
  $("#acct-email").value = info.email || "";
  $("#acct-title").textContent = info.hasAccount ? "Your account" : "Create your account";
  $("#acct-desc").textContent = info.hasAccount ? "Changing the password signs out paired iPhones." : "Sign in with the same email and password on your iPhone.";
  $("#avatar").textContent = (info.email || "MG").slice(0, 2).toUpperCase();
  $("#pc-name").value = info.name;
  $("#addr-list").innerHTML = (info.addresses || []).map((a) => `<div class="addr"><span class="tag ${a.kind}">${a.kind === "tailscale" ? "Tailscale" : "Wi-Fi / LAN"}</span><code>${a.ip}:${info.port}</code><button class="ic" data-copy="${a.ip}:${info.port}">${ICON.copy}</button></div>`).join("") || `<div class="muted">No network found.</div>`;
  $$("[data-copy]").forEach((b) => (b.onclick = async () => { await navigator.clipboard.writeText(b.dataset.copy); toast("Address copied"); }));
}
$("#acct-save").onclick = async () => {
  const m = $("#acct-msg");
  try {
    await invoke("set_account", { email: $("#acct-email").value, password: $("#acct-pass").value });
    $("#acct-pass").value = ""; m.className = "msg ok"; m.textContent = "Saved. Sign in on your iPhone with these details.";
    refreshInfo();
  } catch (e) { m.className = "msg err"; m.textContent = e; }
};
$("#fw-allow").onclick = async () => {
  try { await invoke("allow_firewall"); toast("Approve the Windows prompt to allow MediaGrid through the firewall"); }
  catch (e) { toast("Couldn't open the firewall prompt: " + e); }
};
$("#pc-name-save").onclick = async () => { await invoke("save_settings", { s: { name: $("#pc-name").value } }); toast("Renamed — restart MediaGrid to update Wi-Fi discovery"); refreshInfo(); };

/* ---------------- settings ---------------- */
function folderRow(v = "") {
  const d = document.createElement("div"); d.className = "folder";
  d.innerHTML = `<input value="${esc(v)}" placeholder="C:\\Users\\you\\Music" /><button class="ic" data-browse title="Browse">${ICON.folder}</button><button class="ic" data-del title="Remove">${ICON.x}</button>`;
  $("[data-browse]", d).onclick = async () => { const p = await pickFolder(); if (p) $("input", d).value = p; };
  const del = $("[data-del]", d); del.onclick = () => d.remove();
  return d;
}
async function pickFolder() {
  try { return await invoke("plugin:dialog|open", { options: { directory: true, multiple: false } }); } catch { return null; }
}
function renderSettings() {
  for (const [id, list] of [["music-dirs", info.musicDirs], ["media-dirs", info.mediaDirs]]) { const el = $("#" + id); el.innerHTML = ""; (list || []).forEach((v) => el.append(folderRow(v))); }
  for (const [id, v] of [["photo-dir", info.photoSyncDir], ["inbox-dir", info.inboxDir]]) { const el = $("#" + id); el.innerHTML = ""; const r = folderRow(v); r.querySelector("[data-del]").remove(); el.append(r); }
  $("#s-autostart").checked = info.autostart; $("#s-clip").checked = info.clipboardSync; $("#s-remote").checked = info.remoteControl; $("#s-photos").checked = info.autoPhotoSync;
  $("#s-ecokeep").value = info.ecoKeep || ""; ecoOn = info.ecoOn; renderEco();
  $("#eco-sched").checked = info.ecoSchedule; $("#eco-from").value = info.ecoFrom; $("#eco-to").value = info.ecoTo;
  $("#s-accept").checked = info.acceptPhoneStream; $("#s-pcaudio").checked = info.sharePcAudio;
  $("#clip-toggle").checked = info.clipboardSync;
}
$$("[data-add]").forEach((b) => (b.onclick = () => $("#" + b.dataset.add).append(folderRow(""))));
$("#settings-save").onclick = async () => {
  const vals = (id) => $$(`#${id} input`).map((i) => i.value.trim()).filter(Boolean);
  await invoke("save_settings", { s: {
    musicDirs: vals("music-dirs"), mediaDirs: vals("media-dirs"), photoSyncDir: vals("photo-dir")[0], inboxDir: vals("inbox-dir")[0],
    autostart: $("#s-autostart").checked, clipboardSync: $("#s-clip").checked, remoteControl: $("#s-remote").checked, autoPhotoSync: $("#s-photos").checked,
    ecoKeep: $("#s-ecokeep").value,
    acceptPhoneStream: $("#s-accept").checked, sharePcAudio: $("#s-pcaudio").checked,
  } });
  toast("Settings saved"); refreshInfo();
};

/* ---------------- lyrics ---------------- */
const lyr = { lines: [], plain: "", on: false, idx: -1 };
async function loadLyrics() {
  if (!lyr.on || !player.cur) return;
  const id = player.cur.id, body = $("#lyrics-body");
  body.textContent = "Looking for lyrics…"; lyr.lines = [];
  try {
    const d = await api("/api/music/lyrics/" + id);
    if (player.cur?.id !== id) return;
    lyr.lines = (d.synced || "").split("\n").map((l) => { const m = l.match(/^\[(\d+):(\d+(?:\.\d+)?)\](.*)$/); return m ? { t: +m[1] * 60 + +m[2], s: m[3].trim() } : null; }).filter(Boolean);
    body.innerHTML = lyr.lines.length ? lyr.lines.map((l, i) => `<p data-i="${i}">${esc(l.s) || "♪"}</p>`).join("")
      : d.plain ? `<pre>${esc(d.plain)}</pre>` : "No lyrics found for this song.";
    $$("#lyrics-body p").forEach((p) => (p.onclick = () => (audio.currentTime = lyr.lines[+p.dataset.i].t)));
  } catch { body.textContent = "Couldn't load lyrics."; }
}
function syncLyrics() {
  if (!lyr.on || !lyr.lines.length) return;
  let i = lyr.lines.findIndex((l) => l.t > audio.currentTime + 0.2) - 1;
  if (i === -2) i = lyr.lines.length - 1;
  if (i === lyr.idx) return;
  lyr.idx = i;
  $$("#lyrics-body p").forEach((p, k) => p.classList.toggle("active", k === i));
  $(`#lyrics-body p[data-i="${i}"]`)?.scrollIntoView({ block: "center", behavior: "smooth" });
}
$("#p-lyrics").onclick = () => { lyr.on = !lyr.on; $("#lyrics-panel").hidden = !lyr.on; $("#p-lyrics").classList.toggle("on", lyr.on); loadLyrics(); };

/* ---------------- eco mode ---------------- */
let ecoOn = false;
function renderEco() { $("#eco-btn").textContent = ecoOn ? "Turn eco mode off" : "Turn eco mode on"; $("#eco-btn").classList.toggle("primary", !ecoOn); }
$("#eco-btn").onclick = () => {
  if (!ecoOn && !confirm("Freeze all your other apps and turn the screen off?\n\nNothing is closed or lost. Turn it off again from here, the iPhone, the tray menu or Ctrl+Alt+E.")) return;
  invoke("toggle_eco");
};

const saveEcoSchedule = () => invoke("save_settings", { s: { ecoSchedule: $("#eco-sched").checked, ecoFrom: $("#eco-from").value, ecoTo: $("#eco-to").value } }).then(() => toast("Eco schedule saved"));
["#eco-sched", "#eco-from", "#eco-to"].forEach((id) => ($(id).onchange = saveEcoSchedule));

/* ---------------- lock when away ---------------- */
async function loadPresence() {
  try { const p = await api("/api/presence"); $("#away-on").checked = p.lock; $("#away-min").value = p.minutes; } catch { /* PC app not ready yet */ }
}
const savePresence = () => api("/api/presence", { method: "POST", json: { lock: $("#away-on").checked, minutes: +$("#away-min").value || 3 } }).catch((e) => toast(e.message));
$("#away-on").onchange = savePresence;
$("#away-min").onchange = savePresence;

/* ---------------- drop files to send them to the iPhone ---------------- */
T.webview?.getCurrentWebview?.().onDragDropEvent((e) => {
  const p = e.payload;
  if (p.type === "enter" || p.type === "over") $("#dropzone").hidden = false;
  else {
    $("#dropzone").hidden = true;
    if (p.type === "drop" && p.paths?.length) invoke("send_files", { paths: p.paths }).then(() => toast(`Sent ${p.paths.length} file${p.paths.length > 1 ? "s" : ""} to your iPhone`));
  }
});

/* ---------------- iPhone camera & mic ---------------- */
const cam = { state: { camera: false, mic: false }, ctx: null, abort: null };

function renderCam() {
  const s = cam.state, img = $("#cam-view");
  const on = [s.camera && "camera", s.mic && "microphone"].filter(Boolean);
  $("#cam-status").textContent = on.length ? `Streaming from the iPhone: ${on.join(" + ")}` : "Off. Start it on the iPhone: PC tab → Access PC → Webcam & mic.";
  if (s.camera) { if (!img.src.includes("cam.mjpg")) img.src = url("/cam.mjpg"); img.hidden = false; } else { img.removeAttribute("src"); img.hidden = true; }
  $("#cam-url").value = url("/cam.mjpg").replace("127.0.0.1", "localhost");
  if (s.mic && $("#cam-listen").checked) startMic(); else stopMic();
  loadVcam();
}

/* The phone sends 16 kHz mono 16-bit PCM; play it with small buffering, on the chosen output device. */
async function startMic() {
  if (cam.abort) return;
  const abort = (cam.abort = new AbortController());
  try {
    const ctx = (cam.ctx = new AudioContext({ sampleRate: 16000 }));
    await ctx.resume();
    const sink = $("#mic-out").value;
    if (sink && ctx.setSinkId) await ctx.setSinkId(sink).catch(() => {});
    const reader = (await fetch(url("/api/cam/audio"), { signal: abort.signal })).body.getReader();
    let t = ctx.currentTime + 0.15, left = new Uint8Array(0);
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      const b = new Uint8Array(left.length + value.length); b.set(left); b.set(value, left.length);
      const n = b.length - (b.length % 2); left = b.slice(n);
      const pcm = new Int16Array(b.slice(0, n).buffer), f = new Float32Array(pcm.length);
      for (let i = 0; i < pcm.length; i++) f[i] = pcm[i] / 32768;
      const buf = ctx.createBuffer(1, f.length, 16000); buf.copyToChannel(f, 0);
      const src = ctx.createBufferSource(); src.buffer = buf; src.connect(ctx.destination);
      if (t < ctx.currentTime) t = ctx.currentTime + 0.1;   // fell behind: re-buffer
      else if (t - ctx.currentTime > 0.6) continue;         // too far ahead (burst): drop it so the mic stays live
      src.start(t); t += buf.duration;
    }
  } catch { /* stopped or phone went away */ }
  if (cam.abort === abort) stopMic();
}
function stopMic() { cam.abort?.abort(); cam.abort = null; cam.ctx?.close().catch(() => {}); cam.ctx = null; }

async function loadVcam() {
  try {
    const v = await api("/api/vcam");
    $("#vcam-install").hidden = !(v.available && !v.installed);
    $("#vcam-flip").checked = v.flip;
    $("#vcam-status").textContent = !v.available ? "The virtual camera is not included in this build."
      : !v.installed ? "Install it once (Windows asks for permission). Then start the camera on the iPhone and pick “DirectShow Softcam” as the camera in Zoom, Teams, Chrome or OBS."
      : v.on ? "On. Pick “DirectShow Softcam” as the camera in your video app." : "Installed. It switches on when the iPhone camera starts. Pick “DirectShow Softcam” as the camera in your video app.";
  } catch (e) { $("#vcam-status").textContent = String(e.message || e); }
}
$("#vcam-install").onclick = async () => {
  try { await api("/api/vcam/install", { method: "POST" }); toast("Virtual camera installed"); } catch (e) { toast(e.message); }
  loadVcam();
};
$("#vcam-flip").onchange = () => api("/api/vcam", { method: "POST", json: { flip: $("#vcam-flip").checked } });

$("#cam-listen").onchange = renderCam;
$("#cam-copy").onclick = () => { navigator.clipboard.writeText($("#cam-url").value); toast("Address copied"); };
$("#cam-outputs").onclick = async () => {
  try { (await navigator.mediaDevices.getUserMedia({ audio: true })).getTracks().forEach((t) => t.stop()); } catch { /* names stay generic without permission */ }
  const outs = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === "audiooutput");
  $("#mic-out").innerHTML = `<option value="">Default speakers</option>` + outs.map((d) => `<option value="${esc(d.deviceId)}">${esc(d.label || "Audio output")}</option>`).join("");
  const virt = outs.find((d) => /cable|virtual|vb-audio/i.test(d.label));
  if (virt) $("#mic-out").value = virt.deviceId;
  stopMic(); renderCam();
};
$("#mic-out").onchange = () => { stopMic(); renderCam(); };

/* ---------------- boot ---------------- */
async function refreshInfo() {
  info = await invoke("get_info");
  BASE = `http://127.0.0.1:${info.port}`; TOKEN = info.uiToken;
  const pill = $("#status-pill");
  pill.textContent = info.serverError ? "Not reachable — port in use" : info.scanning ? "Scanning library…" : `Running · port ${info.port}`;
  pill.classList.toggle("ok", !info.scanning && !info.serverError);
  pill.classList.toggle("bad", !!info.serverError);
  pill.title = info.serverError || "";
  renderProfile(); renderSettings();
}

T.event.listen("mg", ({ payload }) => {
  const { event, data } = payload;
  if (event === "scan") { refreshInfo(); if (!data.scanning) { loadTracks(); media = []; if ($("#tab-media").classList.contains("active")) loadMedia(); } }
  else if (event === "shared") { const el = $("#shared-list"); if ($(".empty", el)) el.innerHTML = ""; el.insertAdjacentHTML("afterbegin", renderShared(data)); bindShared(el, [data]); if (data.from !== "pc") toast(data.kind === "file" ? `Received ${data.name}` : "Clipboard from iPhone"); }
  else if (event === "devices") { if ($("#tab-mobile").classList.contains("active")) loadDevices(); }
  else if (event === "photo") {
    info.syncedPhotos++;
    if (data.item && media.length) { media.unshift(data.item); if ($("#tab-media").classList.contains("active")) renderMedia(); }
  }
  else if (event === "playback") applyPlayback(data);
  else if (event === "call") {
    if (data.state === "ended") { callState.current = null; callState.log = [data, ...(callState.log || [])].slice(0, 30); toast(data.answered ? `Call ended · ${dur(data.duration || 0)}` : "Missed call"); }
    else callState.current = data;
    renderCalls();
  }
  else if (event === "playlists") { playlists = data; loadTracks(); }
  else if (event === "cam") { cam.state = data; renderCam(); }
  else if (event === "eco") { ecoOn = data.on; renderEco(); toast(data.on ? "Eco mode on" : "Eco mode off"); }
  else if (event === "pcplay") {
    const list = (data.ids || []).map((id) => tracks.find((t) => t.id === id)).filter(Boolean);
    if (list.length) { data.mode === "queue" ? player.enqueue(list) : player.playList(list, 0); toast(data.mode === "queue" ? "Added to the PC queue" : `Playing ${list[0].title}`); }
  }
  else if (event === "error") toast(data.message);
});

(async () => {
  await refreshInfo();
  api("/api/cam/state").then((s) => { cam.state = s; renderCam(); }).catch(() => {});
  loadPresence();
  await loadTracks();
  loadShared();
  if (!info.hasAccount) { showTab("profile"); toast("Create an account to pair your iPhone"); }
})();
