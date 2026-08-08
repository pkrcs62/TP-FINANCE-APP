/**
 * FinSphere PWA — Service Worker
 * ---------------------------------
 * Strategy:
 *  - App shell (this HTML page, manifest, icons, the CDN libraries the
 *    app depends on) is cached on install so the app opens instantly
 *    and still launches with no signal.
 *  - Live data calls to the Apps Script Web App (script.google.com)
 *    are ALWAYS network-first and NEVER cached — this is a live ledger,
 *    stale financial figures must never be served silently.
 *  - Everything else falls back to cache-first, network-fallback.
 */

const CACHE_VERSION = 'finsphere-v8';
const APP_SHELL = [
  './',
  './index.html',
  './config.js',
  './manifest.webmanifest',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon-maskable-512.png',
  './icons/apple-touch-icon.png',
  'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js',
  'https://cdnjs.cloudflare.com/ajax/libs/jspdf-autotable/3.8.2/jspdf.plugin.autotable.min.js',
  'https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js',
  'https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) =>
      cache.addAll(APP_SHELL).catch((err) => {
        // Don't fail install if a CDN asset is briefly unreachable —
        // the app still needs to become installable.
        console.warn('SW: some app-shell assets failed to precache', err);
      })
    )
    // NOTE: no self.skipWaiting() here on purpose. A newly installed
    // worker stays in "waiting" state until the page explicitly asks
    // it to take over (see the SKIP_WAITING message below) — this is
    // what lets index.html show an "Update available" banner instead
    // of silently swapping the app out from under the user mid-use.
  );
});

// Lets the page (after the user taps "Update") tell this waiting
// worker to activate immediately instead of waiting for all tabs
// of the old version to close.
self.addEventListener('message', (event) => {
  if (event.data === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys.filter((k) => k !== CACHE_VERSION).map((k) => caches.delete(k))
      )
    ).then(() => self.clients.claim())
  );
});

function isLiveDataRequest(url) {
  // Google Apps Script Web App endpoints — always live, never cached.
  return url.hostname === 'script.google.com' || url.hostname === 'script.googleusercontent.com';
}

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return; // POST (all data mutations) always goes straight to network

  const url = new URL(req.url);

  if (isLiveDataRequest(url)) {
    event.respondWith(fetch(req).catch(() => new Response(
      JSON.stringify({ error: 'Database not connected. Please check the Apps Script Web App URL, then try again.' }),
      { headers: { 'Content-Type': 'application/json' } }
    )));
    return;
  }

  event.respondWith(
    caches.match(req).then((cached) => {
      if (cached) return cached;
      return fetch(req).then((res) => {
        // Cache same-origin and known CDN assets for next time.
        if (res.ok && (url.origin === self.location.origin || APP_SHELL.includes(req.url))) {
          const clone = res.clone();
          caches.open(CACHE_VERSION).then((cache) => cache.put(req, clone));
        }
        return res;
      }).catch(() => cached);
    })
  );
});
