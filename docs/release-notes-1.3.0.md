Watchtower can now show the month's spend in the menu bar itself, beside the
glyph, as an opt-in.

Opening the panel to answer "how much so far" is one click too many when the
answer is a number that fits next to the icon. With **Show cost in menu bar**
ticked in the panel footer, the status item reads `$4.12 · in 12d 6h`:
month-to-date spend, and how long until the billing month closes. A second
style, **% of budget**, reads `31% · in 12d 6h` instead. Off by default, so an
existing install looks exactly as it did.

**Added**
- The readout, in two styles. Amount is the `AWS/Billing` total the "Estimated
  bill" card already polls; with billing alerts off it falls back to the
  budget's actual spend from AWS Budgets, which is free and already fetched.
  Percent is that same budget's actual over its limit.
- The countdown, truncated rather than rounded: `in 12d 6h`, then `in 6h 40m`,
  then `in 40m`, so it never overstates what is left.
- `menuBarCost` and `menuBarCostStyle` (`amount` | `percent`) in `defaults`.
  The footer checkbox and picker write the same keys and take effect without
  a relaunch.
- `--selftest` prints the exact line the menu bar would show, or `(icon only)`.

**No new API calls.** Everything the readout shows was already being fetched
for the panel; the countdown runs off the panel's existing clock. The
measured-spend figure in the footer does not move.

**The glyph stays first and stays the same.** The text is added after it,
never in place of it, so alarm and budget state are still readable at a
glance, and the status item is icon-only whenever the option is off.

**Icon only rather than a false zero.** Billing alerts enabled but nothing
published yet this month, or no data from either feed, leaves the status item
exactly as before. A `$0.00` from missing data is the reading this app exists
to avoid, in the menu bar as much as in the panel. A failed poll keeps showing
the last value, the same way the cards do.

### Upgrading

No policy or account changes. Replace the installed copy and relaunch:

```sh
ditto --norsrc --noextattr --noacl dist/Watchtower.app ~/Applications/Watchtower.app
codesign --force --sign - --timestamp=none ~/Applications/Watchtower.app
```

Then tick **Show cost in menu bar** in the panel footer, or set it from the
terminal:

```sh
defaults write dev.ryangrey.watchtower menuBarCost -bool true
```

---

### This build is not notarized

It is ad-hoc signed, so macOS will refuse it on first open. That is what an
unnotarized app is, not a broken download. Either **right-click ▸ Open** the
first time, or clear the quarantine flag:

```sh
xattr -d com.apple.quarantine /Applications/Watchtower.app
```

Building from source avoids this entirely — `scripts/make-app.sh` needs only
Command Line Tools, no Xcode.
