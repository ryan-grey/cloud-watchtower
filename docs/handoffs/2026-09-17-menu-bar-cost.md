# Handoff: cost readout in the menu bar (opt-in)

Written Sept 17, 2026 by Atlas (Claude) for Claude Code. Ryan's ask: "make watchtower show total cost in menu bar next to its icon as an option you toggle in the app's settings, and have it show total cost so far and when the window ends, similar to how the ChatGPT menu-bar app shows `25% · in 4d 20h`."

## Result to build

When the option is on, the status item reads, for example:

    [glyph] $4.12 · in 12d 6h

`$4.12` is month-to-date spend, `in 12d 6h` is time until the current billing period closes. Option off (the default) leaves today's icon-only status item exactly as it is.

## Where the numbers come from (no new AWS calls)

- **Amount:** `state.billing.value?.total` — the CloudWatch `AWS/Billing EstimatedCharges` figure the panel already shows under "Estimated bill", polled every `billingIntervalSeconds` (default 900 s). Format with `Fmt.moneyAdaptive` so sub-dollar months don't read `$0.00`.
- **Fallback:** if `state.billingNotEnabled` or `billing.value == nil` but `state.budget.value` exists, use `budget.actual` (AWS Budgets, free, refreshed ~3×/day) and render the same way.
- **Window end:** the billing period is the calendar month in UTC. Derive the end from `billing.value?.periodStart` + 1 month (matches `Fmt.monthEndDay`), or from the current UTC date when only the budget fallback is available. Countdown against `state.now` (the existing 10 s ticker), formatted `in 12d 6h`; under 24 h → `in 6h 40m`; under 1 h → `in 40m`.
- **Never fabricate:** if neither billing nor budget has a value, or `billing.value?.hasData == false`, show the icon only. A `$0.00` from missing data is the exact lie the README says this app exists to avoid. If the feed `isFailing` but a last value exists, keep showing that last value (the panel already explains staleness).
- This adds zero API calls. Say so in the README's cost section.

## Settings

The footer's "Launch at login" checkbox is the only settings UI today. Add beside it:

1. **"Show cost in menu bar"** — checkbox, `UserDefaults` key `menuBarCost` (Bool, default false). Read into `Configuration` next to `billingIntervalSeconds`, with a matching `defaults write dev.ryangrey.watchtower menuBarCost -bool true` line in the README's Quick start block. Toggling must take effect immediately without relaunch (publish it through `AppState`).
2. **Style** — a small segmented picker shown only when the checkbox is on: `Amount` (default) or `% of budget`. Key `menuBarCostStyle`, values `amount` | `percent`. Percent uses `budget.fraction` via `Fmt.percent` and reads `31% · in 12d 6h`; if there is no budget value, fall back to Amount silently.

## Implementation notes

- `WatchtowerApp.body`: the `MenuBarExtra` label becomes an `HStack(spacing: 4)` of the existing `Image(systemName: state.health.systemImage)` plus, when enabled and a title exists, `Text(title).monospacedDigit()`. Keep the template-image tinting behaviour; the text inherits menu-bar colour on its own.
- Put the title logic in one pure function, e.g. `enum MenuBarTitle { static func make(billing:budget:billingNotEnabled:now:style:) -> String? }`, so it is testable and so `--selftest` can print the line it would show. Keep the countdown maths in `Fmt` next to `monthEndDay`.
- The health glyph stays first and stays the same; the text never replaces it, so alarm state is still visible at a glance.
- Width: the status item grows with the text. Amount + countdown is about 14–16 characters; keep the separator as ` · ` to match the panel's existing typography.

## Not in scope

No Cost Explorer calls (still manual, still billed). No changes to polling intervals. No new windows; the checkbox lives in the existing footer.

## Finish

- CHANGELOG entry under a new `1.3.0` heading; bump `VERSION`; `scripts/release.sh` as usual.
- README: Quick start defaults line, the "Interface" section (mention the readout and both styles), the cost section (zero added calls), and remove "The panel has no settings UI" from Known gaps or reword it.
- Verify by hand: toggle on → text appears within one tick; toggle off → icon only; kill network → last value stays, no `$0.00`; fresh install with no data → icon only.
