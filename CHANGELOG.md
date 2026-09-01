# Changelog

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
