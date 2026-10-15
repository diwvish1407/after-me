# AfterMe — Release runbook (Google Play)

| | |
|---|---|
| **Status** | v1.0 (Phase 13). Written for the owner, who is also the operator and on call |
| **Related** | [PLAY_STORE](PLAY_STORE.md) (what to enter in Play Console) · [BETA_PLAN](BETA_PLAN.md) · [ONCALL](ONCALL.md) · [DEPLOYMENT §5.1, §8](DEPLOYMENT.md) · [INFRASTRUCTURE](INFRASTRUCTURE.md) |

The order of a release is: **reviewer account ready → closed test (12 × 14) → production access → signed build → internal track → production, staged → the first 48 hours.** Play gives no "undo" (§6): every step is designed so that stopping is always possible and going back is never needed.

---

## 1. Before the first submission

### 1.1 What must already be true

PLAY_STORE §10 "Owner actions" up to and including the production backend (deployed, alerts tested, restore tested, Hold rehearsed), the legal pages final (`LEGAL_DOCUMENTS_FINAL=true` after counsel), `support@afterme.app` read daily.

### 1.2 The reviewer (demo) account

Play's reviewers sign in with credentials you give them (PLAY_STORE §6.1). The account is made by an operator command that runs **as the API database role with the KMS identity** (it seals two sample instructions), exactly like the `kms` commands; in staging and production it refuses any other database role.

```bash
# On a terminal that has the API's environment (a generated password is printed ONCE, only to a
# terminal; where stdout is a log the command refuses and wants --password-env):
python -m cli.admin --operator <you> reviewer-account create \
  --email play-review@afterme.app --contact-email review-inbox@afterme.app \
  --reason "Play review 1.0.0"
python -m cli.admin --operator <you> reviewer-account reset <user_id>
```

* `--contact-email` must be **our own inbox**. A public mail domain (gmail.com, outlook.com, …) is refused unless `--allow-public-contact` (a typo there would point real alerts at a stranger); an address on the suppression list, or a contact row that declined, opted out or bounced, is refused rather than overridden.
* `create` refuses an address that already has an account; `reset` acts only on an account that `create` made (an `operator.reviewer_account` audit row names it) and that is active.
* `reset`: new password, every session ended, Premium, the profile, the one contact, the two-stage plan, the two samples and the daily schedule restored; whatever the reviewer added is removed the way the app removes it. Running it twice gives the same state.
* `reset` **refuses while an incident is open**. Close it deliberately first with `python -m cli.admin incident void <id>` (worker role: the `afterme-admin` job; our inbox receives the withdrawn alert), then reset.
* The password is never logged and never in the audit row. Store it in the password manager and in Play Console → App access.
* A deleted or suspended reviewer account is not reset: make a new one with another address (e.g. `play-review+2@afterme.app`).

### 1.3 In production: the `afterme-reviewer-account` job

Cloud Run writes stdout to Cloud Logging, so in production the password is **never printed**: it comes from the secret `reviewer-password`.

1. Generate a password in the password manager (20+ characters).
2. Add it as a secret version without it touching your shell history:
   `gcloud secrets versions add reviewer-password --project afterme-prod --data-file=/dev/stdin` then paste, Enter, Ctrl-D.
3. Enable the job once: `reviewer_account_job = true` in the env's `terraform.tfvars`, `terraform apply` (it is off by default because a job bound to an empty secret cannot run).
4. Create: Console → Cloud Run → Jobs → **afterme-reviewer-account** → *Execute with overrides*, arguments
   `create`, `--email`, `play-review@afterme.app`, `--contact-email`, `review-inbox@afterme.app`, `--reason`, `Play review 1.0.0`, `--password-env`, `AFTERME_REVIEWER_PASSWORD`.
   Or: `gcloud run jobs execute afterme-reviewer-account --region asia-south1 --wait --args="create,--email,play-review@afterme.app,--contact-email,review-inbox@afterme.app,--reason,Play review 1.0.0,--password-env,AFTERME_REVIEWER_PASSWORD"` (no commas inside a value).
5. Read the execution's log: `created: user_id=… login=…` and `password: from AFTERME_REVIEWER_PASSWORD (not printed)`. Keep the user id with the password.
6. Before every submission: `--args="reset,<user_id>,--password-env,AFTERME_REVIEWER_PASSWORD"` (to rotate the password, add a new secret version first). Exit code 2 = refused, nothing changed; the log says why.

