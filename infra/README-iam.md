# IAM for Watchtower

Watchtower should NOT run as `<DEPLOY_USER>`. Create a role it can assume instead.

## Why a role and not a second IAM user

A second user means a second long-lived access key on disk — two secrets to rotate and twice
the exposure. A role means the app holds **no new secret at all**: it assumes the role with
`<DEPLOY_USER>`'s existing key and runs on 1-hour STS credentials. Revoking is deleting the role.

## Create it (CloudShell, as admin — `<DEPLOY_USER>` has no IAM write, by design)

```sh
aws iam create-role \
  --role-name watchtower-readonly \
  --assume-role-policy-document file://watchtower-readonly-trust.json

aws iam put-role-policy \
  --role-name watchtower-readonly \
  --policy-name watchtower-readonly \
  --policy-document file://watchtower-readonly-policy.json
```

Then add to `~/.aws/config`:

```ini
[profile watchtower]
role_arn = arn:aws:iam::<ACCOUNT_ID>:role/watchtower-readonly
source_profile = default
region = us-east-1
```

Watchtower already defaults to the `watchtower` profile and supports `role_arn` +
`source_profile`, so nothing in the app needs to change. Verify with:

```sh
dist/Watchtower.app/Contents/MacOS/Watchtower --selftest --profile watchtower
```

## Note on `ce:GetCostAndUsage`

It is in the policy because the manual "Break down spend" button needs it. It is NEVER called
on a timer — see the cost section of the main README. If you would rather the menu-bar app
could not spend money at all, drop that statement; the button will then fail with a clear
AccessDenied and everything else keeps working.
