"use strict";
// A bounded, on-demand view of host snapshots. Never merges response pages or
// promotes an older song to current membership. Provider reads go through Dart
// and the existing owner command endpoint, never directly from this page.
const ListenMusic = (() => {
  const token = v => typeof v === "string" && /^[A-Za-z0-9_-]{1,160}$/.test(v) ? v : null;
  const text = v => typeof v === "string" ? v.slice(0, 240) : "";
  const count = v => Number.isSafeInteger(v) && v >= 0 && v <= 1000000 ? v : null;
  const date = v => typeof v === "string" && Number.isFinite(Date.parse(v)) ? v.slice(0, 64) : null;
  function summary(v) {
    if (!v || !token(v.id) || count(v.cached) === null) return null;
    const total = count(v.total);
    return { id: v.id, title: v.liked === true ? "Liked songs" : text(v.title), cached: v.cached, total, updatedAt: date(v.updatedAt),
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
    let search = null;
    if (v.search) {
      const q = v.search;
      if (typeof q.query !== "string" || !Array.isArray(q.rows) || q.rows.length > 50) return null;
      const rows = q.rows.map(r => r && token(r.id) && token(r.list) && token(r.snapshot) ? {
        id: r.id, list: r.list, snapshot: r.snapshot, listTitle: text(r.listTitle), title: text(r.title), artist: text(r.artist),
        durationMs: Number.isSafeInteger(r.durationMs) && r.durationMs > 0 && r.durationMs <= 86400000 ? r.durationMs : null,
        playable: r.playable === true } : null);
      if (rows.some(r => !r)) return null;
      search = { query: q.query.slice(0, 120), rows, more: q.more === true };
    }
    return { request: v.request, available: v.available === true, revision: v.revision, lists, list, page, search };
  }
  const time = v => v ? new Date(v).toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }) : "unknown";
  const note = v => `${v.cached} of ${v.total === null ? "?" : v.total} cached · updated ${time(v.updatedAt)}`;
  function cleanOnline(v) {
    if (!v || !Number.isSafeInteger(v.request) || v.request < 0) return null;
    if (v.error) {
      const messages = {
        soda_online_rate_limited: "汽水 is limiting searches. Wait a moment, then search again. Your cached lists still work.",
        rate_limited: "Too many requests. Wait a moment, then search again.",
        soda_online_timeout: "汽水 took too long to respond. Search again to retry.",
        soda_online_rejected: "汽水 did not accept this search. Your cached lists still work.",
        soda_schema_changed: "汽水 returned an unexpected response. Your cached lists still work."
      };
      return {request: v.request, error: Object.hasOwn(messages, v.errorCode) ? messages[v.errorCode] :
        "Online 汽水 is unavailable. Your cached lists still work."};
    }
    if (!token(v.revision) || !["search", "modes"].includes(v.kind) || typeof v.query !== "string" ||
        Array.from(v.query).length > 120 || !Array.isArray(v.rows) || v.rows.length > 20 ||
        !Array.isArray(v.modes) || v.modes.length > 80) return null;
    const rows = v.rows.map(r => r && token(r.id) && Number.isSafeInteger(r.durationMs) &&
      r.durationMs > 0 && r.durationMs <= 86400000 ? {id:r.id, title:text(r.title), artist:text(r.artist),
        durationMs:r.durationMs, playable:v.playbackReady === true && r.playable === true} : null);
    const modes = v.modes.map(m => m && token(m.id) && typeof m.label === "string" ?
      {id:m.id, label:text(m.label)} : null);
    if (rows.some(r => !r) || modes.some(m => !m)) return null;
    return {request:v.request, revision:v.revision, kind:v.kind, query:v.query, rows, modes,
      playbackReady:v.playbackReady === true};
  }
  function create({ send, state, toast }) {
    const el = id => document.getElementById(id);
    let open = false, busy = false, request = 0, data = null, selected = null, snapshot = null, offset = 0;
    let query = "", searchTimer = null;
    let onlineRequest = 0, onlineData = null, onlineBusy = false, modeView = false;
    const rowOf = new WeakMap(); // track button -> its row, for enable/disable
    const node = (tag, value, cls) => { const e = document.createElement(tag); e.textContent = value; if (cls) e.className = cls; return e; };
    function close() {
      if (!open) return;
      open = false; busy = false; data = null; request++;
      clearTimeout(searchTimer); query = ""; el("music-search").value = "";
      onlineRequest++; onlineData = null; onlineBusy = false; modeView = false;
      send({ t: "musicClose" }); el("music-backdrop").hidden = true;
      el("music-btn").setAttribute("aria-expanded", "false");
      el("music-body").replaceChildren(); el("music-status").textContent = "";
      if (!el("music-btn").hidden) el("music-btn").focus();
    }
    function load(nextList = null, nextSnapshot = null, nextOffset = 0) {
      if (!open || busy) return;
      selected = nextList; snapshot = nextSnapshot; offset = nextOffset; busy = true;
      onlineRequest++; onlineData = null; onlineBusy = false; modeView = false;
      el("music-body").replaceChildren(); el("music-status").textContent = "Reading laptop cache…";
      el("music-search").hidden = !!selected || !state().musicSearch;
      el("music-back").hidden = !selected; el("music-heading").textContent = "Music";
      update();
      send({ t: "musicBrowse", request: ++request, ...(selected ? { list: selected } : {}),
        ...(snapshot ? { snapshot } : {}), offset });
    }
    function search(text, force = false) {
      if (!open) return;
      const next = text.trim().slice(0, 120);
      if (!force && next && next === query && !modeView && (busy || onlineBusy)) return;
      query = next;
      if (!query) { busy = false; load(); return; }
      selected = null; snapshot = null; offset = 0; busy = true;
      modeView = false; data = null; el("music-body").replaceChildren();
      el("music-back").hidden = false; el("music-heading").textContent = "Search";
      el("music-status").textContent = "Searching your cached songs…";
      update();
      send({ t: "musicBrowse", request: ++request, query });
      loadOnline("search");
    }
    function loadOnline(kind) {
      onlineData = null; onlineBusy = false; ++onlineRequest;
      if (!state().musicOnline) return;
      if (kind === "search" && Array.from(query).length < 2) { paintOnline(); return; }
      onlineBusy = true; paintOnline();
      send({t:"musicOnline", request:onlineRequest, kind, ...(kind === "search" ? {query} : {})});
    }
    function paintOnline() {
      const body = el("music-body"); body.querySelector(".music-online")?.remove();
      if (!state().musicOnline || (!query && !modeView)) return;
      const section = node("section", "", "music-online");
      section.append(node("h3", modeView ? "Listening modes" : "On 汽水", "music-name"));
      if (onlineBusy) section.append(node("p", "Reading 汽水…", "music-note"));
      else if (onlineData?.error) section.append(node("p", onlineData.error, "music-note"));
      else if (!onlineData) section.append(node("p", "Enter at least two characters for online search.", "music-note"));
      else if (onlineData.kind === "modes") {
        section.append(node("p", "Current 汽水 catalogue. Recommendation contents are not verified yet; selecting a mode is unavailable. This does not change the laptop app’s mode.", "music-note"));
        for (const mode of onlineData.modes) {
          const b = node("button", mode.label, "music-list"); b.type = "button"; b.disabled = true; section.append(b);
        }
      } else {
        section.append(node("p", onlineData.playbackReady ?
          "Anonymous results · 汽水 decides availability. Playing brings the laptop app to the front and changes its queue." :
          "Anonymous results · browse only until the supervised playback check passes.", "music-note"));
        for (const row of onlineData.rows) {
          const b = trackButton(row, row.artist);
          b.onclick = () => {
            if (b.disabled || busy || state().pending || state().control !== "mine") return;
            send({t:"musicOnlinePlay", revision:onlineData.revision, track:row.id});
          }; section.append(b);
        }
        if (!onlineData.rows.length) section.append(node("p", "No online matches returned.", "music-note"));
      }
      body.append(section);
    }
    function receiveOnline(raw) {
      const value = cleanOnline(raw);
      if (!open || !value || value.request !== onlineRequest ||
          (!value.error && value.kind === "search" && value.query !== query)) return;
      onlineBusy = false; onlineData = value; paintOnline(); update();
    }
    function play(listId, snapshotId, trackId) {
      if (busy || state().pending || state().control !== "mine") return;
      send({ t: "musicPlay", list: listId, snapshot: snapshotId, track: trackId, revision: data.revision });
    }
    function trackButton(row, sub) {
      const b = node("button", "", "music-track"); b.type = "button"; rowOf.set(b, row);
      b.disabled = !row.playable || state().pending || state().control !== "mine" || state().connection !== "connected";
      const meta = node("span", "", "music-track-meta"); meta.append(node("span", row.title, "music-name"), node("small", sub, "music-note"));
      const seconds = row.durationMs === null ? null : Math.floor(row.durationMs / 1000);
      const duration = seconds === null ? "" : `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
      const action = node("span", "", "music-track-action");
      action.append(node("small", duration, "music-duration"), node("span", row.playable ? "▷" : "—", "music-play"));
      b.append(meta, action);
      return b;
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
      if (!data || data.error) { paintOnline(); return; }
      if (data.search) {
        el("music-heading").textContent = "Search";
        body.append(node("h3", "In your lists", "music-name"));
        const found = data.search.rows.length;
        body.append(node("small", found ? `${found}${data.search.more ? "+" : ""} song${found === 1 ? "" : "s"} in your cached lists` :
          `No cached song matches “${data.search.query}”.`, "music-note"));
        if (!found) body.append(node("p", "Only songs in playlists 汽水 has cached on your laptop can be found here.", "music-partial"));
        for (const row of data.search.rows) {
          const b = trackButton(row, `${row.artist} · ${row.listTitle}`);
          b.onclick = () => play(row.list, row.snapshot, row.id); body.append(b);
        }
        if (data.search.more) body.append(node("p", "Showing the first 50. Add a word to narrow it down.", "music-partial"));
        paintOnline(); return;
      }
      paintOnline();
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
          const b = trackButton(row, row.artist);
          b.onclick = () => play(list.id, page.snapshot, row.id); body.append(b);
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
      if (query && !value.search && !value.error) return; // the search box changed again
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
      el("music-search").hidden = !s.musicSearch || !!selected;
      el("music-search").disabled = s.connection !== "connected";
      el("music-search").placeholder = s.musicOnline ? "Search your lists and 汽水" : "Search your cached songs";
      el("music-search").setAttribute("aria-label", el("music-search").placeholder);
      el("music-modes").hidden = !s.musicOnline;
      el("music-modes").disabled = s.connection !== "connected";
      if (open) for (const b of el("music-body").querySelectorAll(".music-track")) {
        const row = rowOf.get(b);
        b.disabled = !row?.playable || s.pending || s.control !== "mine" || s.connection !== "connected";
      }
    }
    el("music-btn").onclick = show; el("music-close").onclick = close;
    el("music-back").onclick = () => { clearTimeout(searchTimer); query = ""; el("music-search").value = ""; busy = false; load(); };
    el("music-refresh").onclick = () => query ? search(query, true) : load(selected);
    el("music-modes").onclick = () => {
      if (!open || !state().musicOnline) return;
      clearTimeout(searchTimer); query = ""; el("music-search").value = "";
      modeView = true; selected = null; data = null; busy = false; ++request;
      el("music-back").hidden = false; el("music-heading").textContent = "Listening modes";
      el("music-status").textContent = ""; el("music-body").replaceChildren(); loadOnline("modes");
    };
    el("music-search").addEventListener("input", e => {
      clearTimeout(searchTimer);
      const value = e.target.value;
      // Fence old replies immediately, including the gap before debounce fires.
      ++request; ++onlineRequest; busy = false; data = null; onlineData = null; onlineBusy = false;
      el("music-body").replaceChildren();
      el("music-status").textContent = "Waiting for you to finish typing…";
      searchTimer = setTimeout(() => search(value, true), 600);
    });
    el("music-search").addEventListener("keydown", e => {
      if (e.key === "Enter") { e.preventDefault(); clearTimeout(searchTimer); search(e.target.value); }
    });
    el("music-backdrop").onclick = e => { if (e.target === el("music-backdrop")) close(); };
    el("music-backdrop").addEventListener("keydown", e => {
      if (e.key === "Escape") { e.preventDefault(); close(); }
      if (e.key === "Tab") {
        const focusable = Array.from(el("music-backdrop").querySelectorAll("button:not([disabled]),select:not([disabled]),input:not([disabled])")).filter(e => !e.hidden);
        const first = focusable[0], last = focusable.at(-1);
        if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last?.focus(); }
        else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first?.focus(); }
      }
    });
    return { receive, receiveOnline, update };
  }
  return { clean, cleanOnline, note, create };
})();
