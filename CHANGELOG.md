# Changelog

## 1.2.0 — 2026-09-06

**Added: the whole account's bill, polled every 15 minutes.**

Until now the only per-service spend figure came from Cost Explorer, behind a
manual button, because Cost Explorer costs $0.01 a request and putting that on a
timer would cost more than the budget it watches. The consequence was that the
panel could not answer the question people actually open it for: what is this
month going to cost, and which service is responsible.

The new "Estimated bill" card reads CloudWatch's `AWS/Billing` namespace, which
is a different trade: approximate and a few hours stale, but billed per metric
rather than per request, so a 900 s poll costs about $0.60/month rather than $29.

- **Every service, not a filtered set.** One metric per service AWS is charging
  for, plus the account total, in a single `GetMetricData` call. Services at
  $0.00 collapse into a count rather than disappearing — "18 services at $0.00"
  answers "is anything else running", and hiding them is how a newly expensive
  service goes unnoticed for a week.
- **A month-end projection, labelled as Watchtower's arithmetic rather than
  AWS's.** `month-to-date + (daily rate × days remaining)`, where the rate is the
  **median of the per-interval burn rates**. A one-off charge belongs in the
  month-to-date total but says nothing about the days remaining, and any average
  amortises it into a recurring cost: five days into a month, a $17 domain
  transfer projects $101.86 by endpoint difference and $17.00 by median. A
  trailing window alone does not fix this — early in the month the window is
  longer than the data, so the spike is inside it either way. Below five
  datapoints it declines to project rather than extrapolate.
- **`Maximum`, not `Average`.** `EstimatedCharges` is a cumulative gauge that
  resets at the billing boundary, so the largest value in a bucket is the state
  at the end of it. Averaging smears the running total backwards and
  under-reports every figure on screen.
- **Three empty states, one zero.** Billing alerts never enabled, enabled but
  not yet publishing, and a genuine $0.00 are distinguished; only the last draws
  a zero. This is the same rule the Cost Explorer backfill trap already follows.
- **The publish time is shown next to the fetch time**, because they are hours
  apart and conflating them is how a 15-minute poll gets mistaken for
  15-minute-fresh data.
- `billingIntervalSeconds` is exposed in `defaults` (floored at 300 s) — the one
  interval whose cost scales with the account rather than with the app.
- Adds `cloudwatch:ListMetrics` to the role policy, and requires **Receive
  CloudWatch billing alerts** to be enabled in Billing preferences.

## 1.1.0 — 2026-09-04

**Changed: the panel is redesigned on Primer.**

The panel was styled ad hoc — sizes and colours picked per view, `.green` and
`.orange` standing in for state, sections separated by bare dividers. It read as
a stack of rows rather than an interface, and nothing stopped two views that
meant the same thing from being drawn differently.

`Panel/Primer.swift` ports GitHub's Primer to SwiftUI: tokens taken from
`primer/primitives` rather than eyeballed, plus the components the panel needs —
Box, Label, Counter, btn, btn-invisible, flash, and the rules used to build
tables. No dependency is added; it is one file of about 350 lines.

- **Colour always carries a role.** `PrimerRole` selects foreground, emphasis
  and subtle background together, so no view hand-mixes three colours and no
  state can be styled inconsistently with another. Health maps onto a role, not
  a tint, which is why the header glyph and its Label pill can never disagree.
- **Every failure is a flash** — a tinted, bordered callout — instead of a line
  of coloured text. The mistake this app exists to prevent is reading a stale
  or failed value as a real one, so a degraded reading is visually louder than
  a healthy one, not merely a different hue.
- **Dynamic `NSColor`, not `@Environment(\.colorScheme)`.** `--preview` and
  `--render` pin a light pane and a dark pane to their own `NSAppearance` in
  one window; a dynamic provider resolves per view, which is what makes the
  two-up screenshot possible.
- Two places deliberately exceed Primer: the budget bar still handles more than
  100% (ProgressBar has no state for it) and keeps the danger flash naming the
  overage, and the type scale is Primer's 12/14/16/20 dropped two points,
  because a menu-bar popover is denser than a page.

**Added**
- `LICENSE` — the repo is MIT.

**Docs**
- All three README renders (`docs/panel.png`, `panel-alarm.png`,
  `panel-degraded.png`) re-rendered from the new panel on live data.

## 1.0.1 — 2026-09-01

**Fixed: the app silently stopped launching at login.**

The login item pointed at a build that had been run once out of a temporary
directory. That directory was later swept, so every login tried to launch a
bundle that was not there. Nothing reported it — System Settings still listed
the item and still showed it enabled, and the app was simply never running.

`SMAppService.mainApp.register()` registers whatever bundle is running, and
nothing checked that the bundle lived somewhere that would still exist tomorrow.
`LaunchAtLogin` now refuses to register from `/tmp`, `/var/folders`,
`dirs_cleaner` or a `DerivedData` path, and returns a message naming the path
instead. Paths are compared after resolving symlinks, since `/tmp` is a symlink
to `/private/tmp`. Unregistering stays allowed from anywhere — that is how you
clean up after a temporary copy has captured the login item.

**New: `--login-item status|register|unregister`.**

The panel's toggle is still the normal way in. This exists because the one
failure worth having a command for leaves the app not running, and therefore
leaves no panel to click. `status` prints the resolved bundle path, because
"enabled" on its own was exactly what was misleading.

**Install it somewhere permanent.** `dist/` is a build output that
`scripts/make-app.sh` deletes on every build, so it was never a safe home for
something macOS launches every morning. The README now documents copying to
`~/Applications` first.

**Release process.** `scripts/release.sh` builds, gates and packages; `VERSION`
is the single source of truth that `make-app.sh` reads too.

---

## 1.0.0

First working version: CloudFront traffic and error rates, CloudWatch alarm
state, and month-to-date spend against a budget, in a menu-bar app with no Dock
icon and no dependencies — SigV4 signed by hand rather than pulling a 2.3 GB SDK.
