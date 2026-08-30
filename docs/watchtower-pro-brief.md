# Watchtower Pro — product brief

**Status:** not started. This document defines the product; no Pro code exists yet.
**Open decisions in §7:** items 2 and 3 settled 2026-08-29; item 1 (Apple) still open.
**Base:** `~/Documents/cloud-watchtower` (Cloud Watchtower, shipped, single-user).
**Author of brief:** Claude (Cowork), 2026-08-29, from a read of the live repo.
**Audience:** Claude Code, as the implementation brief.

---

## 1. What this is

Cloud Watchtower today is a personal macOS menu-bar monitor hardwired to one
CloudFront distribution, one CloudWatch alarm and one AWS Budget belonging to
`ryangrey.dev`. It is finished, verified against live AWS, and good.

Watchtower Pro is the commercial version of the same idea: **a menu-bar AWS
monitor for people running small AWS accounts, whose selling point is that it
tells the truth and does not cost more than the thing it is watching.**

That second clause is the actual product thesis and it should drive every
decision below. The existing README already contains the argument in full —
the naive polling design costs $8.50/mo to watch a $5/mo budget, which is 170%
of the budget being monitored. Every competitor in this space either ignores
cost entirely or is an enterprise observability tool priced for teams. Nobody
is selling *frugal, honest monitoring for a hobby-scale AWS account.*

### The two properties worth charging for

1. **Cost-aware polling.** Alarm state and budget state are free, so they poll
   fast. Metrics are billed, so they poll lazily and batch into one call. Cost
   Explorer costs ~$0.01 a request, so it never runs on a timer at all and the
   manual button is labelled with its own price. Measured cost: $0.12/mo
   passive, $0.42/mo worst case.
2. **Honest degradation.** Every card holds its own value, last-success time
   and last error. A failed refresh keeps the last known value *with the
   failure named and the value's age stated* — never a blank, never a zero
   standing in for unknown. The glyph has three states, not two, because
   "cannot reach AWS" is not "healthy". Values older than 15 minutes stop
   counting as evidence of health. Cost Explorer's backfill trap (structurally
   valid all-zero data for a month that genuinely cost money) is detected by
   counting populated days rather than trusting the total.

Both of these are already built. The Pro work is almost entirely about turning
a one-account tool into something a stranger can install.

---

## 2. What already exists and must be preserved

Assets in the current repo that Pro inherits and should not regress:

- **Zero dependencies.** Not even the AWS SDK. `Sources/Watchtower/Infra/SigV4.swift`
  signs requests with CryptoKit in ~100 lines. Clean build ~20 seconds. This was
  a deliberate call after `awslabs/aws-sdk-swift` (2.3 GB, ~923k objects) failed
  to resolve in 110 minutes. Keep it — it is also what makes the credential
  handling auditable, which is a sales argument for a security-sensitive app.
- **Two wire protocols.** CloudWatch and STS speak AWS Query (form-encoded POST,
  XML response, hence the small `XMLNode` parser); Budgets and Cost Explorer
  speak JSON with an `X-Amz-Target` header. Both implemented.
- **Read-only assumed role, not the deploy user.** The app reads `~/.aws/config`
  and `~/.aws/credentials` itself, including `role_arn` + `source_profile`, and
  performs `sts:AssumeRole` directly, running on 1-hour STS credentials. It
  deliberately ignores `AWS_PROFILE`/`AWS_REGION` because a GUI app launched at
  login inherits no shell environment. `infra/` has the policy and trust JSON.
- **Request-weighted error rates.** 24h rate is `Σ(rate × requests) / Σrequests`,
  not the mean of hourly rates. On live data that was 56.99% weighted vs 51.22%
  unweighted. No traffic renders `—`, not `0%`.
- **Builds without Xcode.** Command Line Tools ship the macOS SDK including
  SwiftUI; `scripts/make-app.sh` wraps `swift build` output into the bundle that
  `MenuBarExtra`, `LSUIElement` and `SMAppService` need.
