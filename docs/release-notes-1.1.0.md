The panel is redesigned on [Primer](https://primer.style), GitHub's design
system, ported to SwiftUI in one dependency-free file. The repo is now MIT.

Before, the panel was styled ad hoc: sizes and colours picked per view,
`.green` and `.orange` standing in for state, sections separated by bare
dividers. It read as a stack of rows rather than an interface, and nothing
stopped two views that meant the same thing from being drawn differently.

**Changed**
- `Panel/Primer.swift` carries real Primer tokens (from `primer/primitives`,
  not eyeballed) and the components the panel needs — Box, Label, Counter,
  buttons, flash, table rules. About 350 lines, no dependency added.
- Colour always carries a role. `PrimerRole` selects foreground, emphasis and
  subtle background together, so no state can be styled inconsistently with
  another, and the header glyph and its state pill can never disagree.
- Every failure is now a flash — a tinted, bordered callout — rather than a
  line of coloured text. A stale or failed value is the one thing this app must
  never let you read as real, so it is louder than a healthy one, not merely a
  different hue.
- Colours are dynamic `NSColor`s, so `--preview` and `--render` draw a light
  pane and a dark pane in one window, each correct for its own appearance.
- Two deliberate departures from Primer: the budget bar still handles an
  over-100% month and names the overage in a danger flash, and the type scale
  is dropped two points because a menu-bar popover is denser than a page.

**Added**
- `LICENSE` — MIT.

**Docs**
- The three README renders are regenerated from the new panel on live data.

No behaviour, polling, credential or cost changes. Configuration is unchanged;
an existing install just needs the new bundle.

**Install it somewhere permanent.** `dist/` is a build output that
`scripts/make-app.sh` deletes on every build:

```sh
ditto --norsrc --noextattr --noacl dist/Watchtower.app ~/Applications/Watchtower.app
codesign --force --sign - --timestamp=none ~/Applications/Watchtower.app
~/Applications/Watchtower.app/Contents/MacOS/Watchtower --login-item register
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
