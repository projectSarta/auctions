---
name: MoJ Auctions Dashboard
description: An Arabic right-to-left public register for Jordan's court-ordered auctions — parchment ground, court navy, a gold seal.
colors:
  court-navy: "#1B3A57"
  court-navy-deep: "#0E2438"
  court-navy-soft: "#EEF2F6"
  treasury-gold: "#C9A961"
  treasury-gold-deep: "#A88840"
  treasury-gold-soft: "#FBF6E8"
  hammer-red: "#B73E3E"
  hammer-red-deep: "#962E2E"
  hammer-red-soft: "#FBF2F2"
  seal-green: "#3D7A6A"
  seal-green-soft: "#E6F0EC"
  info-slate: "#4A6B85"
  parchment: "#FAF8F4"
  surface: "#FFFFFF"
  rule: "#E5DFD3"
  ink: "#1A1F2E"
  body-ink: "#3D4859"
  muted-ink: "#7B8499"
  mist-ink: "#B8BEC9"
typography:
  display:
    fontFamily: "'Iowan Old Style', 'Palatino Linotype', Palatino, Cambria, Georgia, serif"
    fontSize: "clamp(2.1rem, 5.5vw, 3.5rem)"
    fontWeight: 600
    lineHeight: 1.12
  title:
    fontFamily: "'Iowan Old Style', 'Palatino Linotype', Palatino, Cambria, Georgia, serif"
    fontSize: "1.25rem"
    fontWeight: 600
  body:
    fontFamily: "'Segoe UI', Tahoma, 'Arabic UI Text', system-ui, -apple-system, sans-serif"
    fontSize: "0.85rem"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "'Segoe UI', Tahoma, 'Arabic UI Text', system-ui, -apple-system, sans-serif"
    fontSize: "0.7rem"
    fontWeight: 600
  numeric:
    fontFamily: "'Iowan Old Style', 'Palatino Linotype', Palatino, Cambria, Georgia, serif"
    fontSize: "0.98rem"
    fontFeature: "tabular-nums"
rounded:
  chip: "999px"
  sm: "4px"
  md: "6px"
  lg: "10px"
  card: "14px"
spacing:
  xs: "4px"
  sm: "7px"
  md: "11px"
  lg: "16px"
  xl: "26px"
components:
  stat-card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.card}"
    padding: "11px"
  pill:
    backgroundColor: "{colors.treasury-gold-soft}"
    textColor: "{colors.treasury-gold-deep}"
    typography: "{typography.label}"
    rounded: "{rounded.chip}"
    padding: "2px 8px"
  hero:
    backgroundColor: "{colors.court-navy}"
    textColor: "{colors.surface}"
    padding: "56px 0 104px"
---

# Design System: MoJ Auctions Dashboard

## Overview

**Creative North Star: "The Court Record"**

This is a public register, not a product. It inherits its authority from the
thing it documents — court-ordered auctions executed under Jordan's execution
law — and its job is to be legible under scrutiny. The scales-of-justice seal,
the serif display face, and the parchment ground all say the same thing: this is
a record you can cite, not a dashboard trying to sell you something.

But it is a *warm* record, not a cold one. The ground is parchment
(`#FAF8F4`), never white-grey; the accent is gold, never corporate blue; the
rules between rows are a soft tan (`#E5DFD3`) rather than a hard grey line. That
warmth is deliberate and load-bearing — it is what keeps a screen of 300 dense
rows from reading as an enterprise data table. Density and warmth are not in
tension here; the warmth is what makes the density bearable.

Precision is the other half. Every number is tabular-lined and set in the serif,
so columns of dinars align down the page and a price can be compared at a glance
without reading it. The interface is dense on purpose: filters on every column,
stat tiles that are themselves filters, and as many lots per screen as legibility
allows. A visitor is here to compare lots and catch a deadline, not to browse.

**Key Characteristics:**
- Parchment ground, never white — warmth is a system invariant
- Serif for display *and* for every number; sans for body and controls
- Gold is a seal, used sparingly; red means a deadline, never decoration
- Flat at rest, lifting only on hover
- Arabic RTL first, and the only language

## Colors

A warm institutional palette: navy for authority, gold for the seal, red
reserved for time running out, all over parchment.

### Primary
- **Court Navy** (`#1B3A57`): the authority colour. Page header, the hero
  gradient on the landing page, table header ground, primary buttons, and the
  focus ring. It carries institutional weight without reading as corporate blue.
- **Court Navy Deep** (`#0E2438`): the far end of the hero gradient and the
  source of every shadow colour — shadows here are navy-tinted, never neutral
  black.
- **Court Navy Soft** (`#EEF2F6`): selected and hovered rows, quiet fills.

### Secondary
- **Treasury Gold** (`#C9A961`): the seal. It draws the scales-of-justice mark,
  marks re-announced lots, and signals a freshness pill going stale. It is never
  a surface fill at full strength.