- **`@State` is banned.** In the macOS 27 SDK `@State` is a macro, and
  `libSwiftUIMacros.dylib` ships with Xcode, not Command Line Tools. View state
  lives in `AppState` as `@Published` instead. **This constraint survives into
  Pro** — do not introduce `@State` anywhere.
- **Headless entry points.** `--selftest` (live AWS verification incl.
  `sts:GetCallerIdentity`), `--preview` (light+dark in a normal window),
  `--render <path.png>` (draw the panel to a PNG with no screen). These are
  gold for generating marketing screenshots and for CI.
- **In-app call meter.** `callmeter.json` counts every call and multiplies by
  published unit price, shown in the panel footer. This becomes a *feature* in
  Pro: "this app tells you what it costs you."

---

## 3. What blocks it from being sold

Ordered by how hard they block.

### 3.1 The sandbox fork — DECIDED 2026-08-29: Option A, direct distribution

**Decision: Option A — direct distribution.** Settled with Ryan on 2026-08-29. The
reasoning below replaces the original argument, which rested on a technical
error worth recording so it is not re-derived later.

**Correction to the original premise.** This document previously claimed that
sandboxing forces abandoning the `~/.aws` read in favour of pasted credentials
in Keychain — "exactly the second copy of a long-lived secret the current design
refuses to create". That is a false dichotomy. A sandboxed app *can* read
`~/.aws`, via `NSOpenPanel` plus a **security-scoped bookmark**
(`com.apple.security.files.user-selected.read-only` +
`com.apple.security.files.bookmarks.app-scope`), which persists read access
across launches. Bookmark the *directory* rather than the individual files and
it survives the atomic rewrites `aws configure` performs. Sandboxed-and-reading-
the-real-file is arguably a *stronger* security story than unsandboxed-and-
reading-the-real-file: the OS gates the access and the user granted it
explicitly. **The credential model does not decide this question.**

**What actually decides it.** Two facts, both independent of sandboxing:

1. **The Mac App Store has no upgrade pricing.** §5 commits to $15 paid major
   upgrades for v2. MAS has no mechanism for this; you ship a separate SKU and
   lose continuity with your install base.
2. **The Mac App Store has no trial for a paid-upfront app.** Phase 3 commits to
   a 14-day trial. On MAS that requires free-with-IAP — rewriting the entire
   licensing story — or a separate "lite" SKU.

**Both pricing decisions already made in §5 and Phase 3 are incompatible with
the App Store regardless of the sandbox.** The business model would have to be
redesigned before the sandbox question even became live.

Supporting reasons, in rough order of weight:

- **Onboarding friction compounds at the known bounce point.** §6 risk #1 is that
  IAM onboarding is the biggest conversion killer. Sandboxing adds "find a hidden
  folder in an open panel" on top of "create an IAM role". Stacking friction at
  the worst point in the funnel is the wrong place to spend it.
- **App Review adjudication risk.** An app whose core function is reading your
  cloud credentials file draws a reviewer who may not understand it. That risk is
  unbounded in time, unappealable in practice, and recurs on every update.
- **Apple is already on the critical path and already misbehaving.** §3.2 is live
  proof — the membership name is wrong and case `20000148660563` is open. Adding
  a per-release Apple gate on top of an unresolved Apple blocker is the wrong
  direction.
- **MAS packaging fights the Command-Line-Tools-only pipeline.** `pkgbuild` and
  `productbuild` ship with CLT, but embedding a provisioning profile and driving
  Transporter without Xcode is genuinely fiddly. `xcrun notarytool` is a clean
  one-liner by comparison, and CI stays cheap.
- **Option A is the reversible choice.** Ship direct and MAS remains available
  later if it ever justifies a business-model rewrite. The reverse is not true.

**What Option A costs, stated honestly.** The original argument led with "keeps
100% of revenue minus payment processor". That is the *weakest* consideration
here. At the §5 expectation of ~200 units × $29, MAS's 15% (Small Business
Program) is ~$870 against a merchant of record's ~5–8%, ~$400 — a delta of
roughly **$450 over the product's entire life**, less than the value of the 28
hours Phase 3 costs. The real price of Option A is:

- **Phase 3 (~28 h) exists only because of this decision.** MAS would have
  provided payment, tax and licensing for its cut.
