# Login-gating the site with Cloudflare Access

Goal: nobody sees the listings — or any underlying file — without signing in
first.

## Why the site has to move

The site is static. On GitHub Pages every file is public, and that is not a
setting you can change:

```
https://projectsarta.github.io/auctions/auctions.json   -> 200, 23.6 MB
https://projectsarta.github.io/auctions/reports/*.pdf   -> 200
```

A login screen written in JavaScript cannot fix this. Anyone can open the JSON
URL directly, read the page source, or browse the public GitHub repo. The
existing team login (SHA-256 hashes in `dashboard.html`) is a convenience gate
for *sharing favourites* — it was never access control and must not be
presented as such.

Real gating needs something that can **refuse to serve the bytes**. Cloudflare
Access does that at the edge: an unauthenticated request never reaches the
file.

## What you end up with

| | before | after |
|---|---|---|
| Host | GitHub Pages | Cloudflare Pages |
| URL | `projectsarta.github.io/auctions/` | `<project>.pages.dev` (or your domain) |
| Who can read `auctions.json` | anyone | signed-in users only |
| GitHub repo | public | **private** |
| Sign-in | none | email one-time code (or Google) |
| Auth code to maintain | — | none |

Free for up to 50 users.

---

## Steps

You must do these — they need your Cloudflare and GitHub accounts. You already
have a Cloudflare account (`iyas85.workers.dev`), so no new signup.

### 1. Make the GitHub repo private

`github.com/projectSarta/auctions` → Settings → General → Danger Zone →
Change visibility → Private.

**This takes the current GitHub Pages site offline** — Pages from a private
repo needs a paid GitHub plan. That is intended: it closes the public door.
Do it *after* step 3 if you want zero downtime.

### 2. Create the Pages project

Cloudflare dashboard → Workers & Pages → Create → Pages → Connect to Git →
authorise the repo → select `projectSarta/auctions`.

Build settings — the site is plain static files, there is no build:

- Framework preset: **None**
- Build command: *(leave empty)*
- Build output directory: **`/`**

Deploy. You get `https://<project>.pages.dev`.

> If the Git build struggles, the repo history is ~1.8 GB (images and PDFs are
> committed). The fallback is direct upload from CI with
> `wrangler pages deploy .` — ask and I will wire it into the existing Actions
> workflow, using a `CLOUDFLARE_API_TOKEN` repo secret.

### 3. Turn on Access

Cloudflare dashboard → Zero Trust → Access → Applications → **Add an
application** → **Self-hosted**.

- Application name: `MoJ Auctions`
- Session duration: e.g. 1 week (how often people re-authenticate)
- Public hostname: your `<project>.pages.dev`

Then add a policy:

- Policy name: `Allowed users`
- Action: **Allow**
- Rules — pick whichever fits:
  - *Emails* → list the exact addresses you allow, or
  - *Emails ending in* → `@ingotbrokers.com` to let any colleague in, or
  - *Everyone* + an identity provider, if you genuinely want open registration

Under Settings → Authentication, enable at least **One-time PIN** (emails a
code, no provider setup). Add Google if you want one-click sign-in.

### 4. Verify it actually gates

This is the step that matters — do not skip it:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://<project>.pages.dev/auctions.json
```

You want a redirect to the Access login (`302`), **not** `200`. A `200` with
23 MB of JSON means the policy is not applied to that path.

Also confirm in a private browser window that the site asks you to sign in
before the dashboard renders.

### 5. Tell me the new URL

I will update the repo's internal links and the README.

---

## Notes and gotchas

- **"Register" means you approve.** Access is an allowlist, not open
  self-service signup. Users authenticate (email code / Google) and are let in
  if they match a policy rule. If you want genuinely open registration with
  user records you own, that is the Firebase option instead — a much larger
  change.
- **The 25 MiB per-file limit.** Pages refuses larger assets. One report
  (`52562.pdf`, 50 MB) exceeded it; its `pdfPath` has been cleared and the file
  removed, so the dashboard falls back to the MoJ link for that lot.
  `enrich_reports.ps1` now enforces the same rule on new downloads.
- **The scraper is unaffected.** It keeps pushing to the same repo; Pages
  redeploys on push exactly as GitHub Pages did.
- **The team login can stay.** It still does its original job — identifying who
  you are for shared favourites — now behind the Access gate.
- **Old links break.** Anything pointing at `projectsarta.github.io/auctions`
  stops working once the repo is private. Re-share the `.pages.dev` URL.
