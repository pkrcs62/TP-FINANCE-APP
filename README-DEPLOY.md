# FinSphere v1.34 — Supabase Deployment Guide

This version replaces the Google Sheets/Apps Script backend with a real
Postgres database on Supabase and adds separate Investor Mode / Borrower Mode dashboards. This guide covers the full path:
create the database → load the schema → connect the app → host it →
share the link.

You (the admin) do all of Part 1 and Part 2 once. Nobody else touches
Supabase directly — everyone else just opens the hosted link.

---

## ⚠️ Upgrading an existing V28 (or earlier) database to V29

V29 adds an optional email field to investor and borrower profiles. If
your Supabase project already has data in it, do NOT re-run the whole
`01_schema_and_functions.sql` file — `create table` will fail because the
tables already exist. Instead, open **SQL Editor → New query** and run
just this once:

```sql
alter table investors add column if not exists email text default '';
alter table borrowers add column if not exists email text default '';
```

Then open a second query and paste in just the four function blocks from
`01_schema_and_functions.sql` named `add_investor`, `edit_investor`,
`add_borrower`, and `edit_borrower` (search the file for `create or
replace function add_investor` etc.) and run that. These are safe to
re-run any number of times.

Brand-new projects can skip this section — just follow Part 1 and Part 2
below as normal; the email column is already included there.

---

## Part 1 — Create the Supabase project (one-time)

1. Go to **https://supabase.com** and sign up / log in (GitHub or email).
2. Click **New project**.
   - **Name**: anything, e.g. `finsphere`
   - **Database password**: generate/set one and **save it somewhere safe**
     (a password manager) — you may need it later for direct DB access,
     though the app itself won't need it.
   - **Region**: pick the one closest to where most users are (e.g. an
     `ap-south-1`/Mumbai-area region if most users are in India) — this
     affects latency, not correctness.
3. Wait ~2 minutes for the project to finish provisioning.

## Part 2 — Load the database schema (one-time)

1. In your new project, open the left sidebar → **SQL Editor**.
2. Click **New query**.
3. Open `01_schema_and_functions.sql` (included in this folder) in a text
   editor, copy its **entire contents**, and paste into the SQL Editor.
4. Click **Run** (or press Ctrl/Cmd+Enter).
5. You should see "Success. No rows returned." If you see an error,
   stop and check — do not proceed with a partially-created schema.
6. Confirm the tables exist: left sidebar → **Table Editor** — you should
   see `investors`, `accounts`, `transactions`, `borrowers`, `audit_log`,
   `counters`.

This one file creates every table, every security policy, and every
piece of business logic (interest calculation, recalculation on edit,
receipt numbering, as-of-date reporting) — ported exactly from your
previous Apps Script backend.

## Part 3 — Get your connection details (one-time)

1. Left sidebar → **Project Settings** (gear icon) → **API**.
2. Copy two values:
   - **Project URL** — looks like `https://abcdefghij.supabase.co`
   - **anon public** key — a long string starting with `eyJ...`
     (this is the one under "Project API keys", NOT the `service_role`
     key — never put the service_role key in a frontend file, it
     bypasses all security rules)
3. Open **`config.js`** in this folder in any text editor:
   ```js
   const SUPABASE_URL = 'PASTE_YOUR_SUPABASE_PROJECT_URL_HERE';
   const SUPABASE_ANON_KEY = 'PASTE_YOUR_SUPABASE_ANON_PUBLIC_KEY_HERE';
   ```
   Replace both placeholder strings with the values you copied. Save.

