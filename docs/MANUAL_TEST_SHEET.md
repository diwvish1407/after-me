# AfterMe — Manual test sheet (devices)

| | |
|---|---|
| **Status** | Draft v0.1 (Phase 10) |
| **Source** | [TEST_PLAN §8](TEST_PLAN.md#8-manual-test-checklist-before-each-betaproduction-release), the Phase 9 → 10 hand-off in [ROADMAP](ROADMAP.md), [SECURITY_REVIEW §10](SECURITY_REVIEW.md#10-what-this-review-could-not-check) |
| **Use** | Copy §1 once per device. Run the cases. Record `P` (pass), `F` (fail, with the ticket), `N` (not applicable, with the reason). Anything that fails gets a severity from [TEST_PLAN §11](TEST_PLAN.md#11-defect-severity) on the spot |
| **Build** | The release candidate only: `prod` flavor from `tool/build_release.sh` for the Play-bound checks, `staging` flavor against staging for the real-time ones. The `adb` cases need a **dev or staging** (debuggable) build |

The cases are written so that a person who has never seen the app can run them. "Expected" is what must happen; anything else is a defect even if it looks harmless.

## 1. Device record (one per device)

| Field | Value |
|---|---|
| Device model, OEM skin and version | |
| Android version / patch level | |
| RAM, storage free | |
| Locale, font size and display size settings | |
| Screen lock / biometrics enrolled | |
| Build (version name+code, flavor), source | |
| Backend (staging/prod) and date | |
| Tester | |

**Minimum matrix:** Pixel (stock, newest Android), Samsung (One UI), one of Xiaomi/Redmi (HyperOS), Oppo or OnePlus (ColorOS); one device with ≤ 3 GB RAM; an Android 8.0 (API 26) emulator. **≥ 3 OEMs** must pass for the closed beta.

## 2. Cases

Severity column = what a failure is, unless the notes say otherwise.

### A. Install, launch, upgrade

| ID | Steps | Expected | Sev |
|---|---|---|---|
| A01 | Fresh install; open | Reaches sign-in without a crash; cold start feels < 2 s on a mid-range device; no permission prompt before it makes sense | S1 if it cannot start |
| A02 | **Intent hardening (dev/staging build, signed in).** `adb shell am start -n <appId>/app.afterme.MainActivity --es route /settings/delete` and `--es cached_engine_id x` and `--ez enable-software-rendering true` | The app opens Home as normal (or the lock screen). It **never** opens the requested route and never crashes | S2 |
| A03 | `adb shell am start -a android.intent.action.VIEW -d "afterme://anything"` and `-d "https://<publicbase>/a/delete"` | Nothing is handled by the app (no deep links in 1.0); at most the browser opens the https page | S3 |
| A04 | Install the previous build, sign in, leave a pending check-in (airplane mode), install the new build over it | Still signed in; the pending check-in is still there and is sent once | S2 |
| A05 | Uninstall, reinstall | Sign-in required; nothing from the earlier install (no stale session, no stale pending record) | S2 |
| A06 | Cold launch from: launcher, recents, a notification tap, "Open" after install | Same result each time; the hand-written activity fragment starts without a black or white flash that lasts more than a second | S3 |

### B. Account and onboarding

| ID | Steps | Expected | Sev |
|---|---|---|---|
| B01 | Register with a new address | Code email within 1 minute; a wrong code is refused with a calm message; resend obeys the interval | S2 |
| B02 | Sign in on a second device | "New device" email arrives; the first device remains signed in | S3 |
| B03 | Forgot password (email link in a mobile browser) | Link opens, new password works, old sessions end | S2 |
| B04 | Run onboarding at largest font and largest display size on the smallest phone | Every step reachable; no clipped or overlapping controls; the primary action is always visible or scrollable | S2 |
| B05 | Deny notification permission at the pre-prompt, then continue | Onboarding finishes; Home shows a gentle banner; Settings explains how to enable | S3 |

### C. Check-in (the product's core)

| ID | Steps | Expected | Sev |
|---|---|---|---|
| C01 | Tap I'M OK online | Confirmation within about a second; Home shows the next due time; History has one entry | S1 if it fails |
| C02 | Airplane mode, tap I'M OK, wait, reconnect | Clearly says it will retry; after reconnection exactly one event is recorded (History) | S1 |
| C03 | Offline tap, then swipe the app away (kill), reopen online | The pending record survives and is sent once | S1 |
| C04 | Pending tap, advance the phone clock 13 h forward and reopen | The old tap is dropped with a notice; nothing wrong is sent | S3 |
| C05 | Change the phone's time zone | Schedule still shows the schedule's own zone; the deadline does not move unless the person changes it in the app | S2 |
| C06 | Set the phone's date a day ahead, check in | Check-in works and the server decides the time (the app does not show a wrong state) | S2 |
| C07 | Let a pre-reminder arrive with the app killed, in Doze (screen off 30 min), with battery saver on, and with the OEM's "restricted/sleeping app" setting | The reminder arrives (note the delay). If it does not on some OEM, record the setting that stops it: this is a documented finding, not a pass | S2 |

### D. Escalation and I'M SAFE (staging, real time, short offsets)

| ID | Steps | Expected | Sev |
|---|---|---|---|
| D01 | Plan: grace 3 h or the shortest allowed, one contact; miss a check-in | Reminder(s) first and only to you; Home moves through its states with calm wording; the contact is told only after grace + settle delay | S1 if the contact is told early |
| D02 | Miss, then I'M OK during grace | Resolves; nobody was told; History shows it | S1 if contacts are told |
| D03 | Miss until the contact is told, then tap I'M OK | Refused with a clear explanation; the app offers I'M SAFE; password asked; all-clear reaches the contact | S1 |
| D04 | Two stages, different contacts (needs a **Premium** test account: free allows one contact; `python -m cli.admin user set-tier <id> premium --reason test`); I'M SAFE after stage 1 | Stage 2 is never sent; both contacts who were told get the all-clear (and only them) | S1 |
| D05 | Instruction released to a contact. A release stage is always **at least 24 h** after the incident starts (`MIN_RELEASE_OFFSET_MINUTES` has a floor of 1440), and the test clock is refused with real providers, so plan this case over **two days**: start the missed check-in on day 1 with the release at a 24 h stage, and observe on day 2 | The email holds a link, no content; page → code → content; after I'M SAFE the page shows nothing | S1 |
| D06 | Operator Hold during an incident ([GAMEDAYS](GAMEDAYS.md)) | The app shows the interruption notice; nothing reaches contacts; after exit deadlines are shifted | S1 |
| D07 | I'M SAFE with a wrong password, then the right one | Wrong: calm error and a retry; right: succeeds; 5 wrong in 15 minutes **on one session**: a calm "try again later" (a rate limit, not an account lock: the lock and its email belong to 10 failed sign-ins) | S2 |

### E. Notifications

| ID | Steps | Expected | Sev |
|---|---|---|---|
| E01 | Permission granted / denied / revoked later (Settings → Apps) | Home and Settings reflect each; no crash; the app asks again only in a sensible place | S3 |
| E02 | Android 13+: first-run prompt wording and timing | A pre-prompt explains why before the system dialog | S3 |
| E03 | Lock screen with "hide sensitive content" on and off | The text is the generic one (no names, no times, no information) either way | **S1** if content or a name shows |
| E04 | Tap a push while the app is killed, backgrounded and foreground | Opens the right screen each time; with the plan editor holding unsaved edits, the guard still asks | S3 |
| E05 | Sign out | The phone stops receiving that account's pushes | S2 |
| E06 | Turn the three channels off one at a time (reminders, incidents, account) | Each switch works; the incident channel is explained as important | S3 |

### F. Privacy and screen protection

| ID | Steps | Expected | Sev |
|---|---|---|---|
| F01 | Open recents with each of: an instruction, the plan, a contact (add/edit/detail), export, password entry, the reauth sheet | The thumbnail is blank; a screenshot is refused; screen recording shows black | **S1** if content is captured |
| F02 | Use the app through a full flow, then paste into any text field | The clipboard holds nothing from the app (only the diagnostic text, and only after tapping "Copy diagnostic text") | S2 |
| F03 | App lock on; background 2 minutes; return | Unlock required; fallback path works; with no biometrics enrolled the lock says how to continue; on a phone with **no screen lock** the option is unavailable and says why | S2 |
| F04 | Reading an instruction | Asks for the password the first time in 5 minutes, then not again | S3 |
| F05 | Export my data | System file picker opens; the file saves and opens; it contains the person's data and no secrets; asks for the password within 60 s | S2 |
| F06 | `adb logcat` for a whole flow (register → check-in → alert → I'M SAFE → export → delete) on a debuggable (dev flavor or `flutter run`) build: a sideloaded staging release build is not debuggable, so `run-as` and full logcat need the dev flavor | No tokens, passwords, email addresses, names, instruction text; error lines name classes only | **S1** if anything leaks |
| F07 | Android Auto Backup / `adb backup` then reinstall | Nothing is restored; sign-in required | S2 |
| F08 | `adb shell run-as <appId>` (debug build): list `shared_prefs`, `files`, `databases` | No access tokens, passwords or instruction text in plain files | S1 |

### G. Account lifecycle and the web pages

| ID | Steps | Expected | Sev |
|---|---|---|---|
| G01 | Delete the account in the app while a contact has been told | Confirmation explains the withdrawn alert; the contact gets "alert withdrawn" (never "is safe"); sign-in fails afterwards | S1 |
| G02 | `/a/delete` in a browser: request the link, open it, enter the password | Same result as G01; the page answers the same for unknown addresses | S2 |
| G03 | Lost-phone page (`/a/login` → `/a/checkin`, `/a/safe`) in Chrome, Samsung Internet, Firefox, Safari (iOS), Gmail's in-app browser | Sign-in works (cookie sticks), I'M OK and I'M SAFE work, sign-out works, the CSRF protection does not break a normal submit | S1 (the lost-phone path is the safety net) |
| G04 | Contact journey: invitation → accept / decline / opt out, in Chrome Android, Safari iOS and Gmail's in-app browser | Pages render; the fragment token survives the in-app browser; opt-out is confirmed | S2 |
| G05 | Portal: link → code → content in the same three browsers | Works; Back button does not re-submit anything; nothing is cached after leaving | S2 |

### H. Email rendering

| ID | Steps | Expected | Sev |
|---|---|---|---|
| H01 | Send each template (invitation, alert, release link, all-clear, withdrawn, reminder, security notices) to Gmail (web, Android, iOS), Outlook, Apple Mail, Yahoo | Layout readable; plain-text part complete; links work; no content in subjects; dark-mode clients readable | S3 (S2 if a link breaks) |
| H02 | Open the raw headers of an alert in Gmail | SPF, DKIM and DMARC pass; not in spam | S2 |
| H03 | Use the opt-out link of an invitation and of an alert | Confirmed on a page; later messages to that address stop | S2 |

### I. Accessibility

| ID | Steps | Expected | Sev |
|---|---|---|---|
| I01 | **TalkBack** full journey: onboarding → check-in → I'M SAFE | Every control is announced with a name and role; focus order follows the visual order; status changes (checked in, pending, incident open) are announced; no unlabeled buttons | S2 |
| I02 | Font size and display size at maximum; the smallest phone | Nothing clipped or unreachable | S2 |
| I03 | Dark mode on every main screen | Readable; contrast acceptable | S3 |
| I04 | Remove animations (Settings → Accessibility) | No pulsing or looping animation remains | S3 |
| I05 | Switch Access or an external keyboard (Tab, Enter) on Home and the I'M SAFE flow | Reachable and operable | S3 |

### J. Network

| ID | Steps | Expected | Sev |
|---|---|---|---|
| J01 | Throttle to 2G / high latency, check in, open Home | Spinners finish; no duplicate events; messages are calm | S2 |
| J02 | Captive portal (hotel Wi-Fi) | The app shows an offline/unreachable message; nothing is sent in clear text | S2 |
| J03 | IPv6-only network; and a VPN | Works | S3 |
| J04 | Backend returns 503 (staging, stop the API for 2 minutes) | Calm retry messaging; check-in is kept as pending; no sign-out | S1 if the tap is lost |

### K. Devices and OEM specifics

| ID | Steps | Expected | Sev |
|---|---|---|---|
| K01 | Xiaomi/HyperOS: Battery saver "restricted" and no autostart; Samsung: "sleeping apps"; Oppo/OnePlus: "battery optimisation" | Record whether reminders still arrive. The in-app help for this OEM (if any) is accurate | S2 if not documented |
| K02 | ≤ 3 GB RAM device: cold start, open every main screen | No ANR; no visible jank on Home; memory warnings do not crash | S2 |
| K03 | Android 8.0 emulator | Fingerprint prompt works (legacy permission), channels created, no crash | S2 |
| K04 | A 16 KB page-size device or emulator image (Android 15+, developer option) | App starts; native libraries load | S1 |
| K05 | Predictive back and edge-to-edge on Android 14/15/16 | Back behaves; nothing hidden behind system bars | S3 |

### L. Copy review

| ID | Steps | Expected | Sev |
|---|---|---|---|
| L01 | Read every user and contact message, error and empty state against [USER_FLOWS §15](USER_FLOWS.md#15-wording-rules) | No "death", no countdown language, no exclamation marks in alerts, "trusted contact" not "beneficiary", an I'M SAFE message never says more than we know | S3 |
| L02 | Read the alert, release, all-clear and withdrawn emails as the **contact** | A stranger can tell what is happening, that it may not mean anything is wrong, who to contact and how to opt out | S2 |

## 3. Sign-off

| Gate | Done |
|---|---|
| ≥ 3 OEMs passed (A–K) with no open S1/S2 | |
| Low-end device and Android 8.0 passed | |
| TalkBack journey (I01) done by a person, not skipped | |
| H01 done for Gmail, Outlook and Apple Mail | |
| G03–G05 done in Chrome, Safari and Gmail in-app | |
| Every failed case has a ticket with a severity | |
| Sheet archived with the build id | |

*Signed:* ________________  *Date:* ________  *Build:* ________________