- **Treasury Gold Deep** (`#A88840`): gold text on a soft gold ground, where the
  base tone would fail contrast.
- **Treasury Gold Soft** (`#FBF6E8`): pill and badge grounds.

### Tertiary
- **Hammer Red** (`#B73E3E`): time, and only time. Imminent deadlines, the
  pulsing "new lot" dot, the freshness pill past 72 hours. Reserving it for
  urgency is what makes a red row mean something.
- **Seal Green** (`#3D7A6A`) and **Info Slate** (`#4A6B85`): confirmation and
  neutral notice. Both are desaturated to sit inside the warm palette rather
  than on top of it.

### Neutral
- **Parchment** (`#FAF8F4`): the page ground. The single most identity-defining
  value in the system.
- **Surface** (`#FFFFFF`): cards, the table body, modals — white only ever
  appears *on* parchment, which is what makes cards read as laid on a desk.
- **Rule** (`#E5DFD3`): every border and divider. A warm tan, not a grey.
- **Ink** (`#1A1F2E`) → **Body Ink** (`#3D4859`) → **Muted Ink** (`#7B8499`) →
  **Mist Ink** (`#B8BEC9`): the four-step text ramp, headings down to disabled.

### Named Rules

**The Parchment Rule.** The page ground is `#FAF8F4` and never pure white.
White is a surface that sits *on* the ground; if the two are ever the same
value, cards stop existing.

**The Gold Is A Seal Rule.** Treasury Gold marks provenance and status — the
seal, a re-announcement, a staleness warning. It is never a call to action and
never a large fill. If gold covers more than a badge, it has stopped being a
seal.

**The Red Means Time Rule.** Hammer Red is reserved for deadlines and newness.
It is not an error colour, not a brand colour, and not available for emphasis.
A red cell on this screen must always mean the clock.

## Typography

**Display Font:** Iowan Old Style (with Palatino Linotype, Palatino, Cambria,
Georgia, serif)
**Body Font:** Segoe UI (with Tahoma, Arabic UI Text, system-ui, sans-serif)

**Character:** An old-style serif against a plain system sans. The serif does
the ceremonial work — the wordmark, headings, and every figure — while the sans
carries body copy, controls and filters. The stack is deliberately system-local:
no webfont is loaded, so the page paints immediately and Arabic falls through to
the platform's own Arabic face rather than a mismatched Latin webfont.

### Hierarchy
- **Display** (600, `clamp(2.1rem, 5.5vw, 3.5rem)`, 1.12): the landing hero
  headline. Once per page, never in the dashboard.
- **Title** (600, 1.25rem): modal titles and section headings.
- **Body** (400, 0.85rem, 1.5): table cells, labels, descriptions. The dashboard
  lives almost entirely at this size.
- **Label** (600, 0.7rem): pills, badges, column chips. Small and heavy.
- **Numeric** (serif, 0.98rem, `tabular-nums`): every monetary value, count and
  countdown.

### Named Rules

**The Tabular Serif Rule.** Numbers are set in the display serif with
`font-variant-numeric: tabular-nums`, not in the body sans. Columns of dinars
must align on the decimal down a 300-row table; this is the reason the serif
exists in the body of the page at all.

**The No Webfont Rule.** The type stack is system-local by design. Do not add a
Google Font or any webfont — it would delay first paint on a mobile connection
and would not improve the Arabic rendering, which is the only language here.

## Layout

A single-column page over a parchment ground, with content held in white cards
on a 14px radius. The dashboard is table-led: a sticky-headed data table is the
primary surface, with a stat-tile row above it and a filter card between.

Spacing runs on a small, tight rhythm — 4 / 7 / 11 / 16 / 26px — which is what
produces the density. Card padding sits at 11px, not the 16–24px a marketing
layout would use.

**Breakpoints are 560px and 900px**, and there are only two. Below 900px the
layout collapses to a single column; below 560px the stat row wraps and controls
go full width. The table does not reflow into cards — it keeps horizontal
scroll, because a lot's figures only make sense read across.

**Direction is RTL throughout** (`dir="rtl"`, `lang="ar"`). Use logical
properties (`margin-inline-start`, not `margin-left`) so nothing mirrors wrongly.

## Elevation & Depth

Flat at rest, lifting on interaction. Surfaces are defined by a 1px warm rule
and the parchment/white contrast, not by shadow. Shadow appears as a *response*:
a card lifts 2px on hover, a popover sits above the page, a focus ring insets.

Every shadow is tinted with Court Navy Deep (`rgba(14,36,56,…)`), never neutral
black — a black shadow on parchment goes grey and muddy.

### Shadow Vocabulary
- **Resting** (`0 2px 6px rgba(14,36,56,.06)`): the near-invisible seat under
  cards, tiles and the table. Present so edges are not purely linear.
- **Lifted** (`0 1px 2px rgba(14,36,56,.06), 0 12px 28px -12px rgba(14,36,56,.22)`):
  hover on a card or stat tile, paired with `translateY(-2px)`.