Both values are safe to ship inside the app's files — the anon key
only grants what the security policies in the SQL file allow (in this
build: anyone holding it can read/write, matching your old "Anyone
with the link" Apps Script setup — see the note in Part 6).

## Part 4 — Host the app

Same as before — this app is still a static folder, hosting doesn't
change.

### Option A — GitHub Pages (recommended, free, easiest)

1. Create a free GitHub account if you don't have one.
2. Create a new repository (e.g. `finsphere-app`), public.
3. Upload the contents of this folder to the repo root (not the
   enclosing folder itself), keeping the structure:
   - `index.html`
   - `config.js` (with your Supabase URL/key filled in)
   - `manifest.webmanifest`
   - `service-worker.js`
   - `icons/` (the whole folder)
   - `01_schema_and_functions.sql` (optional to include — reference only,
     the app doesn't load this file)
4. Repo **Settings → Pages** → Source: "Deploy from a branch" → Branch:
   `main` / folder: `/ (root)` → Save.
5. Wait ~1 minute. Your app is live at:
   `https://<your-username>.github.io/finsphere-app/`

### Option B — Netlify (drag-and-drop)

1. Go to **https://app.netlify.com/drop**
2. Drag this whole folder onto the page.
3. Netlify gives you an instant HTTPS URL.

## Part 5 — Verify it works

1. Open your hosted link.
2. It should connect within a second or two (no more multi-second
   "cold start" delay — that was specific to Apps Script and doesn't
   apply to Supabase).
3. Add a test investor, add a test investment, confirm it appears.
4. In Supabase → **Table Editor** → `investors`, confirm the row is
   really there.
5. Open the same link on a different device/network (or ask someone
   else to) and confirm they see the same data.

## Part 6 — Login and access model (read this once)

The app now shows a login screen every time it's opened. ADMIN can choose Investor Mode or Borrower Mode after sign-in; USER goes straight to Borrower Mode:

| Login ID | Password | Access |
|---|---|---|
| `ADMIN` | `1234` | Signs in first, then chooses Investor Mode or Borrower Mode |
| `USER` | `1234` | Borrower Mode only (borrowers dashboard and borrower profiles) |

**Important — read this before relying on it:** this login is a
convenience gate, not real security. The ID/password live in plain
text inside `index.html`'s JavaScript, which is public — anyone can
view-source the page and read them, or open the browser console and
bypass the check entirely. It's there to keep casual/non-technical
users from wandering into the wrong module, not to keep out someone
who intends to get around it.

Underneath the login, this build still uses the simplest database
access model: **anyone who has the app's hosted link and the Supabase
anon key baked into `config.js` can read and write all data at the
database level**, regardless of which login ID they used in the app.
There is no per-user database permission difference between ADMIN and
USER — the restriction is enforced only in the app's UI/JS layer.

If you ever need real security (only specific people can access the
data at all, stronger separation between admin and user, or an audit
trail of who did what), that requires Supabase Auth with real
accounts and rewritten Row Level Security policies — a separate,
larger change from what's here.

To change the login ID/password later: open `index.html`, search for
`LOGIN_ACCOUNTS`, and edit the values there. Re-host the file as usual
(Part 4) for the change to take effect.


---

## How updates reach everyone (one link, forever)

You host once → everyone gets **one permanent HTTPS link**, installs
the PWA from it once. After that:

**Frontend changes** (UI, features, bug fixes):
- Re-upload the changed files to the same host/repo. The URL doesn't
  change.
- **Every push, bump the version** in two places so the browser
  actually notices the change:
  - `service-worker.js` → `CACHE_VERSION` (e.g. `'finsphere-v20'` → `'finsphere-v21'`)
  - `index.html` → `const APP_VERSION = 'V26';` (also update the two
    other `V26` spots: the `<title>` tag near the top, and the
    `version-badge`/`foot-version` spans)
- The app can still show a full-screen "Update Now" screen when a new
  service worker is waiting, but the normal load path should now fetch
  the latest shell automatically without manual cache clearing.

**Backend changes** (schema or business logic):
- Write the new/changed SQL and run it in the Supabase **SQL Editor**.
  `create or replace function ...` is safe to re-run — it replaces the
  function in place without needing a new deployment or a new URL
  (unlike Apps Script, there's no "redeploy" step and no URL to update
  — the Project URL never changes).
- For a new table or column: write an `alter table ...` / `create
  table ...` statement and run it. Existing rows aren't affected by
  additive changes.
- If a function signature changes in a way the frontend calls
  differently, update the matching call in `index.html`'s `RPC_MAP`/
  `callRpc` section to match, then redeploy the frontend as above.

---

## Notes / limitations

- The service worker still caches the app shell and CDN libraries
  (jsPDF, SheetJS, html2canvas, and now also the Supabase JS client)
  so the UI loads offline. It does **not** cache your investor/ledger
  data — that always requires a live connection to Supabase.
- Keep `index.html`, `config.js`, `manifest.webmanifest`,
  `service-worker.js`, and `icons/` all in the same directory.
- iOS Safari doesn't support Chrome's install prompt, but
  `apple-touch-icon` and related tags mean people can still "Add to
  Home Screen" from Safari's Share menu.
- **Never commit or share your Supabase `service_role` key.** Only the
  `anon` public key belongs in `config.js` or anywhere in this app.

---

## v1.58 Amendment Batch (deploy notes)

This release adds a new migration file, **`03_amendments_v2.sql`**, on
top of `01_schema_and_functions.sql` and `02_recurring_investment.sql`.
Run it once, after the two existing files, in the Supabase SQL Editor.
It is written to be safe to re-run (every `CREATE TABLE`/`CREATE
POLICY`/`CREATE OR REPLACE FUNCTION` guards against already existing).

**What it adds, in plain terms:**

1. **Loan Closure** (replaces "Full Settlement" as the primary closing
   action). Admin can now collect only part of an outstanding late fine
   and/or pre-closure penalty — whatever isn't collected is waived
   automatically (the waived amount is always computed by the system,
   never typed in directly). Every rupee's destination — business pool,
   profit pool, who it's credited to — is shown in a bordered
   plain-language breakdown, and is now also permanently recorded in a
   new `loan_closure_breakdown` table for later reference.

2. **Bahi No.** — Admin can assign a register-book number to a loan at
   creation or at agent-request approval time (never visible to Field
   Agents). The system builds the Loan No. from it: `E-<n>` for EMI,
   `B-<n>` for Bullet, `O-<n>` for Overdraft. Each number can only ever
   be used once per loan type, even if that loan is later deleted —
   tracked permanently in the new `bahi_no_registry` table. Admin can
   correct a wrongly-entered Bahi No. later from the loan's profile
   screen.

3. **Borrower Credit Rating** — a 0–10 whole-number score for EMI and
   Overdraft loans (Bullet loans don't contribute, for now). Each
   installment/cycle scores 10 if paid on or before its due date, loses
   1 point per day late (down to a floor of 0), and scores 0 while
   still unpaid. A loan's rating is the average of its own periods; a
   borrower's rating is the average across every EMI/OD loan they've
   ever had. Visible on the borrower's profile, with a full month-wise
   breakdown available from a button on the Loan Details screen.

4. **Overdraft due-date fix** — Overdraft interest cycles were closing
   on the 19th of each month instead of the intended 20th. This is now
   corrected at the function level, and the migration also re-dates any
   not-yet-fully-paid existing cycles that were computed under the old,
   incorrect logic.

5. **Sanction Date** — a new date, separate from Disbursement Date,
   captured once per loan. When a Field Agent submits a loan request,
   they record an "Application Form Collected Date" instead; that date
   becomes the loan's official Sanction Date automatically the moment
   admin approves the request (admin can still adjust it before saving).

6. **"Loan Details" Excel report** — a new report type in the Reports
   menu. One row per loan (Borrower details, Bahi No., Principal, ROI,
   Sanction/Disbursement Dates, ten EMI/Interest columns depending on
   loan type, Profit Share, Total Amount, Status, and outstanding
   Fine/Penalty), exportable as both `.xls` and `.xlsx`, with borders on
   every cell and a bold, frozen header row.

7. **Loan Details screen cleanup** — "Ledger" and "Statement" are now
   one button. "Edit ROI" and "Profit Share" are replaced by a single
   "Edit Loan Details" action covering every editable field; changing
   the principal, ROI, or tenure on an existing loan now automatically
   recalculates its entire EMI schedule, fines, and credit rating to
   match — with a confirmation warning shown before saving. "Loan
   Closure" and "Delete" are now visually separated from the everyday
   actions.

8. **Dashboard cleanup** — the "Missing Profit Share" and "Total Late
   Fine" tiles are gone; a new tile shows Active Borrowers / Active
   Loans counts at a glance.

9. **Borrowers & Loans screens** — both now use a "choose your filters,
   then press Submit" flow instead of showing everything by default.
   Loans can be filtered either by Loan Type first or by Village first
   (a toggle switches between the two). The old always-visible "Due
   Today & Overdue" card on the Loans screen is no longer shown by
   default.

**After running the SQL migration**, deploy the updated `index.html`
exactly as described in the frontend deployment steps above. The
service worker's cache version has been bumped (`finsphere-v1-58`), so
existing installs will automatically pick up the new version the next
time they're opened — no manual cache-clearing needed on any device.
