# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Arabic-speaking people in Jordan following court-ordered public auctions
(المزادات العلنية) published by the Ministry of Justice — land, apartments,
vehicles, trademarks and other seized assets sold under the execution law.

Today the site is gated by a three-person client-side login (`3bweh`, `fees`,
`Sarta`) and the README still describes it as "for internal use". **That is
superseded:** the confirmed intent is to open it to the public, so future work
should assume a visitor who has never seen it before, not three people who
already know the data. The shared-favourites star was built for the three-person
case and predates that decision.

Typical situation: checking before a deadline, often on a phone, reading
right-to-left, deciding whether a specific lot is worth pursuing.

## Product Purpose

Re-present the public MoJ e-auctions listing in a form that is faster to work
through than the official site, and keep the history the official site discards.

Four confirmed jobs, all of them real:

1. **Spot undervalued lots** — find lots priced well below the expert estimate
   before others do.
2. **Never miss a deadline** — know with certainty when a tracked lot closes.
3. **Browse faster than MoJ** — filters, search, sorting, images and reports in
   one place.
4. **Keep a record over time** — the archive and how lots change across
   re-announcements, not only what is live today.

Success is a user acting on a lot they would otherwise have missed or
mispriced.

## Positioning

MoJ publishes only what is listed right now, one category at a time, with no
search and no per-lot link. This project holds what the source throws away and
derives signals the source never exposes:

- a **4,806-row archive** including expired lots, against the 2,343 MoJ
  currently lists;
- the **announcement round number** (`CurrentAnnouncementSerial`), a hidden
  field on MoJ's own page that reveals how many times a lot has failed to sell;
- **per-lot permalinks** (`AuctionInfo.aspx?token=…`) recovered from an ASP.NET
  postback MoJ never renders as a link;
- **pre-fetched expert-report PDFs** (content-hashed so one case's report is not
  mis-attributed to another lot), cached images, and parcel polygons.

A neighbouring product could copy the listing. It could not copy the history, or
the derived signals, without having been scraping for months.

## Operating Context

**Source.** `auctions.moj.gov.jo` — ASP.NET WebForms. No public API. Pagination
is sequential `lbNext` postbacks only, so page N is unreachable without walking
pages 1..N-1. There is no GET search; the only per-lot address is an encrypted
token harvested from a postback response.

**Pipeline.** GitHub Actions Windows runner → `overnight_run.ps1` → scrape,
enrich (images, reports, parcel polygons, permalinks), rebuild `summary.json`,
commit, publish via GitHub Pages.

**Legal frame.** Jordanian Execution Law No. 25/2007, articles 84–97: the first
30-day announcement, الإحالة المؤقتة, the 15-day second announcement, the
"فرق شاسع" re-offer when the bid falls 25% or more below the estimate, الإحالة
القطعية, the Article 88 ten-day increase window, and Article 97/b re-auction
when a winner defaults. Measured across the archive, the opening price is
**exactly 50% of the expert estimate in ~93% of lots** — the legal floor — so a
low opening price is not itself a bargain signal.

**Anti-bot.** MoJ blocks GitHub's runner IPs far more aggressively than
residential ones; blocked runs return captchas or silently accept the TCP
connection and never respond. Measured 2026-10-05 from a local IP: 131
consecutive requests succeeded, walking the entire 1,305-lot land listing in
9.8 minutes.

**MoJ behaviour to account for.** A bid in the final four minutes resets the
countdown to four minutes, so a stated end time is not a real end time.

## Capabilities and Constraints

- Arabic, right-to-left throughout.
- Static site on GitHub Pages: every file is publicly readable, including
  `auctions.json` and every report PDF. There is no server and no private tier.
- **Bidder identities are not obtainable.** Verified three ways: absent from all
  76 element ids and the full page text, and absent from every method in MoJ's
  SignalR hub contract, which carries only auction id plus amount/date/status.
  The page publishes a bid *count* and nothing more.
- No post-sale hammer price; closed results live in the title registry, a
  different system.
- No bidding from the dashboard — placing a bid requires an authenticated MoJ
  session.
- **Operational rule: nothing may hit `auctions.moj.gov.jo` between 11:00 and
  17:00 Amman time**, from cron or locally. Close-time bid tracking in that
  window is manual only.
- **Access model is explicitly undecided.** The current SHA-256 team gate
  identifies who starred what; it is not access control, and the shared-store
  URL sits in client-side code. A real registration model was started and
  reverted. Do not design as though either outcome is settled.

## Brand Commitments

- Name as shipped: **لوحة المزادات — وزارة العدل الأردنية**.
- Must state it is **not affiliated with the Jordan Ministry of Justice**, and
  must link the official MoJ record from every auction so a user can verify
  against the source.
- Re-presents public data only. No private data is collected or surfaced.

## Evidence on Hand

Real, in-repo, and usable:

- `auctions.json` — 4,806 lots, 4,806 distinct ids, 329 currently live.
- `reports/` — 1,640 expert-report PDFs (2,401 rows carry a report URL).
- `images/` — 4,242 auction photographs.
- 1,468 lots with aradi.io parcel polygons; 280 with harvested per-lot
  permalinks.
- `summary.json` — the few-KB digest the landing page reads instead of the
  multi-MB dataset.

Absent, and not to be invented: no testimonials, no customers, no usage or
traffic figures, no pricing, no benchmarks, no partnership or endorsement of any
kind from the Ministry.

## Product Principles

1. **Public data, honestly re-presented.** Never imply affiliation; always link
   the official record.
2. **The archive is the product.** What MoJ discards — history, re-announcement
   rounds, change over time — is the part that cannot be copied.
3. **Signals over listings.** Surface what makes a lot worth attention: round
   number, bid count, price against estimate. The listing alone is the source's
   job.
4. **Deadlines are load-bearing.** A missed close is a total failure for the
   user, and a stated end time can move by four minutes at a time.
5. **Never overstate what is known.** Bid counts are not bidders; a low opening
   price is the legal floor, not a discount; the login identifies, it does not
   protect.

## Accessibility & Inclusion

- Arabic RTL is the primary and only interface language; numerals, dates and
  countdowns must read correctly in RTL.
- Mobile is a first-class case, not a fallback — users check deadlines on a
  phone. Bottom tab bar, single-column layouts and safe-area handling are
  already shipped.
- No formal standard has been set as a requirement.
