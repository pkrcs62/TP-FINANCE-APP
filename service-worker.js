/**
 * FinSphere PWA — Service Worker
 * ---------------------------------
 * Network-first for app shell so new builds appear without manual cache deletion.
 */

const CACHE_VERSION = 'finsphere-v1-53-0';
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

const APP_SHELL_URLS = new Set(APP_SHELL.map((u) => new URL(u, self.location.href).href));

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) =>
      cache.addAll(APP_SHELL).catch((err) => {
        console.warn('SW: some app-shell assets failed to precache', err);
      })
    ).then(() => self.skipWaiting())
  );
});

self.addEventListener('message', (event) => {
  if (event.data === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys.filter((k) => k.startsWith('finsphere-') && k !== CACHE_VERSION).map((k) => caches.delete(k))
      )
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  // The version manifest must NEVER be served from an old cache.
  // It is what lets old installed builds detect a newer deployment before login.
  if (url.pathname.endsWith('/version.json')) {
    event.respondWith(fetch(req, { cache: 'no-store' }));
    return;
  }

  event.respondWith((async () => {
    try {
      const res = await fetch(req);
      if (res && res.ok && (url.origin === self.location.origin || APP_SHELL_URLS.has(url.href))) {
        const cache = await caches.open(CACHE_VERSION);
        cache.put(req, res.clone()).catch(() => {});
      }
      return res;
    } catch (err) {
      const cached = await caches.match(req);
      if (cached) return cached;
      if (req.mode === 'navigate') {
        const fallback = await caches.match('./index.html');
        if (fallback) return fallback;
      }
      throw err;
    }
  })());
});
