"use strict";
// A bounded, on-demand view of host snapshots. Never merges response pages or
// promotes an older song to current membership. No network requests or timers.
const ListenMusic = (() => {
  const token = v => typeof v === "string" && /^[A-Za-z0-9_-]{1,160}$/.test(v) ? v : null;
  const text = v => typeof v === "string" ? v.slice(0, 240) : "";
  const count = v => Number.isSafeInteger(v) && v >= 0 && v <= 1000000 ? v : null;
  const date = v => typeof v === "string" && Number.isFinite(Date.parse(v)) ? v.slice(0, 64) : null;
  function summary(v) {
    if (!v || !token(v.id) || count(v.cached) === null) return null;
    const total = count(v.total);
    return { id: v.id, title: text(v.title), cached: v.cached, total, updatedAt: date(v.updatedAt),
      partial: total === null || v.cached !== total, historical: v.historical === true,
      historyCount: count(v.historyCount) || 0 };
  }
  function clean(v) {
    if (!v || !Number.isSafeInteger(v.request)) return null;
    if (v.error) return { request: v.request, error: "Cached music is unavailable. Open 汽水 on the laptop, then reopen Music." };
    if (!token(v.revision) || !Array.isArray(v.lists) || v.lists.length > 200) return null;
    const lists = v.lists.map(summary);
    if (lists.some(x => !x)) return null;
    let list = null, page = null;
    if (v.list) {
      list = summary(v.list);
      if (!list || !Array.isArray(v.list.snapshots) || v.list.snapshots.length > 200) return null;
      list.snapshots = v.list.snapshots.map(s => s && token(s.id) && count(s.cached) !== null ? {
        id: s.id, updatedAt: date(s.updatedAt), cached: s.cached, total: count(s.total), historical: s.historical === true
      } : null);
      if (list.snapshots.some(s => !s)) return null;
    }
    if (v.page) {
      const p = v.page;
      if (!list || !token(p.snapshot) || !Array.isArray(p.rows) || p.rows.length > 100 || count(p.offset) === null ||
          (p.nextOffset !== null && count(p.nextOffset) === null)) return null;
      const snapshot = list.snapshots.find(s => s.id === p.snapshot);
      if (!snapshot) return null;
      const rows = p.rows.map(r => r && token(r.id) ? { id: r.id, title: text(r.title), artist: text(r.artist),
        durationMs: Number.isSafeInteger(r.durationMs) && r.durationMs > 0 && r.durationMs <= 86400000 ? r.durationMs : null,
        playable: !snapshot.historical && r.playable === true } : null);
      if (rows.some(r => !r)) return null;
      page = { snapshot: p.snapshot, rows, offset: p.offset, nextOffset: p.nextOffset };
    }
    return { request: v.request, available: v.available === true, revision: v.revision, lists, list, page };
  }
  const time = v => v ? new Date(v).toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }) : "unknown";
  const note = v => `${v.cached} of ${v.total === null ? "?" : v.total} cached · updated ${time(v.updatedAt)}`;
  function create({ send, state, toast }) {
    const el = id => document.getElementById(id);
    let open = false, busy = false, request = 0, data = null, selected = null, snapshot = null, offset = 0;
    const node = (tag, value, cls) => { const e = document.createElement(tag); e.textContent = value; if (cls) e.className = cls; return e; };
    function close() {
      if (!open) return;
      open = false; busy = false; data = null; request++;
      send({ t: "musicClose" }); el("music-backdrop").hidden = true;
      el("music-btn").setAttribute("aria-expanded", "false");
      el("music-body").replaceChildren(); el("music-status").textContent = "";
      if (!el("music-btn").hidden) el("music-btn").focus();
    }
    function load(nextList = null, nextSnapshot = null, nextOffset = 0) {
      if (!open || busy) return;
      selected = nextList; snapshot = nextSnapshot; offset = nextOffset; busy = true;
      el("music-body").replaceChildren(); el("music-status").textContent = "Reading laptop cache…";
      el("music-back").hidden = !selected; el("music-heading").textContent = "Music";
      update();
      send({ t: "musicBrowse", request: ++request, ...(selected ? { list: selected } : {}),
        ...(snapshot ? { snapshot } : {}), offset });
    }
    function show() {
      if (!state().music || state().connection !== "connected") return;
      open = true; selected = null; data = null; busy = false;
      el("music-backdrop").hidden = false; el("music-btn").setAttribute("aria-expanded", "true");
      el("music-close").focus(); load();
    }
    function describe(parent, s) {
      parent.append(node("small", note(s), "music-note"));
      if (s.partial) parent.append(node("small", "汽水 only shared part of this list.", "music-partial"));
    }
    function paint() {
      const body = el("music-body"); body.replaceChildren();
      if (!data || data.error) return;
      if (!data.list) {
        el("music-heading").textContent = "Music";
        for (const list of data.lists) {
          const b = node("button", "", "music-list"); b.type = "button";
          b.append(node("span", list.title, "music-name")); describe(b, list);
          if (list.historical) b.append(node("small", "Earlier snapshot · list no longer in the current cache", "music-partial"));
          if (list.historyCount) b.append(node("small", `${list.historyCount} earlier snapshot${list.historyCount === 1 ? "" : "s"} available`, "music-note"));
          b.onclick = () => load(list.id); body.append(b);
        }
        if (!data.lists.length) body.append(node("p", "No cached playlists yet. Open a playlist in 汽水 on the laptop, then read the cache again."));
      } else {
        const list = data.list, page = data.page;
        el("music-heading").textContent = list.title;
        const s = page && list.snapshots.find(s => s.id === page.snapshot);
        describe(body, s ? { ...s, partial: s.total === null || s.cached !== s.total } : list);
        if (list.snapshots.length > 1) {
          const label = node("label", "Snapshot", "music-note");
          const chooser = node("select", "", "music-snapshots"); chooser.setAttribute("aria-label", "Cached snapshot");
          for (const entry of list.snapshots) {
            const option = node("option", `${entry.historical ? "Earlier" : "Newest"} · ${note(entry)}`); option.value = entry.id; chooser.append(option);
          }
          if (page) chooser.value = page.snapshot;
          chooser.onchange = () => load(list.id, chooser.value); label.append(chooser); body.append(label);
        }
        if (s?.historical) body.append(node("p", "Earlier snapshot · browsing only. Current membership is unconfirmed.", "music-partial"));
        for (const row of page?.rows || []) {
          const b = node("button", "", "music-track"); b.type = "button"; b.disabled = !row.playable || state().pending || state().control !== "mine" || state().connection !== "connected";
          const meta = node("span", "", "music-track-meta"); meta.append(node("span", row.title, "music-name"), node("small", row.artist, "music-note"));
          const seconds = row.durationMs === null ? null : Math.floor(row.durationMs / 1000);
          const duration = seconds === null ? "" : `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
          const action = node("span", "", "music-track-action");
          action.append(node("small", duration, "music-duration"), node("span", row.playable ? "▷" : "—", "music-play"));
          b.append(meta, action);
          b.onclick = () => {
            if (busy || state().pending || state().control !== "mine") return;
            send({ t: "musicPlay", list: list.id, snapshot: page.snapshot, track: row.id, revision: data.revision });
          }; body.append(b);
        }
        if (page && (page.offset > 0 || page.nextOffset !== null)) {
          const nav = node("div", "", "music-pages");
          if (page.offset > 0) { const b = node("button", "First page"); b.onclick = () => load(list.id, page.snapshot); nav.append(b); }
          if (page.nextOffset !== null) { const b = node("button", "Next page ›"); b.onclick = () => load(list.id, page.snapshot, page.nextOffset); nav.append(b); }
          body.append(nav);
        }
      }
    }
    function receive(raw) {
      const value = clean(raw);
      if (!open || !value || value.request !== request) return;
      busy = false; data = value;
      el("music-status").textContent = value.error || (!value.available ? "Cached music is unavailable on this laptop." : "");
      paint(); update();
    }
    function update() {
      const s = state(); el("music-btn").hidden = !s.music;
      if (!s.music) { close(); return; }
      el("music-btn").disabled = s.connection !== "connected";
      el("music-refresh").disabled = busy || s.connection !== "connected";
      el("music-back").disabled = busy;
      if (open) for (const b of el("music-body").querySelectorAll(".music-track")) {
        const row = data?.page?.rows[Array.from(b.parentNode.querySelectorAll(".music-track")).indexOf(b)];
        b.disabled = !row?.playable || s.pending || s.control !== "mine" || s.connection !== "connected";
      }
    }
    el("music-btn").onclick = show; el("music-close").onclick = close;
    el("music-back").onclick = () => load(); el("music-refresh").onclick = () => load(selected);
    el("music-backdrop").onclick = e => { if (e.target === el("music-backdrop")) close(); };
    el("music-backdrop").addEventListener("keydown", e => {
      if (e.key === "Escape") { e.preventDefault(); close(); }
      if (e.key === "Tab") {
        const focusable = Array.from(el("music-backdrop").querySelectorAll("button:not([disabled]),select:not([disabled])")).filter(e => !e.hidden);
        const first = focusable[0], last = focusable.at(-1);
        if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last?.focus(); }
        else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first?.focus(); }
      }
    });
    return { receive, update };
  }
  return { clean, note, create };
})();
