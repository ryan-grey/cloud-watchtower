Watchtower now shows what the whole AWS account is going to cost this month,
per service, updated on a timer, with a month-end projection.

Before, the only per-service spend figure came from Cost Explorer behind a
manual button, because Cost Explorer bills about $0.01 a request and putting
that on a 15-minute timer would cost roughly $29/month — six times the budget
it is watching. So the panel could not answer the question people actually open
it for: what is this month going to cost, and which service is responsible.

The new "Estimated bill" card reads CloudWatch's `AWS/Billing` namespace
instead. That is a different trade: approximate, a few hours stale, and blind to
credits, but billed per metric rather than per request, so a 900 s poll costs
about $0.60/month.

**Added**
- Every service AWS is charging for, plus the account total, in one
  `GetMetricData` call. Services at $0.00 collapse into a count rather than
  disappearing — "20 services, all at $0.00" answers "is anything else
  running", and hiding them is how a newly expensive service goes unnoticed.
- A month-end projection, labelled as Watchtower's arithmetic rather than
  AWS's: `month-to-date + (daily rate × days remaining)`.
- `billingIntervalSeconds` in `defaults`, floored at 300 s. This is the only
  interval whose cost scales with the account rather than with the app, so it
  is the only one exposed.
- `--selftest` now exercises the billing path and reports the three states
  separately.

**The projection uses a median, not an average**, and that is the whole point.
A one-off charge belongs in the month-to-date total but says nothing about what
the remaining days will cost, and any average amortises it into a recurring
cost. Five days into a month, a $17 domain transfer projects **$101.86** by
endpoint difference and **$17.00** by median. A trailing window does not fix
this on its own — early in the month the window is longer than the data, so the
spike sits inside it either way. Below five datapoints it declines to project
rather than extrapolate.

**Three empty states, one zero.** Billing alerts never enabled, enabled but not
yet publishing, and a genuine $0.00 are distinguished, and only the last draws
a zero. This is the same rule the Cost Explorer backfill trap already followed.
The panel also shows AWS's publish time next to Watchtower's fetch time,
because they are hours apart and conflating them is how a 15-minute poll gets
mistaken for 15-minute-fresh data.

**Cost Explorer stays on the button.** It is authoritative, it knows about
credits and refunds, and it is still never on a timer.

### Upgrading needs two things

1. Add `cloudwatch:ListMetrics` to the role policy — see
   [`infra/watchtower-readonly-policy.json`](../infra/watchtower-readonly-policy.json).
2. Tick **Receive CloudWatch billing alerts** in Billing preferences. The
   namespace does not exist until you do, it is `us-east-1` only regardless of
   where your resources run, and it lives on the payer account. The first
   datapoint can take a few hours.

Until both are done the card says which one is missing rather than drawing
`$0.00`, and `--selftest` names the exact policy statement to fix.

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
