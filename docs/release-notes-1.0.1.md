Fixes a failure where Watchtower silently stopped launching at login.

The login item pointed at a build that had been run once out of a temporary
directory. That directory was later swept, so every login tried to launch a
bundle that was no longer there — while System Settings still listed the item
and still showed it enabled. The app was simply never running, and nothing said
so.

**Fixed**
- `LaunchAtLogin` refuses to register from `/tmp`, `/var/folders`,
  `dirs_cleaner` or a `DerivedData` path, and names the path instead of
  registering something that will vanish. Unregistering still works from
  anywhere, which is how you clean up after a temporary copy has captured the
  login item.

**Added**
- `--login-item status|register|unregister`. The panel toggle is still the normal
  way in; this exists because the failure it is for leaves you with no panel to
  click. `status` prints the resolved bundle path — "enabled" on its own was the
  misleading part.

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