The command is fixed up to `reviewer-account`, so the top-level `--operator` cannot be passed in the job: the audit row records the container's user, and Cloud Run records the Google account that executed it.

### 1.4 Living with the reviewer account

The account is an ordinary one with an active daily schedule (20:00 India time). If nobody checks in, the engine opens an incident, tells our review inbox after 3 hours and shares the samples with it after 24 hours. That is the honest demo, and it shows up in `status` and `beta-report`: **verdict "expected: reviewer account"** in the beta log. While a review is pending you may keep the account in its calm state by checking in once a day at `https://afterme.app/a/checkin` (it is our demo account); the App access text describes both states. Never point its contact at anyone outside the team.

## 2. Applying for production access

A personal account must run a **closed test with ≥ 12 testers opted in for 14 continuous days** before Play Console offers *Apply for production*. Play then asks about the test; answer from the beta log ([BETA_PLAN §6, §9](BETA_PLAN.md#9-what-the-beta-must-show-production-acceptance)), truthfully and specifically:

| Play asks (in substance) | Prepare from |
|---|---|
| How did you recruit testers? How easy was it? | BETA_PLAN §5: friends, family, colleagues, community groups; the 18+ rule; the consent message (§11) |
| How engaged were they; what did they do? | `beta-report` weekly metrics: active testers, check-ins per day (app/web), missed check-ins, rehearsed escalations, I'M SAFE time-to-all-clear |
| What feedback did you get, and how did you collect it? | The feedback form and the beta log: themes, counts by severity |
| What did you change because of it? | The defects fixed and copy changes, with the build numbers |
| Who is the app for; what value does it give them? | PRD §1–§4 (adults who want a plan if they are unexpectedly unreachable) |
| How many installs do you expect in the first year? | Your honest estimate (India first) |
| How do you know it is ready? | BETA_PLAN §9 acceptance: zero wrongful contact messages with every escalated incident reviewed, zero open S1/S2, crash-free ≥ 99.5%, ANR under Play's threshold, the game days passed |

Never claim testers, numbers or changes that the beta log does not show. If the application is refused, Play says why; fix that and re-apply (another test period may be required).

## 3. The signed build

### 3.1 The upload key (once)

Play App Signing holds the **app signing key**; we hold only the **upload key**. Create it on your own machine, never in the repository:

```bash
keytool -genkeypair -v -keystore upload-keystore.jks -storetype PKCS12 \
  -keyalg RSA -keysize 4096 -validity 10000 -alias upload
keytool -list -v -keystore upload-keystore.jks -alias upload    # note the SHA256 fingerprint
```

* Store the `.jks` and both passwords in the **password manager**, plus one **offline copy** (encrypted USB in a safe place). Never commit it (`.gitignore` excludes `*.jks` and `key.properties`), never email it, never put it in a ticket.
* GitHub → Settings → Environments → **`release`**: required reviewer = you; deployment rules: branch `main` and tags `app-v*`. Secrets (enter them with `gh` so they never enter your shell history: `gh secret set NAME --env release` reads the value from stdin):
  * `ANDROID_UPLOAD_KEYSTORE_BASE64` = `base64 -i upload-keystore.jks | tr -d '\n'` (macOS) / `base64 -w0 upload-keystore.jks` (Linux)
  * `ANDROID_UPLOAD_KEYSTORE_PASSWORD`, `ANDROID_UPLOAD_KEY_ALIAS` (`upload`), `ANDROID_UPLOAD_KEY_PASSWORD`
  * variable (not secret) `ANDROID_UPLOAD_CERT_SHA256` = the fingerprint, once Play Console shows it (Setup → App signing → Upload key certificate). The workflow then refuses a bundle signed with any other key.
* The first bundle you upload enrols its key as the upload key (Play generates the app signing key). **Lost or leaked upload key:** Play Console → Setup → App signing → *Request upload key reset* (takes days; the app signing key is unaffected). Rotate the GitHub secrets the same day.
* Local builds: `mobile/android/key.properties` as in `mobile/README.md` → "Release signing".

### 3.2 Production configuration

`mobile/config/prod.json` is committed with placeholders (`*.invalid`, empty Firebase values). Commit the real values (`https://api.afterme.app`, `https://afterme.app`, the production Firebase **client** configuration, which is public configuration, not a secret) before the first release; `release.yml` refuses placeholders.

### 3.3 Building

`.github/workflows/release.yml`, on a tag **`app-v<versionName>`** (e.g. `app-v1.0.0`) or *Run workflow* on `main`:

1. refuses a commit not on `main`, and a tag that does not match `mobile/pubspec.yaml`'s `version` (`1.0.0+12` → tag `app-v1.0.0`, versionCode 12);
2. refuses a placeholder `config/prod.json`;
3. writes the upload key from the Environment's secrets into `mobile/android/` (never echoed) and runs `mobile/tool/build_release.sh --appbundle` (prod flavor, obfuscation, split debug info, the merged-manifest check; no `--allow-debug-signing`, so a missing key fails);
4. refuses a bundle signed with the debug key, or (when the variable is set) with any key but ours;
5. wipes the key in an `always()` step;
6. keeps three **private workflow artifacts for 90 days**: the AAB, the R8 `mapping.txt`, the Dart symbols. Copy the mapping and symbols into the release record (password manager attachment or a private bucket): they expire, and they are the only way to read an obfuscated stack trace of that version. In a public repository artifacts are downloadable by signed-in users: keep the repository private, or move the mapping and symbols elsewhere at once.

Actions are pinned by commit SHA; the build uses Flutter 3.47.6 like `mobile.yml`.

### 3.4 Internal track (by hand)

Play Console → Testing → **Internal testing** → Create release → upload the AAB artifact → release notes (`mobile/store/whatsnew/`) → Review → Roll out. Then:

* App bundle explorer: **16 KB page size** compatible; target SDK 36; no new permission.
* Upload the R8 mapping (App bundle explorer → the version → Downloads → *Upload ReTrace mapping file*) so Android vitals traces are readable.
* The **pre-launch report**: no crash, no ANR; address accessibility warnings or record why not.
* Install from the internal track on your own phone: sign in, check in, open an instruction, I'M SAFE path on a rehearsal account.

Promote the same release to **Closed testing** (the beta) or **Production**; never rebuild for promotion.

### 3.5 Why publishing is manual (and how to automate it later)

`release.yml` does not upload to Play. Keyless publishing is possible: Workload Identity Federation → a dedicated service account (e.g. `afterme-play-publisher`) invited in Play Console with *Release to testing tracks* only → the Play Developer API (`edits.insert`, `edits.bundles.upload`, `edits.tracks.update` with `track=internal`, `edits.commit`) using a short-lived access token with the `androidpublisher` scope. No JSON key is ever needed. It is **not built** because it needs infrastructure that does not exist yet (a pool provider accepting `release.yml` on `app-v*` tags in a `play-internal` Environment, the service account, the Play Console grant), it cannot be tested here, and the very first upload of a new app must be made by hand anyway. Until then the manual upload doubles as the moment you read the pre-launch report. Never use a long-lived service-account key for this.

### 3.6 Production: staged rollout

Play Console → Production → Create release → *add from library* (the bundle already tested) → release notes → **Staged rollout 10%** → Review → Start rollout.

| Step | Wait at least | Go on only if |
|---|---|---|
| 10% | 24 h | no halt criterion below; every escalated incident since the start reviewed |
| 25% | 24 h | same |
| 50% | 48 h | same, and support/complaints at their normal level |
| 100% | — | same |

**Halt criteria (any one):**

* any **S1** (TEST_PLAN §11), or any **wrongful contact message** (BETA_PLAN §7);
* **crash-free sessions < 99.5%** for the new version, or a crash on launch for a device family;
* **user-perceived ANR rate above Play's bad-behaviour threshold** (0.47% overall, 8% on any single device model; check Play's current values) or crash rate above 1.09%;
* a **spike in support mail, reviews or complaints** that you cannot explain within the hour;
* a **Hold** that is not explained (any Hold during a rollout is investigated before the next step).

**Halt:** Play Console → Production → Releases → the release → **Halt rollout**. New users stop getting the version; people who already have it keep it (§6). If people may be harmed by contacts being messaged, **enter Hold first** (`afterme-oncall-hold-enter`), then halt. **Resume:** the same page → **Resume rollout** (same or a different percentage), only with a written cause and a fix or an explanation. Change the percentage with **Update rollout**.

## 4. Versioning, tags and release notes

* `mobile/pubspec.yaml` `version: <major.minor.patch>+<versionCode>`. **versionCode only ever increases** (Play rejects a reused or lower one); increase it on every upload, including internal builds. versionName is semver.
* Tag the released commit **`app-v<versionName>`** (on `main`; backend deploys use `v*`, a different namespace). One versionName per production release; a rebuild of the same name for an internal-only fix bumps versionCode and is tagged only if it ships.
* Release notes: plain, true, ≤ 500 characters, `mobile/store/whatsnew/`; the same copy rules as the listing (no death wording, no "end-to-end", no purchase claims in 1.0). Write what changed for a person, not for a developer.
* Keep a release record per version: versionName/code, commit, AAB SHA-256 (in the workflow summary), upload certificate fingerprint, mapping and symbols, rollout dates and the 48-hour review.

## 5. The first 48 hours

Every day for the first two days after a production release (and after each rollout step), in this order:

1. **Android vitals** (Play Console → Quality): crash rate, ANR rate, by device and Android version; compare with the previous version.
2. **`python -m cli.admin status`** (job `afterme-oncall-status`): nothing paging, no warnings you cannot explain.
3. **`python -m cli.admin beta-report --since <launch day>`**: review **every escalated incident** as in BETA_PLAN §7 and write the verdict. Reviewer-account incidents are "expected: reviewer account".
4. **Reviews and support inbox:** read every review and every mail; answer reviews **within 48 hours**, plainly, without asking for personal data in public.
5. **Email deliverability:** the provider dashboards (bounces, complaints, the fallback provider used?) and the `notify` alerts.
6. **Sign-ups vs verifications:** a gap means codes are not arriving (from `beta-report` metrics or the provider's logs).
7. **Policy and Console messages:** Play Console inbox, policy status, the developer email.

Then write the review, using this template, into the release record:

```text
Post-launch review: AfterMe <versionName> (<versionCode>), <date>, rollout <n>%
Vitals:        crash-free sessions ___%  ANR ___%  (previous version ___ / ___)
Engine:        status clean? ___   Holds: ___ (each explained?)
Incidents:     escalated ___  reviewed ___  verdicts: expected ___  S3 ___  wrongful ___
Delivery:      sent ___  bounced ___  complaints ___  fallback used? ___
Accounts:      sign-ups ___  verified ___  deletions ___
Support:       mails ___  reviews ___ (avg ___)  answered within 48 h? ___
Decision:      continue to ___% / hold at ___% / halt   because: ___
Follow-ups:    ___
```

## 6. What you cannot undo, and the emergency lever

* **Play has no rollback.** A version that reached a phone stays there. Halting stops new installs of it; to undo, ship a **fixed build with a higher versionCode** (the old code rebuilt is fine) through internal testing, then production. Keep the previous release's tag buildable.
* **`MIN_CLIENT_VERSION` (the `426 upgrade_required` gate)** is the only server-side lever over old apps: the API refuses `/v1` requests from older versions and the app shows a blocking *Update AfterMe* screen. **It is dangerous:** a person who cannot update yet (a staged rollout has not reached them, no data, an old phone) **cannot check in from the app**, and the engine keeps counting, so the gate can *cause* missed check-ins and wrongful alerts. Rules:
  * raise it only to a version that has been at **100% rollout for several days**, and only for a security or data-integrity reason;
  * **never during an incident or a Hold**, never as a way to stop a crash (halt the rollout instead);
  * the **web check-in `https://afterme.app/a/checkin` (and `/a/safe`) is not gated** and must work before you raise it; tell users about it in the update email;
  * after raising it, watch missed check-ins and incidents hourly for a day; if they rise, enter Hold and lower it again.
  It is the Terraform variable `min_client_version` (`AFTERME_MIN_CLIENT_VERSION`), applied by a deploy.

## 7. Every year, and always

* **Target API deadline every August** (around 31 August): new apps and updates must target the then-required API level. Plan the update in **June**; Play usually allows an extension to 1 November on request, do not rely on it.
* **Policy monitoring:** the Play Console inbox and the developer email weekly; Policy Center announcements; re-check **Data safety** (PLAY_STORE §7) and the **content rating** whenever data handling changes (Play Billing in 1.1, a crash reporter, SMS/WhatsApp).
* The reviewer account: `reset` before every submission; renew it if its audit record ages out (audit retention, default 365 days), then `reset` refuses and you `create` a new one.
* The upload key: check yearly that the offline copy opens.
