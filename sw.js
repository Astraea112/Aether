/* Tidal Echo — service worker (offline shell + Web Push).
   IMPORTANT: bump CACHE on every front-end change, or installed clients keep the
   old shell (the precached index.html won't refresh until the SW reinstalls). */
const AI_NAME = "Orion";           // push-title fallback; keep in sync with index.html CONFIG.AI_NAME
const CACHE = "companion-v83-laudanum";
const PRECACHE = [
  "./index.html",
  "./chat-light.webp", "./chat-lily.webp",
  "./menu-light.webp", "./menu-flower.webp", "./menu-harbor.webp", "./chat-harbor.webp",
  "./ribbon-drift.svg", "./ribbon-bow.svg", "./ribbon-line.svg",
  "./avatar-sea.png", "./avatar-lily.webp",
  "./letter-mailbox.webp", "./letter-envelope.webp", "./letter-paper.webp", "./letter-pen.webp",
  "./laudanum-ewer.webp", "./laudanum-cup.webp", "./laudanum-cup-clear.webp", "./laudanum-paper.jpg",
  "./laudanum-stain-1.webp", "./laudanum-stain-2.webp", "./laudanum-stain-3.webp", "./laudanum-stain-4.webp",
];

// Two caches: the shell (index.html, versioned with CACHE) and the images (ASSETS, kept across
// versions so an update doesn't re-download ~1.5 MB of pictures over a slow link).
const ASSETS = "companion-assets-v1";

self.addEventListener("install", (e) => {
  e.waitUntil((async () => {
    // The page itself must make it into the new cache, or this version doesn't install and the
    // old one keeps serving (no skipWaiting on failure -> never left with an empty cache).
    const shell = await caches.open(CACHE);
    const res = await fetch("./index.html", { cache: "no-cache" });
    if (!res || !res.ok) throw new Error("shell " + (res && res.status));
    await shell.put("./index.html", res);
    // Pictures: best effort, only the ones not cached yet.
    const assets = await caches.open(ASSETS);
    await Promise.all(PRECACHE.filter((u) => u !== "./index.html").map(async (u) => {
      if (await assets.match(u)) return;
      try { const r = await fetch(u); if (r && r.ok) await assets.put(u, r); } catch (_) {}
    }));
    await self.skipWaiting();
  })());
});
self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((ks) => Promise.all(ks.filter((k) => k !== CACHE && k !== ASSETS).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// Fetch the latest page without passing the navigate Request (iOS throws on
// fetch(navigateRequest, init)); give up after 8s so a dead network can't hang the open.
function freshShell(){
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 8000);
  return fetch("./index.html", { cache: "no-cache", credentials: "same-origin", signal: ctrl.signal })
    .then(async (res) => {
      clearTimeout(t);
      if (res && res.ok){ const c = await caches.open(CACHE); await c.put("./index.html", res.clone()); }
      return res;
    }, (err) => { clearTimeout(t); throw err; });
}

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (url.pathname.startsWith("/relay/")) return;          // never intercept the API / SSE
  if (e.request.mode === "navigate") {
    // stale-while-revalidate: open instantly from whatever copy of the page we have,
    // refresh it in the background (shows up next open). No copy at all -> network.
    const fresh = freshShell();
    e.respondWith(
      caches.match("./index.html").then((hit) => hit || fresh).catch(() => fresh)
        .catch(() => new Response("<meta charset=utf-8><p style='font:16px sans-serif;padding:24px'>网络不太好，页面没加载出来。关掉再打开一次试试。</p>",
          { headers: { "Content-Type": "text/html; charset=utf-8" } }))
    );
    e.waitUntil(fresh.catch(() => {}));
    return;
  }
  if (e.request.method === "GET" && url.origin === location.origin) {
    e.respondWith(
      caches.match(e.request).then((r) => {
        if (r) return r;
        return fetch(e.request).then((res) => {
          if (res && res.ok && /\.(webp|png|svg|jpg|mp3)$/.test(url.pathname)){
            const copy = res.clone(); caches.open(ASSETS).then((c) => c.put(e.request, copy));
          }
          return res;
        });
      })
    );
  }
});

// ── Web Push (VAPID) ──────────────────────────────
// The relay sends a push when the AI replies and no PWA tab is holding the stream;
// here we surface it on the lock screen.
self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; }
  catch (_) { d = { body: (e.data && e.data.text && e.data.text()) || "" }; }
  const title = d.title || AI_NAME;                        // backend sends RELAY_AI_NAME as title
  const body  = d.body  || "你有一条新消息";
  const tag   = d.id ? ("companion-" + d.id) : "companion-msg";
  e.waitUntil(
    self.registration.showNotification(title, {
      body,
      tag,
      renotify: true,
      icon:  "./icon-192.png",
      badge: "./icon-192.png",
      vibrate: [80, 40, 80],
      data: { url: d.url || "./" },
    })
  );
});

self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const target = (e.notification.data && e.notification.data.url) || "./";
  e.waitUntil(
    // matchAll only returns clients this SW controls (our own scope), so focus the first one.
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((cls) => {
      for (const c of cls) {
        if ("focus" in c){ c.postMessage({ type: "backfill" }); return c.focus(); }
      }
      return self.clients.openWindow ? self.clients.openWindow(target) : null;
    })
  );
});
