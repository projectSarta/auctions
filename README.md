# MoJ Auctions Dashboard

A web dashboard that scrapes the **Jordan Ministry of Justice e-Auctions site** (`auctions.moj.gov.jo`) and republishes its data with thumbnails, downloadable expert reports, multi-select filters, favorites, calendar export, and live-bid polling.

**Live site:** https://projectsarta.github.io/auctions/
**Source:** https://auctions.moj.gov.jo/index.aspx

The MoJ site is the official listings portal for court-ordered auctions (vehicles, real estate, trademarks, etc.) executed under Jordan's civil-procedure framework. This project does **not** mirror anything private — it only re-presents publicly-listed information in a faster, more filterable UI.

---

## Table of contents

- [What this gives you over the MoJ site](#what-this-gives-you-over-the-moj-site)
- [Architecture at a glance](#architecture-at-a-glance)
- [Daily pipeline](#daily-pipeline)
- [File map](#file-map)
- [Setup from scratch](#setup-from-scratch)
- [Running locally](#running-locally)
- [Key technical findings](#key-technical-findings)
- [Team login (Option C, multi-user)](#team-login-option-c-multi-user)
- [Color & motion system](#color--motion-system)
- [What's NOT possible (and why)](#whats-not-possible-and-why)

---

## What this gives you over the MoJ site

| Feature | MoJ site | This dashboard |
|---|---|---|
| Filter by category | One category at a time (tabs) | Multi-select, plus court / location / vehicle-type / announcement / price range filters all combinable |
| Sort by price / deadline | Server-side only, one column | Click any column header, sorts client-side instantly |
| Free-text search | None | Search across every field |
| Cascading location filter | None | Picking *Amman* governorate auto-narrows directorate → village → basin to only options that exist in that governorate |
| Vehicle make/model filter | None | The `نوع المركبة` column auto-appears when the مركبة category is in scope |
| Favorites | Per-account on MoJ | Shared across the team via a single jsonblob — three of you can star/un-star and see each other's picks in real-time |
| Auction images | Lazy-loaded on scroll, kills the experience for browsing | Inline thumbnails (already enriched and cached locally, 1500+ images at 600 px JPEGs) |
| Expert report PDF | Force-downloads with `Content-Disposition: attachment` (annoying) | Opens inline in a new tab — PDFs are pre-downloaded into `reports/` and served by GitHub Pages |
| Calendar export | None | One click → `.ics` file (Outlook/Apple) or Google/Outlook.com deep link, with 1-day + 1-hour reminders pre-set |
| Live bid updates | SignalR push (works in their UI only) | Optional polling every 25 s via Cloudflare Worker; cell flashes green/red on change |
| Mark a row as "new" | None | Red pulsing dot for auctions added since the previous scrape, plus a 🆕 filter tile |
| "Ending today" tile | None | One-click filter for auctions closing in the next 24 hours |

---

## Architecture at a glance

```
┌─────────────────────────────────────────────────────────────────────┐
│ auctions.moj.gov.jo  (Jordan MoJ, ASP.NET WebForms with ViewState)  │
└───────┬─────────────────────────────────────────────────────────────┘
        │
        │ HTTP (scrape + enrich), every 04:00 + 22:00 Amman
        │
┌───────▼────────────────────────┐
│ GitHub Actions runner (Win)    │
│  .github/workflows/            │
│    daily-scrape.yml            │
│      └─ runs overnight_run.ps1 │
│           ├─ enrich_images     │
│           ├─ enrich_reports    │
│           ├─ scrape (refresh)  │
│           ├─ re-enrich         │
│           ├─ resize_images     │
│           └─ git commit + push │
└────────┬───────────────────────┘
         │
         │ git push
         ▼
┌─────────────────────────────────┐         ┌──────────────────────────────┐
│  GitHub Pages (static host)     │◀────────│  Cloudflare Worker            │
│   • dashboard.html              │  /api/   │   /api/bids?token=…           │
│   • auctions.json + .js         │  CORS    │     polls listing, parses     │
│   • images/<id>.jpg             │          │     bid count + amount        │
│   • reports/<id>.pdf            │          │   /api/auction?id=&token=     │
└─────────────────────────────────┘          │     fetches detail HTML       │
         │                                    └──────────────────────────────┘
         │ browser fetch                              ▲
         ▼                                            │ when "live polling" is on
┌─────────────────────────────────┐                  │
│  Browser (RTL Arabic)           │──────────────────┘
│   Dashboard JS reads auctions.js│
│   Renders table, filters,       │
│   modal, calendar export        │
└─────────────────────────────────┘
```

**Two writes path** for shared state:

- **Static** (deployed by GitHub Actions, refreshed every 12 h): listings, images, reports.
- **Dynamic** (always live):
  - **Shared favorites** → `jsonblob.com/api/jsonBlob/<id>` (team writes through it after login)
  - **Live bids** → Cloudflare Worker polls MoJ for the visible categories every 25 s while the dashboard tab is open

---

## Daily pipeline

`overnight_run.ps1` runs twice daily on `windows-latest` via GitHub Actions and goes through 7 phases:

| Phase | What | ETA |
|---|---|---|
| 1 | `enrich_images.ps1 -ActiveOnly` — POSTs `/AuctionsList.aspx/GetAuctionItemsImage` per auction, decodes base64 to `images/<id>.<ext>` | ~5 min |
| 2 | `enrich_reports.ps1 -ActiveOnly` — `lbtnViewAllImages` postback per auction to scrape the per-lot report-PDF URL, then downloads the PDF to `reports/<id>.pdf` | ~10 min |
| 3 | `scrape.ps1 -Full` — walks every category's paginated listing, parses each row's fields, upserts into `auctions.json`. Stamps `lastSeenInListingAt` on every row visited | ~20 min |
| 4 | Re-runs Phase 1 to enrich any newly-discovered active rows | ~3 min |
| 5 | Re-runs Phase 2 to enrich reports for newly-backfilled caseIds | ~5 min |
| 6 | `resize_images.ps1` — recompresses any image > 80 KB at > 600 px wide down to 600 px JPEG @ q=75 | ~2 min |
| 7 | Stamps `lastRunAt` on the JSON, `git add` everything (incl. `reports/`), commits, pushes to `main` — GitHub Pages auto-deploys | <1 min |

Total: 45–60 minutes per run.

If the scrape phase hits anti-bot during the GitHub Actions run, the rest of the orchestrator still completes — newly-discovered auctions just wait for the next slot.

---

## File map

### Source scripts
| File | Role |
|---|---|
| `scrape.ps1` | Main scraper. Walks every category listing. Parses each row → object with id, header, court, prices, deadline, status, image src, etc. Uses divCountDownVal[2] as the live-countdown deadline source. Anti-bot resilience: UA rotation, jittered delays, periodic session resets, chunked URI encoding (the ViewState now exceeds 65 KB, breaking `[Uri]::EscapeDataString`). |
| `enrich_images.ps1` | Posts to `/AuctionsList.aspx/GetAuctionItemsImage` (JSON web method discovered in `AuctionsListScripts.js`'s `LoadAuctionsImages()`). Saves base64 payloads to `images/<id>.<ext>` after magic-byte sniffing (server lies about MIME — claims PNG but content is often JPEG). |
| `enrich_reports.ps1` | Postbacks `lbtnViewAllImages` (not `lbtnDetails`!) to harvest the per-auction `frmDownloadReports.aspx?token=…` URL. Downloads the PDF locally. The token is stable per-auction, so URLs scraped once remain valid. |
| `resize_images.ps1` | Shrinks anything > 80 KB and > 600 px wide to 600 px JPEG @ q=75. PNG → JPG conversion auto-retags `auction.image` field in JSON. |
| `backfill_caseid.ps1` | Targeted walk of every listing page that extracts `(auctionId, caseId)` pairs from inline `SetAuctionData()` JS calls. Used when older rows are missing caseId. |
| `download_existing_reports.ps1` | Bulk-downloads PDF for every row that has `reportUrl` but no `pdfPath` yet (used after the lbtnDetails → lbtnViewAllImages migration to re-pull). |
| `overnight_run.ps1` | The orchestrator that wires Phases 1-7 together. |
| `overnight_run2.ps1` / `_run3.ps1` / `_slow.ps1` | One-off recovery orchestrators (refresh scrape, deep caseId backfill, captcha-cooldown retry). |
| `serve.ps1` | Local dev HTTP server (port 8123). Serves the static files PLUS `/api/auction`, `/api/bids`, `/api/report` — same routes as the Cloudflare Worker but using `curl --insecure` (so it can hit MoJ's incomplete SSL chain that Workers reject). |
| `probe_*.ps1` / `test_*.ps1` | Diagnostic one-shots used during reverse-engineering of the MoJ endpoints. Safe to delete; kept as references. |

### Output
| File / dir | Role |
|---|---|
| `auctions.json` | Source of truth. ~3 MB. Read by both the dashboard and the scraper (which merges new data into existing). |
| `auctions.js` | `window.AUCTION_DATA = <auctions.json>;` — what the static dashboard loads at startup (avoiding fetch + CORS). Regenerated alongside `auctions.json`. |
| `images/<id>.jpg` | Thumbnails (600 px JPEG @ q=75). ~100 MB total. |
| `reports/<id>.pdf` | Per-auction expert-report PDFs. ~35-100 MB total. |
| `dashboard.html` | The single-file UI (~50 KB). Inline CSS + JS, Bootstrap 5.3 RTL + Leaflet from CDN. |
| `worker.js` | Cloudflare Worker code. Deployed manually via the dashboard editor. |
| `overnight.log` etc | Run logs from the orchestrator (gitignored). |

### Infrastructure
| File | Role |
|---|---|
| `.github/workflows/daily-scrape.yml` | GitHub Actions: cron `0 1,19 * * *` (04:00 + 22:00 Amman), `windows-latest` runner, 90 min timeout. Uploads `overnight.log` as a 7-day artifact. |
| `.gitignore` | Excludes cookie jars, logs, probe HTML files |

---

## Setup from scratch

For a fresh clone on a new machine:

```bash
git clone https://github.com/projectSarta/auctions.git
cd auctions
```

No package install — there's no `npm install` step, no Python venv. Everything is PowerShell + curl.exe (bundled with Windows 10+) + jQuery/Bootstrap from CDN.

To run the dashboard locally with hot-reload of scrapes:
```powershell
./serve.ps1                              # starts http://localhost:8123
# open http://localhost:8123/dashboard.html
```

To force a one-off scrape locally:
```powershell
./scrape.ps1 -Full -Refresh -DelayMs 4500
```

To force a one-off re-enrich:
```powershell
./enrich_images.ps1 -ActiveOnly
./enrich_reports.ps1 -ActiveOnly -Force
./resize_images.ps1
```

To run the whole orchestration manually:
```powershell
./overnight_run.ps1
```

---

## Running locally

When dashboard is opened from `http://localhost:8123` (i.e. `serve.ps1` running), it detects `isLocalhost === true` and routes API calls (`/api/auction`, `/api/bids`, `/api/report`) to itself instead of the Cloudflare Worker. This is important because the Cloudflare Worker **cannot reach** `auctions.moj.gov.jo` due to the origin's incomplete SSL certificate chain — Workers do strict cert validation; Windows curl (with `--insecure`) doesn't.

Opening the GitHub Pages URL → all dashboard reads come from static files; `/api/bids` and `/api/report` route to the Cloudflare Worker (which only sometimes succeeds against MoJ's anti-bot).

Opening `localhost` → static files + live API → everything works.

---

## Key technical findings

A running tally of things that took hours to figure out:

### 1. Images are NOT in the listing HTML — they're an AJAX call
The listing renders `<img id="imgAuctionImage_<id>" src="/Images/noimage.jpg">` placeholders. The real image gets injected at runtime by `LoadAuctionsImages()` in `/JS/AuctionsListScripts.js`, which POSTs JSON to `/AuctionsList.aspx/GetAuctionItemsImage` and gets back a `data:image/...;base64,…` payload. The server **lies about the MIME** — claims PNG but bytes start with `/9j/` (JPEG). Magic-byte sniff after decoding.

### 2. The detail-page report URL flow has TWO postback targets
- `lbtnDetails` returns a **case-level** PDF token — same URL for every auction in the same court case. (Wrong for our use.)
- `lbtnViewAllImages` returns a **per-auction** PDF token — different URL per lot.

We originally used `lbtnDetails` and produced wrong PDFs for the 208 auctions in multi-lot cases. Migrated to `lbtnViewAllImages` and re-downloaded.

### 3. `[Uri]::EscapeDataString` throws on strings > 65,520 chars
Modern ASP.NET ViewState easily exceeds this. The scraper's next-page POST built its form body via that function, which silently threw, the loop caught the exception, re-fetched page 1, looped forever. **This was the actual cause of "0 new auctions for 5 days"** — initially diagnosed (wrongly) as anti-bot blocking. Fix: chunk the encoder in 32 k slices.

### 4. The MoJ origin has an **incomplete SSL chain**
Windows curl auto-fills the missing intermediate from the OS trust store, so it works. Cloudflare Workers do strict validation and return HTTP 526. There's no `--insecure` equivalent on Workers, so:
- `/api/auction` and `/api/bids` only work intermittently from the deployed Worker.
- `serve.ps1` always works for local use because it uses `curl --insecure`.

### 5. `endDate` goes stale on re-announcement
MoJ doesn't always update `AuctionEndDateFormated_<id>` when an auction is re-announced. The **live countdown** uses a different field — the 3rd hidden input in the `divCountDownVal` block, which DOES update. Scraper now reads from there as primary.

Even better: `lastSeenInListingAt` — eager timestamp stamped on every row during scrape. The dashboard's "active" filter = `lastSeenInListingAt within last 48 h`. Survives partial scrapes and naturally self-cleans.

### 6. Auctions in the same court case share a PDF
208 of ~2200 auctions are part of multi-lot cases (75 cases total, biggest has 11 lots). The expert report describes ONE of the lots only. The dashboard now shows a blue info box listing every sibling with its parcel #, basin, and area when you open one of these, so you can identify which lot the PDF actually matches.

### 7. Date parsing pitfall
`[DateTime]::Parse("12/05/2026")` in PowerShell with `en-US` culture returns **December 5**, not May 12. The dashboard uses ISO format (`yyyy-MM-dd HH:mm:ss`) to avoid this. Any PowerShell that parses `dd/MM/yyyy HH:mm:ss` needs `ParseExact`, not `Parse`.

### 8. Bidder identities are confidential by design
The MoJ's public site only exposes `currentAmount` (highest bid) and `numBids` (count). No bidder names, no individual bid amounts, no timestamps. This is by court-policy (privacy protection + collusion prevention) and we don't try to circumvent it.

---

## Team login (Option C, multi-user)

The favorites star feature uses a shared jsonblob.com store gated by a **per-user password**, picked from a hardcoded user list in `dashboard.html`.

```js
const TEAM_USERS = [
  { name: '3bweh', passwordSha256: '…' },
  { name: 'fees',  passwordSha256: '…' },
  { name: 'Sarta', passwordSha256: '…' },
];
const TEAM_BLOB_URL = 'https://jsonblob.com/api/jsonBlob/019e1c8e-…';
```

Login modal asks for password only (no username field). On submit, hash is computed client-side via `crypto.subtle.digest('SHA-256', …)` and matched against the user list to identify which user signed in. The navbar then shows `✓ <name>`.

Every star/un-star pushes the full favorites list (debounced ~700 ms) to the shared blob. Other team members see updates after their next page refresh (or with live polling on).

**Honest security model:** the blob URL is in client-side code, so a technically-savvy outsider could find it. Acceptable for a small private team list. For real auth, swap the storage layer to Firebase — `pullSharedFavorites` and `schedulePushFavorites` are the only two functions that touch the network.

---

## Color & motion system

### Palette (defined as CSS variables in `dashboard.html`)

| Role | Hex | Use |
|---|---|---|
| Primary — Court Navy | `#1B3A57` | Navbar gradient, table headers, primary buttons, stat numbers |
| Accent 1 — Treasury Gold | `#C9A961` | Favorites, fav-only filter, multi-lot case alert |
| Accent 2 — Hammer Red | `#B73E3E` | "Ending today" tile, new-listing dot, bid-flash-down, urgent badges |
| Background — Parchment | `#FAF8F4` | Page background |
| Surface | `#FFFFFF` | Cards, modals, rows |
| Border — Linen | `#E5DFD3` | Soft separators |
| Success — Verdigris | `#3D7A6A` | Live polling ON, bid-flash-up |

Bootstrap CSS variables (`--bs-primary`, `--bs-danger`, etc.) are overridden on `:root` so all of Bootstrap's button/badge/text classes inherit the palette automatically.

### Motion tokens

```css
--motion-fast:    120ms   /* hover tint, focus ring */
--motion-base:    220ms   /* button press, dropdown */
--motion-medium:  360ms   /* card hover, modal backdrop */
--motion-large:   520ms   /* section entrance */
--motion-xl:      720ms   /* first-paint orchestration */

--ease-out-expo:  cubic-bezier(0.16, 1, 0.3, 1)   /* premium entrances */
--ease-out-quart: cubic-bezier(0.25, 1, 0.5, 1)   /* repeat interactions */
--ease-in-quart:  cubic-bezier(0.5, 0, 0.75, 0)   /* exits */
--ease-back-out:  cubic-bezier(0.34, 1.56, 0.64, 1) /* subtle overshoot — selections only */
```

First-paint entrance is orchestrated: navbar → stat cards (staggered 60 ms apart) → filters card → table. Each animation is gated behind `@media (prefers-reduced-motion: no-preference)`; vestibular-disorder users get an instant-state experience.

---

## What's NOT possible (and why)

- **Bidder identities** — not exposed by MoJ at all. Privacy by design. Court-policy protected.
- **Past sale results / final hammer price after the auction ends** — not in the public listing. Would require a separate scrape of closed announcements (post-sale records become public at the title-registry level — دائرة الأراضي / دائرة الترخيص — but that's a different system).
- **Real-time bidding from the dashboard** — placing actual bids requires authenticated session on MoJ. We only DISPLAY bid state; placing a bid still has to go through their UI.
- **Sub-second bid updates from the deployed (Cloudflare) site** — the SSL issue blocks the Worker from polling MoJ reliably. Local (`serve.ps1`) works fine. To get sub-second on production would require a different proxy that allows insecure SSL (e.g. a tiny Render/Fly.io Node app with `rejectUnauthorized: false`).

---

## License & disclaimers

This project re-presents **public data**. No private data is collected, stored, or surfaced. The MoJ source URL is linked from every auction modal so users can verify against the official record.

The dashboard is provided as-is for internal use. Not affiliated with the Jordan Ministry of Justice.