- **The Sparkle dependency in Phase 2** breaks the zero-dependency streak. MAS
  would have provided updates for free.

Roughly 30 hours and one dependency, paid to keep upgrade pricing, keep a real
trial, and stay off Apple's per-release review gate. **That is still the right
trade** — but it is a trade, not a freebie, and should be described as one.

Retained for the record:

- **Option B — Mac App Store.** Sandboxed, credentials via security-scoped
  bookmark (not Keychain paste, per the correction above). Gains discovery —
  which is worth approximately nothing here, since the audience is reached
  through r/aws and Hacker News, not App Store browsing — and payment handling.
  Costs 15–30%, App Review risk, upgrade pricing, and the trial.
- **Option C — Both.** Double the surface, double the support. Rejected.

### 3.2 Apple Developer account name — external blocker

The Apple Developer membership still shows **Christopher Dotson**, not Ryan
Grey. Notarized, Developer-ID-signed builds display the membership name as the
developer identity. Shipping today would put the wrong name on the product.
The Membership Information Update form (region US, "Name") is drafted and case
`20000148660563` is open. **This must resolve before any public build.** It is
not a coding task and it has a lead time, so start it now, in parallel.

### 3.3 Everything is hardcoded to one account

Current config is six `defaults write` invocations against
`dev.ryangrey.watchtower`: `accountId`, `distributionId`, `alarmName`,
`budgetName`, `profileName`, `region`. One of each. There is **no settings UI
at all**.

Pro needs: multiple resources per type, multiple AWS profiles/accounts, and a
real settings window. This is the largest chunk of engineering.

### 3.4 IAM onboarding is the conversion killer

The current setup asks the user to create an IAM role, attach a policy scoped
to specific ARNs, and set up a trust relationship. That is fine for the author.
For a stranger who just paid $29, it is a wall. Most people will bounce here,
and no amount of polish elsewhere compensates.

**Mitigation is mandatory, not optional:** ship a CloudFormation (or CDK)
one-click stack that creates the read-only role and outputs the ARN, plus an
in-app wizard that validates the result with `sts:GetCallerIdentity` and names
the exact missing statement when a call is denied. The existing `--selftest`
already does the diagnostic half of this — it names the statement and the ARN
suffix to fix when `DescribeBudget` is denied. Surface that in the GUI.

### 3.5 Smaller gaps

- Ad-hoc signed (`codesign -s -`); not notarized, not distributable.
- No updater. Needs Sparkle (or equivalent) — note this breaks the zero-dependency
  streak; that is an acceptable trade for a shipping product, but say so
  explicitly rather than quietly.
- No licensing or payment path.
- Bundle ID `dev.ryangrey.watchtower` — decide whether Pro reuses it or forks.
- Launch-at-login is wired to `SMAppService` but **never exercised across a
  reboot**. Verify before shipping; a monitor that doesn't come back after
  restart is worthless.
- `--render` uses a fixed 9-second wait for data rather than observing load
  state. Fine for a dev script, flaky for CI screenshot generation.
- No crash reporting, no analytics, no support channel.
- Only CloudFront metrics. See scope below.

---

## 4. Scope

### Phase 1 — Multi-tenancy and configuration (~43 h) — COMPLETE 2026-08-29

Delivered on branch `pro/phase-1-multi-target`. Clean build, no warnings, zero
`@State`, zero dependencies, 63 offline checks (`--verify`) and a live
`--selftest` against the real account.

**One bug fixed that predates Pro and affected every prior build.** CloudWatch
timestamps a bucket at its start and aligns the bucket grid to the request's
`StartTime`, which is derived from "now" — so the newest bucket always begins
one window-length ago, and `timestamp >= now - 3600` dropped it by the
request's own latency. Observed live at `22:47:00Z` against a `22:47:01Z`
cutoff: the entire "last hour" column rendered `—`. Membership is now decided
by bucket coverage. The same off-by-one gave the 24-hour figure 23 buckets
instead of 24, which may account for part of the README's 56.93% vs 56.99% CLI
gap. It read as a quiet hour rather than a bug because the old code returned
`0` for the requests row and `—` only for the two rate rows.

