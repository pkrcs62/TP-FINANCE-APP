// TP Finance service worker
//
// Cache-busting strategy: the cache name itself is tied to the version
// query string the page registers us with (index.html passes
// `./service-worker.js?v=<APP_VERSION>`). Every time APP_VERSION changes
// in index.html, this script's URL changes, the browser treats it as a
// brand-new service worker, install/activate re-run, and the activate
// step below deletes every old-named cache. This means a plain version
// bump + redeploy is enough to force everyone off stale cached files —
// no manual cache-clear, no uninstall/reinstall needed.
//
// Network-first for navigation/HTML so a fresh index.html is always
// preferred when online (falls back to cache only if offline); cache-first
// for static assets to keep the app fast and installable/offline-capable.

const VERSION = new URL(self.location).searchParams.get('v') || 'dev';
const CACHE_NAME = `tp-finance-${VERSION}`;

const PRECACHE_URLS = [
  './',
  './index.html',
  './manifest.webmanifest'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(PRECACHE_URLS))
      .catch(() => { /* non-fatal: precache is best-effort */ })
  );
  // Activate this new worker immediately instead of waiting for all
  // tabs of the old version to close — critical for a version bump to
  // actually take effect promptly on a phone where the app/tab is
  // rarely fully closed.
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(
        names
          .filter((name) => name.startsWith('tp-finance-') && name !== CACHE_NAME)
          .map((name) => caches.delete(name))
      )
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const isNavigation = req.mode === 'navigate' ||
    (req.destination === 'document');

  if (isNavigation) {
    // Network-first: always try to get the latest index.html when
    // online. This is the actual fix for "update pushed but app still
    // shows old version" — previously a cache-first navigation handler
    // could keep serving an old cached page indefinitely.
    event.respondWith(
      fetch(req)
        .then((res) => {
          const resClone = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(req, resClone));
          return res;
        })
        .catch(() => caches.match(req).then((cached) => cached || caches.match('./index.html')))
    );
    return;
  }

  // Static assets: cache-first, fall back to network, and top up the
  // cache with whatever the network returns.
  event.respondWith(
    caches.match(req).then((cached) => {
      if (cached) return cached;
      return fetch(req).then((res) => {
        const resClone = res.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(req, resClone));
        return res;
      });
    }).catch(() => cached)
  );
});
