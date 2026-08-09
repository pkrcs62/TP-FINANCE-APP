# FinSphere — PWA Deployment Guide

Your app is now a proper installable PWA:
- `manifest.webmanifest` — app name, icons, theme color
- `service-worker.js` — caches the app shell so it opens instantly and
  still launches with no signal (live ledger data always goes to the
  network, never cached, so figures are never stale)
- `icons/` — 192px, 512px, maskable, and iOS touch icon
- `index.html` — your app, with the manifest/service-worker wired in
  and an in-app "Install App" button (automatic connection)

**Chrome only offers "Install" when the site is served over HTTPS** (or
localhost). Opening the HTML file directly (`file://`) will NOT trigger
installability — you must host it. Below are free options, easiest first.

---

## Option A — GitHub Pages (recommended, free, easiest)

1. Create a free GitHub account if you don't have one.
2. Create a new repository (e.g. `finsphere-app`), public.
3. Upload these 4 items to the repo root, keeping the folder structure:
   - `index.html`
   - `manifest.webmanifest`
   - `service-worker.js`
   - `icons/` (the whole folder, all 4 PNGs)
4. Go to repo **Settings → Pages** → Source: "Deploy from a branch" →
   Branch: `main` / folder: `/ (root)` → Save.
5. Wait ~1 minute. Your app will be live at:
   `https://<your-username>.github.io/finsphere-app/`
6. Open that URL in Chrome (desktop or Android) — you'll see an install
   icon in the address bar, or use the in-app "Install App" button
   from the home screen.

## Option B — Netlify (drag-and-drop, free, also very easy)

1. Go to https://app.netlify.com/drop
2. Drag the whole `finsphere` folder (containing index.html, manifest,
   service-worker.js, icons/) onto the page.
3. Netlify gives you an instant HTTPS URL — done, no account required
   for the first deploy (create a free account to keep it permanently).

## Option C — Firebase Hosting (free, more control, custom domain support)

1. Install Node.js, then: `npm install -g firebase-tools`
2. `firebase login`
3. `firebase init hosting` (choose this folder as the public directory)
4. `firebase deploy`

---

## How updates reach your friend (one link, forever)

You host once → your friend gets **one permanent HTTPS link** and
installs the PWA from it a single time. After that:

**Frontend changes** (UI, features, bug fixes):
- Re-upload the changed files to the same host/repo. The URL doesn't
  change.
- **Every push, bump the version** in two places so the browser
  actually notices the change (identical file bytes are otherwise
  invisible to it):
  - `service-worker.js` → `CACHE_VERSION` (e.g. `'finsphere-v6'` → `'finsphere-v7'`)
  - `index.html` → `const APP_VERSION = 'V6';` (shows in the header/title/footer)
- The app checks for a new version as soon as it's opened. If one's
  found, it shows a **full-screen "Update Now" screen that blocks the
  app** — there's no way to skip it or keep using the old version.
  One tap reloads onto the new version. This matters here because
  everyone shares one live database: an old copy of the app could
  silently show stale figures or use a since-changed data format.

**Backend changes** (Apps Script code):
- In the Apps Script editor: **Deploy → Manage deployments → ✏️ (edit
  icon) → New version → Deploy.**
- **Do NOT** use "New deployment" for routine changes — that mints a
  brand new URL, which would break the one baked into `config.js` and
  require re-sharing the file. "Manage deployments → New version"
  keeps the exact same URL while updating the logic behind it.

So your workflow stays simple every time: bump the version → redeploy
under the same URL (backend) / re-upload to the same host (frontend)
→ your friend is required to tap "Update Now" the next time they open
the app before they can do anything else.

## Initial connection to your Google Sheet backend — do this ONCE

You (the admin) do this one time. Your friend/colleague never has to
touch it.

1. Open **Extensions → Apps Script** in your Google Sheet, paste in
   `AppsScript.gs.txt`'s contents.
2. **Deploy → New deployment → Web app** → Execute as: Me, Who has
   access: Anyone with the link.
3. Copy the deployment URL.
4. Open **`config.js`** in this folder in any text editor. Replace
   `PASTE_YOUR_APPS_SCRIPT_WEB_APP_URL_HERE` with the URL you copied,
   between the quotes. Save.
5. Deploy the folder (Option A/B/C above) as usual, or just zip it and
   send the whole folder to your friend.

That's it — anyone who opens the hosted link (or the shared folder)
is automatically connected. Nobody needs to know or type the database
URL; it's baked into the app before it's shared. The automatic connection
still exists on each person's own device if you ever need to point
that one device at a different backend, but it's not required.

**If you redeploy the Apps Script later and get a new URL:** just
edit `config.js` again and re-share/re-host — everyone picks up the
new URL automatically the next time they load the app (as long as
they haven't separately saved an override locally).

## Verifying installability

Open Chrome DevTools → **Application** tab → **Manifest** — it should
show no errors and list all 3 icon sizes. Under **Service Workers**,
you should see `service-worker.js` as "activated and running".

## Notes / limitations

- The service worker caches the app shell and the CDN libraries
  (jsPDF, SheetJS, html2canvas) so the UI loads offline. It does
  **not** cache your investor/ledger data — that always requires a
  live connection to your Apps Script backend, by design, so you're
  never looking at stale financial figures without knowing it.
- If you rename the folder or change file paths, keep `index.html`,
  `manifest.webmanifest`, `service-worker.js`, and `icons/` all in the
  same directory (the manifest and service worker use relative paths).
- iOS Safari does not support Chrome's install prompt UI, but the
  `apple-touch-icon` and `apple-mobile-web-app-capable` tags mean
  users can still "Add to Home Screen" from Safari's Share menu and
  get a full-screen icon-launched app.