**Still unverified, and the one thing worth a real test:** multi-account. The
per-profile credential cache and cross-account batching are covered by offline
checks and reasoning, not by a live two-account run, because only one profile
exists in `~/.aws`. Phase 2's CI throwaway account is the natural place to
close this.

**Data model settled 2026-08-29 — see risk #3 in §6.** Generic CloudWatch
transport with typed recipes, not CloudFront-specific. The +8 h over the
original 35 h estimate is the cost of that decision and lands almost entirely in
panel rendering, not in the fetch path.

- Replace the six scalar `defaults` keys with a structured config: a list of
  *watch targets*, each with a type, an identifier, a display name, an AWS
  profile and a region.

```
WatchTarget { id, displayName, profile, region, kind }
kind = .alarm(name) | .budget(name) | .metricGroup(MetricGroup)

MetricGroup {
  recipe: .cloudFront | .lambda | .apiGateway | .dynamoDB | .custom
  namespace: String
  dimensions: [String: String]     // DistributionId+Region, FunctionName, ApiName, TableName
  series:  [SeriesSpec]            // what we ask GetMetricData for
  derived: [DerivedSpec]           // what the card displays
  period: Int                      // 3600
  windowHours: Double              // 25 — one window yields both the 1 h and 24 h figures
}

SeriesSpec  { id, metricName, stat }
DerivedSpec {
  label, unit: .count | .percent | .milliseconds | .bytes,
  windows: [1, 24],
  form: .sum(id)
      | .ratio(numerator: id, denominator: id)          // Lambda / API Gateway / DynamoDB
      | .weightedAverage(rate: id, weight: id)          // CloudFront
      | .latest(id)
}
```

- `MetricsSnapshot` becomes `series: [String: [Date: Double]]` — which is
  precisely what `CloudWatchService.getMetricData` already builds internally
  before collapsing it into `HourBucket`'s three fixed fields. **This is a
  deletion, not an added abstraction.** `Loaded<T>`, the per-card age/error
  model and `Health` are untouched.
- Metrics do not feed `Health` today (only alarms and budgets do), so generic
  metric cards stay display-only. **No thresholding UI is required in Phase 1**,
  which is what bounds the blast radius of going generic.
- Settings window: add/edit/remove targets, pick profile, pick region, test
  connection. No `@State` — extend `AppState` with `@Published`.
- Migration path from the existing `defaults` keys so the author's own install
  survives the upgrade. The current `distributionId` maps to exactly one
  `.cloudFront` recipe instance.
- Panel must handle N cards, grouped, scrollable, without losing the
  per-card independent value/age/error model.

**Preserve the polling economics per target.** Alarms fast and free, budgets
600 s, metrics lazy at 900 s idle / 300 s active.

> **Correction to the original instruction.** This section previously said
> "batch across targets in a single call wherever the window and resolution
> match", implying a cost saving. There is none. `GetMetricData` bills **$0.01
> per 1,000 metrics requested, not per request** — splitting three metrics
> across three calls costs exactly what one call with three metrics costs. The
> README's actual saving is about *windows*: one 25-hour window instead of two
> halves the billable metric count, and that reasoning is correct as written.

For N targets, billable cost is **linear in Σ|series| per poll, and batching does
not bend that curve.** The levers that do:

- **One window per target**, with the 1 h and 24 h figures computed client-side
  (the existing trick, generalised).
- **Deduplicate identical `(namespace, metric, dimensions, stat, period)` tuples**
  across targets before issuing the call.
- **Minimal default series per recipe.** Lambda's obvious "everything" is five
  metrics; ship three.
- **Live cost projection in the settings window:** *"This configuration:
  12 metrics × 3,900 polls/mo = $0.47/mo."* Nobody else in this space shows the
  price of a monitoring configuration before you commit to it. It turns the
  product thesis from a static README claim into an interactive feature, and it
  makes the generic model self-limiting — a user who adds 40 metrics watches the
  price move.

Batching across targets is still worth doing for throttling headroom and latency
(`GetMetricData` caps at 500 queries per call) — just do not book it as savings.

