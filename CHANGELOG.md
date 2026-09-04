# Changelog

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