- **Floating** (`0 12px 32px -10px rgba(14,36,56,.35)`): popovers and the column
  filter panel, which are appended to `<body>` to escape the table's overflow
  clipping.
- **Focus** (`0 0 0 2px var(--color-primary) inset, 0 2px 6px rgba(0,0,0,.06)`):
  an inset navy ring, so focus never changes an element's footprint.

### Named Rules

**The Navy Shadow Rule.** Shadows are `rgba(14,36,56,…)`. A neutral-black shadow
on `#FAF8F4` reads as dirt, not depth.

## Shapes

Soft but not round. The system has one signature radius — **14px on cards**
(`--radius-card`) — and a descending scale for smaller elements: 10px on
popovers, 6px on controls, 4px on the smallest chips, and fully round (999px)
on pills and the freshness indicator.

Borders are 1px in Rule tan on every container. The form language is rectangular
and calm; nothing is clipped, skewed, or given a decorative silhouette.

**The signature mark** is a 48×48 line-drawn balance scale in Treasury Gold:
two concentric circles, a vertical beam, a horizontal crossbar and two triangular
pans, all at 0.6–1.6px stroke weight with no fill. It is the only illustrative
element in the system and appears once per page, in the brand lockup.

## Components

### Buttons
- **Shape:** Bootstrap's default radius (~6px) — *not* the 14px card token.
- **Primary:** Court Navy ground, white text, via `--bs-primary` remapping.
- **Status variants:** success (Seal Green), danger (Hammer Red), warning
  (Treasury Gold), info (Info Slate), all remapped the same way.
- **Known compromise:** buttons are not styled by this system at all. Bootstrap
  supplies the shape, padding and states; only the palette is ours. See Do's and
  Don'ts.

### Chips / Pills
- **Style:** fully round (999px), Treasury Gold Soft ground, Treasury Gold Deep
  text, 0.7rem at weight 600, 2px 8px padding.
- **Use:** category badges, the re-announcement marker, the landing page's
  freshness indicator (which shifts to gold past 24h and red past 72h).

### Cards / Containers
- **Corner Style:** 14px (`--radius-card`), the system's signature radius.
- **Background:** Surface white on the parchment ground.
- **Border:** 1px Rule tan. **Shadow:** Resting, lifting on hover.
- **Internal Padding:** 11px — tight, because density is the point.
- **Caution:** Bootstrap's `.rounded`, `.bg-white` and `.shadow-sm` utilities
  use `!important` and will silently override the radius token to 6px. Do not
  combine them with a card.

### Stat Tiles
Cards that are also controls: each tile filters the table when clicked. The
value is set in the numeric serif; the label in small sans. They lift on hover
like any card, which is the only affordance indicating they are clickable.

### Data Table
The primary surface. Navy header, sticky on scroll, with a small filter chip in
each header cell. Rows separated by Rule tan at 1px. Horizontal scroll is
preserved at every width.
- **Caution:** `.table-responsive` sets `overflow-x: auto`, which clips absolutely
  positioned descendants. Popovers must be appended to `<body>`, and the filter
  card needs `z-index: 5` to sit above it.

### Brand Lockup
The gold scales mark at 42×42, followed by the wordmark in the display serif
with a small-caps eyebrow line above it. Appears once, top-right (RTL leading
edge).

## Do's and Don'ts

### Do:
- **Do** keep the page ground on Parchment (`#FAF8F4`) and reserve white for
  surfaces that sit on it.
- **Do** set every number in the serif with `tabular-nums`, so columns align.
- **Do** tint shadows with `rgba(14,36,56,…)`, never neutral black.
- **Do** use logical properties (`margin-inline-start`, `padding-inline`) — the
  entire interface is RTL.
- **Do** append popovers and dropdowns to `<body>` when they originate inside
  `.table-responsive`, which would otherwise clip them.
- **Do** treat the 14px card radius as the signature shape.

### Don't:
- **Don't** use Hammer Red for anything except deadlines and newness. It is not
  an error colour and not available for emphasis.
- **Don't** let Treasury Gold grow beyond a badge, seal or marker. Gold at scale
  stops being a seal.
- **Don't** add a webfont. The stack is system-local so Arabic resolves to the
  platform face and first paint is immediate.
- **Don't** combine Bootstrap's `.rounded` / `.shadow-sm` / `.bg-white`
  utilities with a card — their `!important` silently overrides the radius token.
- **Don't** set `overflow: hidden` on `.table-responsive`; it breaks horizontal
  scroll on mobile, where the table is read by scrolling across.
- **Don't** treat the current button styling as the system's intent. Components
  inherit Bootstrap's shape with only the palette remapped — this is recorded
  drift, not a decision. New component work should restyle properly, starting
  with the radius conflict between the 14px card token and Bootstrap's ~6px
  controls.
- **Don't** define the same token twice under different names. The landing page
  calls it `--navy` and the dashboard calls it `--color-primary` for the same
  `#1B3A57`; converge on one, do not add a third.