### Phase 2 — Distribution (~20 h)

- Developer ID Application certificate, hardened runtime, notarization,
  stapling, DMG with background and Applications symlink.
- Sparkle updater with an EdDSA-signed appcast hosted on the existing S3 +
  CloudFront setup. Ryan already runs keyless CI/CD to that bucket.
- CI: build, `--selftest` against a throwaway account, `--render` screenshots,
  notarize, publish appcast. The build already works with Command Line Tools
  only, which makes CI cheap.
- Verify launch-at-login across a real reboot.

### Phase 3 — Licensing and purchase (~28 h)

- Payment via a merchant of record (Paddle or Lemon Squeezy) so VAT/sales tax
  is not Ryan's problem. This matters more than it sounds.
- Offline-verifiable license keys — sign the key with an Ed25519 private key,
  verify in-app with the embedded public key. **Ryan has already implemented
  Ed25519 signature verification for greyBot's Discord interactions endpoint**,
  so this is a known quantity, not new ground.
- 14-day trial with honest expiry (a monitoring app that silently stops
  monitoring when the trial ends would violate the product's own thesis — it
  must keep showing state and say clearly that it is unlicensed, or stop
  entirely and say so; do not degrade silently).

### Phase 4 — Onboarding (~22 h)

- CloudFormation one-click stack creating the read-only role, parameterised on
  the resources to watch, outputting the role ARN.
- In-app first-run wizard: paste role ARN → run `--selftest` logic in-GUI →
  green check or the precise missing IAM statement.
- Resource discovery: once credentials work, list the account's alarms,
  budgets and distributions so the user picks from a list rather than typing
  IDs. Note this needs `cloudfront:ListDistributions` and
  `budgets:DescribeBudgets` added to the policy — a real widening of scope,
  worth it for onboarding, and it stays read-only.

### Phase 5 — Market surface (~22 h)

- Landing page. Ryan already owns and operates `ryangrey.dev` on CloudFront
  with a keyless deploy pipeline; a `watchtower.ryangrey.dev` subdomain is
  nearly free to stand up.
- Screenshots from `--render` (already produces light/dark at 2x, and
  `scripts/optimise-png.py` got the existing one from 193 KB to 77 KB).
- Docs, changelog, a support email, a refund policy.
- Launch posts: r/aws, r/macapps, Hacker News "Show HN", Product Hunt.

