# AfterMe — On-call card (one page, print it)

**You are the second person on call. You do not need to be a developer.** AfterMe tells a person's chosen contacts if the person stops checking in. Your job is to notice when something is wrong and, if it might cause a **wrong message to a real contact**, to press the safe button (Hold). Pressing it never hurts anyone: people still get their reminders, contacts just wait.

Owner (developer): ______________________  phone: ______________  ·  Backup: ______________________  phone: ______________
Google Cloud project: **afterme-prod** (staging: afterme-staging)  ·  Dashboard: Console → Monitoring → Dashboards → "AfterMe operations"

## 1. What a page means (one sentence each)

| Subject starts with | Meaning |
|---|---|
| **engine status check reports a page** | Something the engine itself calls urgent: run **status** (below) and read the `pages` list. |
| **status watchdog is not running** | The thing that checks the engine every 2 minutes has stopped; assume nobody is watching and call the owner. |
| **Hold entered / consistency violation / action held** | The safety brake is on (or something odd happened): contacts are being protected, find out why. |
| **worker loop failing** | The engine's main loop keeps failing: call the owner. |
| **uptime check POST /internal/probe failing** | The app cannot be reached from outside; after 3 minutes the system puts itself in Hold. |
| **uptime check is not reporting** | The outside check itself is gone: call the owner. |
| **API 5xx rate** / **POST /v1/checkins error rate** | People are getting errors, possibly cannot check in: call the owner now. |
| **database …** | The database is busy, nearly full or down: call the owner now. |
| **KMS wrap/unwrap errors** | Saved instructions cannot be opened: call the owner. |
| **database backup is stale** | The nightly backup did not happen: call the owner the same day. |
| **(TEST)** | A practice page. Acknowledge it and tell the owner it arrived. |
| *notify:* latency, fallback e-mail provider, bounce spike, retention job, certificate | An e-mail only. Read it the same day, forward to the owner. |

## 2. The five commands

Open https://console.cloud.google.com → project **afterme-prod** → **Cloud Run** → **Jobs** (or in the Google Cloud app: Cloud Run → Jobs). Pick the job, press **Execute**, wait about a minute, open the new execution and its **Logs** tab. A green tick = exit 0.

| What you want | Job to execute | Output you read |
|---|---|---|
| `python -m cli.admin status` | **afterme-oncall-status** | A red cross (failed) means *something would page*. In the Logs find `"pages": [` and read the sentences in it; `"warnings"` are less urgent. |
| `python -m cli.admin hold status` | **afterme-oncall-hold-status** | `hold_active: true` means the brake is on, with the reason(s) (`ingestion`, `anomaly`, `operator`). |
| `python -m cli.admin hold enter --reason "…"` | **afterme-oncall-hold-enter** | `Hold entered: <id>`. Safe to press at any time. (The reason is fixed: "on-call stop-the-line"; tell the owner why in a message.) |
| `python -m cli.admin hold exit` | **afterme-oncall-hold-exit** | `Holds ended: n`. Ends operator and anomaly Holds; deadlines are shifted automatically. **Only with the owner's OK** (see §4). An ingestion Hold ends by itself. |
| `python -m cli.admin incident void <incident-id>` | **afterme-admin**, button **Execute with overrides**, in *Arguments* enter: `--operator`, `oncall`, `incident`, `void`, `<the incident id>` (one per line or comma-separated, as the form shows) | `voided` or `no open incident with that id`. **Only on the owner's instruction**: it sends an all-clear to contacts already told. |
| `python -m cli.admin kms check` | **afterme-kms** (owner only; not an on-call action) | `ok: wrapped and unwrapped 32 random bytes`. Anything else: tell the owner. Instructions may show "temporarily unavailable" while the key service is failing; check-ins, I'M SAFE and alerts are not affected |

On a phone the Google Cloud app may not show *Execute with overrides*; open the console in the phone's browser ("desktop site"). Every run is recorded with your Google account name.

## 3. When to press Hold (copy of BETA_PLAN §8, "stop the line")

Press **afterme-oncall-hold-enter** first, then call the owner, when any of these is true:

* a contact may have received a message that should not have been sent (a wrong alert), or two unexplained ones in a week;
* a contact received the **same** message twice for one event;
* someone's instruction text, a link or a code appears in a log, an e-mail subject, a push or a ticket;
* a person saw, or could read, another person's data;
* an escalation message failed for every provider and nobody was told;
* the worker heartbeat or the probe is red and the owner cannot fix it **within 30 minutes**;
* the app crashes on launch for many people (nobody can check in).

When in doubt: **Hold first, questions after.** While in Hold, reminders to people continue; messages to contacts wait; deadlines are moved when it ends.

## 4. What NOT to do

* Do **not** press *hold exit* or *incident void* on your own judgment. Ask the owner; write down the cause first.
* Do **not** "retry" or force anything on an action that is held, and do not touch the database, secrets, keys, Cloud SQL, KMS or IAM.
* Do **not** delete, pause or edit any job, alert, uptime check, scheduler job or secret to make a page stop.
* Do **not** copy log lines, incident ids with names, e-mail addresses or links into chat or tickets; use the id only.
* Do **not** redeploy, restart or roll back anything; that is the owner's call.
* Do **not** ignore an unacknowledged page because "it probably clears": if it is a PAGE, look within 15 minutes.

## 5. Who to call, in this order

1. Owner (above). 2. Backup (above). 3. If neither answers in 15 minutes and a Hold-worthy condition is true: you have pressed Hold already; send a message to both and keep trying every 15 minutes.

Practice: once a month press **afterme-oncall-status** and **afterme-oncall-hold-status** (harmless) so that it is not the first time during a real page.