**Total: ~135 hours.** At 10 h/week that is roughly **3.5 months to a paid v1.0**;
at 20 h/week, ~7 weeks. (Up from 127 h: Phase 1 absorbs +8 h for the generic
metric model decided in §6 risk #3.)

### Explicitly out of scope for v1

- Windows/Linux. It is a macOS menu-bar app; that is the product.
- Multi-cloud. "Watchtower for GCP" is a different product.
- Log search, tracing, APM. That is Datadog's business and it is not winnable.
- Team features, shared dashboards, alerting/paging. Single-user desktop only.
- Anything that requires a backend service. There is currently no server-side
  component and adding one adds cost, liability and a privacy story to defend.
  Licensing verification must stay offline for this reason.

---

## 5. Pricing

Recommendation: **$29 one-time, per-user, with 1 year of updates.**

Reasoning, including the uncomfortable parts:

- Menu-bar utilities sell one-time, not by subscription. Subscription fatigue
  is real and the audience is developers, who are the loudest about it.
- The target buyer is by definition someone watching a *$5/month* AWS budget.
  Their demonstrated willingness to pay for cloud spend is very low. A $9/mo
  subscription to watch a $5/mo bill is self-refuting — and it is the exact
  absurdity the product's own README mocks. **Do not ship a subscription.**
  It would contradict the thesis in a way reviewers would notice.
- $29 is roughly a good lunch and sits comfortably in impulse range for a
  developer tool. $19 leaves money on the table; $49 invites comparison to
  tools with far more surface area.
- Paid major upgrades ($15 for v2) rather than recurring revenue.

**Note:** the paid-upgrade model here and the 14-day trial in Phase 3 are
load-bearing for §3.1 — both are unavailable on the Mac App Store, and together
they decide the distribution question. Changing either reopens §3.1.

**Realistic revenue expectation: low.** This is a small market — solo devs and
tiny teams running personal AWS accounts on macOS who care enough to install a
monitor. A good launch might be 100–300 units. Treat the money as a bonus and
the *portfolio credibility* as the actual return: "shipped and sold a notarized
macOS product with offline licensing" is a materially different line on a CV
than "built a menu-bar app."

---

## 6. Risks, stated plainly

1. **IAM onboarding friction is the biggest single risk to conversion.** Phase 4
   is not polish; it is the difference between a product and a demo.
2. **Market size is genuinely small.** Nothing in the build plan fixes this.
3. **CloudFront-only metrics narrow the audience — RESOLVED 2026-08-29.**
   Most small AWS accounts are Lambda + API Gateway + DynamoDB, not CloudFront.
   **Decision: generic CloudWatch transport with typed recipes**, not
   CloudFront-specific and not unstructured "arbitrary metrics". Three findings
   drove it:
   - **The generic model is less code than the current one.** `CloudWatchService`
     already builds `[String: [Date: Double]]` and then discards it to fill
     `HourBucket`'s three named fields. Going generic deletes that collapse step.
     The request builder is already a loop over a tuple array — parameterised in
     shape, hardcoded only in content.
   - **The request-weighted rate is not CloudFront-specific; it is
     ratio-metric-specific**, and every service in the target market has that
     shape. CloudFront is `Σ(4xxErrorRate × Requests) / ΣRequests`; Lambda is
     `ΣErrors / ΣInvocations`; API Gateway is `Σ5XXError / ΣCount`; DynamoDB is
     `ΣThrottledRequests / ΣConsumedReadCapacityUnits`. Two derivation forms —
     `weightedAverage` and `ratio` — cover all four, and both preserve the
     undefined-denominator rule that renders `—` rather than `0%`. Generalising
     the feature **strengthens** the honesty story rather than diluting it; the
     Lambda/API Gateway case is cleaner than CloudFront's.
   - **It widens the IAM policy by nothing.** `cloudwatch:GetMetricData` is
     already granted on `Resource: "*"`. Given that risk #1 is onboarding
     friction, a large market widening that adds zero onboarding steps is close
     to free. Only Phase 4 discovery adds anything — `cloudwatch:ListMetrics`,
     one read-only action.

   Rejected: **fully generic with no semantic layer**, which reaches widest but
   surrenders weighted rates and undefined-denominator handling — i.e. trades the
   honesty differentiator for being a generic CloudWatch viewer. The `.custom`
   escape hatch serves power users; **lead marketing with the recipes**
   ("watches Lambda, API Gateway, CloudFront and DynamoDB"), never with
   arbitrary metrics, or the product reads as exactly that viewer.
4. **Support burden.** AWS misconfiguration will generate support email, and
   every one of those emails is unpaid time.
5. **Apple dependency.** Notarization can fail or slow down; the developer
   account name issue is already live proof that Apple is on the critical path.
6. **The macOS 27 `@State` macro constraint** means the build is unusual. If a
   future SDK changes this again, the workaround needs revisiting.

---

## 7. First things to do

1. Resolve the Apple Developer membership name (external, has lead time).
   **Still open** — case `20000148660563`. Blocks any public build.
2. ~~Decide the sandbox fork.~~ **Decided 2026-08-29: Option A, direct
   distribution.** See §3.1 for the reasoning, which is not the reasoning
   originally written there.
3. ~~Decide risk #3: CloudFront-specific or generic CloudWatch metrics.~~
   **Decided 2026-08-29: generic transport with typed recipes.** See §6 risk #3
   and the Phase 1 schema in §4.
4. ~~Then start Phase 1.~~ **Complete 2026-08-29** — see §4.

Items 2, 3 and 4 are done. Item 1 remains external and now gates everything
that follows: Phase 2 is the phase where the membership name actually appears
on the product, since notarized Developer-ID builds display it as the developer
identity. Nothing in phases 2–5 should begin until it resolves.

Nothing in phases 2–5 should begin before item 1 resolves.
