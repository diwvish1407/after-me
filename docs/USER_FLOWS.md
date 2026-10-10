# AfterMe — User Flows & Experience

| | |
|---|---|
| **Status** | Draft v0.1 — awaiting product-owner approval |
| **Related** | [PRD](PRD.md) · [API_SPEC](API_SPEC.md) · [ESCALATION_ENGINE §14](ESCALATION_ENGINE.md#14-worked-example-the-t0t8-lifecycle) |

---

## 1. Design language

### 1.1 Feel
Calm, trustworthy, premium, human, serious without being grim. Think of a thoughtful insurance letter written by a friend, not a bank dashboard and not a panic button.

| Do | Don't |
|---|---|
| Generous whitespace, one primary action per screen | Dense dashboards, charts, gamification |
| Soft, warm neutrals + one calm accent | Alarm red, black/funeral palettes, skulls, candles, cemeteries |
| Always say *what happens next and when* | Vague states ("Processing…") |
| Plain words, short sentences | Jargon ("payload", "trigger", "dead man's switch") |
| Subtle motion (state changes, check-in confirmation) | Decorative or looping animation; respect "reduce motion" |

### 1.2 Starting tokens (validated for WCAG AA contrast in Phase 2)

| Token | Light | Dark | Use |
|---|---|---|---|
| `bg` | `#F7F5F2` | `#121718` | App background (warm off-white) |
| `surface` | `#FFFFFF` | `#1B2224` | Cards, sheets |
| `text` | `#1F2A30` | `#E8ECEC` | Primary text |
| `textMuted` | `#5B6770` | `#A9B4B8` | Secondary text |
| `primary` | `#1F6F6B` | `#5FB3AD` | Calm teal: primary actions, I'M OK |
| `ok` | `#2E7D5B` | `#6CC39B` | Checked in / healthy |
| `attention` | `#9A6412` | `#E3B263` | Due soon / grace period |
| `escalation` | `#A4472F` | `#E58C74` | Contacts notified (muted brick, not alarm red) |
| `border` | `#E3DED7` | `#2C3538` | Dividers |

**Derived tokens (added in Phase 1).** The app builds its Material 3 colour scheme explicitly from the tokens above plus these:

| Token | Light | Dark | Use |
|---|---|---|---|
| `onPrimary` | `#FFFFFF` | `#121718` | Text/icons on filled `primary`, `ok`, `attention`, `escalation` |
| `outline` | `#737E85` | `#7F8B90` | Boundaries of interactive components (text fields, outlined buttons), ≥ 3:1 |
| `primaryContainer` | `#E4EEED` | `#273C3D` | Info banners, selected navigation indicator |
| `okContainer` | `#E6EFEB` | `#2A3F39` | Tinted status background |
| `attentionContainer` | `#F3ECE3` | `#3F3C2F` | Tinted status background |
| `escalationContainer` | `#F4E9E6` | `#3F3532` | Tinted status background |

**Contrast (verified in Phase 1).** `mobile/test/app/theme/contrast_test.dart` checks WCAG 2.x ratios in both themes; every base token above passed unchanged. `text` and `textMuted` on `bg`/`surface`, `primary`/`onPrimary`, and `ok`/`attention`/`escalation` **as text** on `bg`/`surface` are all ≥ 4.5:1 (lowest: light `ok`/`attention` on `bg`, 4.59:1). On the tinted containers the status colours are used only for icons and accents (≥ 3:1); text on containers always uses `text`.

Status is **never** colour-only: always an icon + a text label.

### 1.3 Typography and components
- A bundled humanist sans (e.g. Inter or Source Sans 3, OFL-licensed), with no runtime font downloads. Body 16 sp, line height 1.4; titles 22/28/34 sp; the check-in button label 24 sp semibold.
- Core components: `CheckInButton` (≥ 160 dp, haptic, states: idle / sending / success / pending / disabled), `StatusHeader`, `PlanStatusCard`, `Timeline`, `ContactRow` + status chip, `InstructionCard`, `Banner` (info / attention / escalation), `EmptyState`, `ConfirmSheet`, `ReauthSheet`, `StageEditor`, `TimeField`.

### 1.4 Accessibility
TalkBack labels and logical focus order; 48 dp minimum targets; text scaling to 200% without truncating key information (layouts reflow); AA contrast; focus moves to the result after an action (e.g. "Checked in. Next check-in tomorrow at 8 PM."); no information conveyed only by colour, motion or haptics.

## 2. Information architecture

```
Bottom navigation:  Home · People · Instructions · Plan · Settings

Home          status, I'M OK / I'M SAFE, next check-in, plan readiness, recent activity
People        contacts list → contact detail → add/edit
Instructions  by category → instruction detail → create/edit (recipients + stage)
Plan          schedule · grace period · stages (timeline preview) · incident history
Settings      profile · security · notifications · timezone · language · subscription ·
              activity · privacy · terms · export · delete account · help · about
```

## 3. Onboarding (target: a working plan in under 5 minutes)

| # | Screen | Content | Time |
|---|---|---|---|
| 1 | **Welcome** (3 short cards, skippable) | "Prepare today for what someone may need tomorrow." · "Check in with one tap. If you don't, the people you choose are told." · "You decide who gets what, and when. You can stop it anytime." · Disclaimer line: *Not an emergency service.* | 20 s |
| 2 | **Create account** | Name, email, password (show/hide, strength hint). Timezone auto-detected and shown ("Asia/Kolkata — change"). Terms + privacy consent; 18+ confirmation. | 45 s |
| 3 | **Enter code** | 6-digit code sent to email; paste support; resend in 60 s; "Wrong email?" | 30 s |
| 4 | **Your first trusted contact** | "Who should we tell if you don't check in?" Name, relationship, email; *Pick from phone* (system picker). Explains they'll get an invitation to accept. | 45 s |
| 5 | **Check-in schedule** | "Check in every **day** by **8:00 PM**." Big defaults; change interval and time; reminder 1 h before. | 20 s |
| 6 | **Your plan** | Preset *Standard* is pre-filled: grace 3 h → notify the contact. A plain-language timeline preview: *"If you miss 8:00 PM: we remind you. At 11:00 PM, Mom is notified."* Edit is optional. | 30 s |
| 7 | **First instruction** (optional) | Starter templates: *Who to call first · Home & keys · Pets · Work handover · Where my documents are · Insurance*. Pick the release stage. "Skip for now" is prominent. | 0–60 s |
| 8 | **Stay protected** | Turn on app lock (biometric/device PIN). Allow notifications (Android 13+ prompt with a pre-explanation). Battery-optimisation tip for aggressive OEMs. | 30 s |
| 9 | **You're set** | Activates the schedule. "Your plan is active. Mom has been invited; we'll let you know when she accepts." → Home. | 10 s |

Rules:
- Progress is saved after each step. Quitting and returning resumes the flow.
- Nothing except steps 2–3 and 5 is mandatory to reach Home. Readiness issues then appear on Home as a short checklist.
- No step asks for information it doesn't immediately use.

*Implementation notes (Phase 2, Android; updated in Phase 3).* Step 4 uses the real contacts API since Phase 3: saving creates the contact and the server queues the invitation email (limits: free plan 1 contact; a duplicate or your own address is explained on the email field; the step can be skipped). Since Phase 5, step 6 saves the plan through `GET/PUT /v1/plan` (`If-Match`; the preset replaces only stage 1 and keeps any later stages, so choosing it can never delete a stage; the grace choices follow the server's rules, so a free account sees 3 h, 6 h, 12 h and 1 day and 1 h / 2 h appear only where custom delays are allowed). Since Phase 6, step 7 saves the first instruction through `POST /v1/instructions`: the same create flow as the Instructions tab (§9), started from one of the six examples (*Who to call first*, *Home and keys*, *Pets*, *Work handover*, *Where my documents are*, *Insurance*) or *Write your own*, with the contact just added ticked. The times offered are the plan's stages that run at least 24 hours after a missed check-in and, because the *Standard* preset has none, 1, 2 and 3 days as times to add: choosing one adds a stage at that time to the plan (telling the people chosen for it) when the instruction is saved, in the same step and under the same password if check-ins are already on (none is asked during onboarding). The Phase 2 "Preview" notice no longer exists. Since Phase 4, step 5 saves the schedule through the API (`PUT /v1/checkin/schedule`, `If-Match`) and step 9 asks the server to activate it. "Pick from phone" uses the system contact picker (no `READ_CONTACTS` permission). Step 5 is the only step after sign-up that cannot be skipped. Step 9 turns the schedule on only when the server accepts it (at least one live contact, and a plan with a stage that notifies someone); otherwise it says what is missing (`no_contacts`, `no_stages`, `stage_empty`), offers the step that fixes it (contact first), and Home shows the checklist. On an account that is already active, Home shows a persistent attention banner for `no_contacts`, `no_stages` and `stage_empty` (§4). Opened again from the Plan tab or that banner while check-ins are on, step 6 asks for the password before saving a changed plan (§10). Progress stores only the step name, a completed flag and an opaque account id; the password and the code are never persisted.

## 4. Home screen states

| State | Header | Main action | Below |
|---|---|---|---|
| **Not active** | "Let's finish your plan" | Checklist (contact, schedule, plan) | — |
| **Active** | ✓ "You're checked in" (ok) · "Good evening, Diwakar" | **I'M OK** (always enabled; checking in early is fine) | Next check-in "Tomorrow · 8:00 PM"; Plan card (2 contacts ✓, 4 instructions ✓, Escalation active); Last check-in "Today · 7:31 PM" |
| **Due soon** (within the reminder lead) | ◔ "Check-in due at 8:00 PM — in 45 min" (attention) | **I'M OK** | as above |
| **Grace** (missed, nobody contacted) | ⚠ "You missed your 8:00 PM check-in" (attention) · "Mom will be notified at **11:00 PM** unless you check in." | **I'M OK** | Timeline of what happens next |
| **Escalating / escalated** | ● "Your contacts have been notified" (escalation) · "Mom was notified at 11:00 PM. Brother will receive *House emergency* tomorrow at 8:00 PM." | **I'M SAFE** | Full timeline incl. views ("Brother viewed at 8:20 PM") |
| **Pending check-in** | "Not received yet — we'll keep trying" | Retry | Explains that success shows only once confirmed |
| **Offline** | Banner: "Offline — showing last known status" | I'M OK (queues as pending) | — |

Readiness banners (one at a time, highest priority first): **nobody would be told** (check-ins are on, but no live contact, no stage, or a stage that tells no one; owner decision 2026-10-10) → contact declined/bounced → contact pending → notifications off → timezone mismatch → battery optimisation. The first is persistent and not dismissible: a safety net with a gap must not look like a working one. Its one action opens the step that fixes it (add a trusted contact, else review the plan).

*Implementation notes (Phase 4).* Home reads `GET /v1/home` and layers the pending-check-in and offline states on top. **Due soon** and **Overdue** are decided by comparing the server's `next_due_at` with the phone's clock corrected by the server-time offset (never the phone's clock alone). **Overdue** (the deadline has passed but the aggregate does not report an incident yet) never claims "you're checked in" and keeps I'M OK enabled. Grace and Escalating arrive with Phase 5/7; until then a non-null `incident` or an unknown status shows a neutral placeholder. Offline with no status yet still lets I'M OK be tapped and queued. The battery-optimisation banner is not built. `recent_activity` is parsed but not shown yet (Settings → Activity, Phase 7).

*Implementation note (Phase 5 follow-up).* The "nobody would be told" banner shows while the status is Active, Due soon or Overdue and `readiness.issues` has `no_contacts`, `no_stages` or `stage_empty` (contact first). It sits above the readiness banner and the status header, and never replaces them or I'M OK. It is not shown while check-ins are off (the checklist says it), during an incident (the plan is read-only) or for a status the app does not know. Copy: "You have no trusted contact. If you miss a check-in, nobody is told." → *Add a trusted contact* (contact step); "Your plan has no stage. If you miss a check-in, nobody is told." / "A stage in your plan has nobody to tell, so it wouldn't reach anyone." → *Review your plan* (plan step). It is kept to two lines so I'M OK stays on the first screen of a small phone. It goes when Home reads the aggregate again after the fix. Note that `stage_empty` is raised when **any** stage has nobody switched on, while activation needs only one stage that tells someone: a plan whose second stage lost its contact keeps working but shows the banner.

## 5. Check-in (I'M OK)

```
Tap I'M OK
  → button shows "Sending…" (haptic)
  → 200: animate ✓ "Checked in", announce "Next check-in tomorrow at 8:00 PM"
         (if an incident was resolved: "Welcome back. No one was contacted.")
  → network/5xx/503: "Not received yet — retrying" (same Idempotency-Key, backoff, retry on resume)
  → 409 safe_required: open the I'M SAFE flow (§7)
  → 401: silent refresh; if that fails → "Please sign in to check in" (+ web check-in hint)
  → a tap that is still unconfirmed after 12 hours is dropped, not sent: "Your earlier check-in
    wasn't received" (Got it) and the person taps I'M OK again
```

The UI **never** shows success before the server confirms.

*Implementation notes (Phase 4).* An unconfirmed tap is kept in secure storage with its idempotency key and re-sent with that same key: with backoff while the app is open (5 s, 15 s, 30 s, 1 min, 2 min, then every 5 min), on app resume, and after the process was killed. `429` keeps the tap and says it will be sent again after `Retry-After`; `426` and a `401` that survives a refresh also keep it. `409 safe_required` shows a placeholder until the I'M SAFE flow exists (Phase 7) and drops the record, because nothing was recorded. Any other `4xx` drops the record. A tap that arrives late is stamped by the server at receipt, so the app does not send a tap that is **more than 12 hours old** (owner decision, 2026-10-10; ESCALATION_ENGINE §9.1): when the record is restored (start, resume, after sign-in) and before every retry it is dropped, nothing is sent with its key, and Home shows an attention banner "Your earlier check-in wasn't received" ("You tapped I'M OK yesterday at 11:30 AM, but it never reached us and is too old to count. Please tap I'M OK again.", time in the profile timezone) with a "Got it" button. I'M OK stays enabled; a new tap has a new key and clears the notice. Exactly 12 hours is still sent; a phone clock that moved back never drops a tap. The notice is not stored: after a restart it is gone.

## 6. Missed check-in (the user's experience)

| When | User sees / receives |
|---|---|
| 1 h before | Push: "Check-in due at 8:00 PM" |
| Deadline (incident opens) | Push + email: "You missed your 8:00 PM check-in. Tap I'M OK. Mom will be notified at 11:00 PM." Home switches to **Grace**. |
| Midpoint | Push: "Still waiting for your check-in. Mom will be notified at 11:00 PM." |
| 15 min before stage 1 | Push + email: "Mom will be notified in 15 minutes." |
| Stage executes | Push + email: "Mom has been notified. If you're safe, tap I'M SAFE." |
| 1 h before a release | Push + email: "In 1 hour, 1 instruction will be shared with Brother. Tap I'M SAFE to stop." |

Android notification visibility is **private**: the lock screen shows a generic public version ("AfterMe — check-in reminder") unless the user allows details.

## 7. I'M SAFE (after contacts were messaged)

```
Tap I'M SAFE
  → ReauthSheet: "For your security, enter your password" (forgot-password link)
  → ConfirmSheet:
       "We'll tell Mom and Brother you're safe."
       "Information shared with Brother will no longer be available.
        Brother viewed 'House emergency' at 8:20 PM — that can't be undone."
       [Confirm I'm safe]
  → 200: "All clear sent to Mom and Brother. Your next check-in is tomorrow at 8:00 PM."
```

The same flow is available on the web at `/a/checkin` (lost phone).

## 8. Trusted contacts

| Flow | Steps |
|---|---|
| **Add** | Name · relationship (chips + Other) · email · phone (optional) → Save → "Invitation sent to mom@…" → row shows **Pending** |
| **Status chips** | Pending (invited) · Accepted ✓ · Declined · Opted out · Email bounced. Each has a one-line explanation and the next action (resend / edit email / remove). |
| **Detail** | Stages where notified; instructions they receive; invitation history; *Resend invitation* (limited); *Edit*; *Remove* |
| **Remove** | Confirm: "Mom will no longer be notified and won't receive 2 instructions." |
| **Limits** | Free tier: at 1 contact, "Add contact" shows a Premium sheet (when billing is live) |

*Implementation notes (Phase 3, Android).*
- **People tab.** Rows show the name, the relationship (the free text for *Other*), a status chip and a one-line explanation, in the order the server returns (priority, then creation). The chip always carries an icon **and** a word and is read out as "Status: Pending". Pull to refresh; calm loading and error states with *Try again*. Empty state: "Who should know if you can't be reached?" with *Add contact*.
- **Status wording.** Pending ("Waiting for them to accept."), Accepted, Declined ("They said no, so we won't contact them."), Opted out ("They asked us not to contact them."), Email could not be delivered ("We couldn't deliver the invitation to this address."). Each has a next action on the detail page (resend, fix the email, remove or add someone else).
- **Readiness hint** (People tab only; Home keeps its checklist): shown when nobody has accepted yet, when the plan depends on someone who has not accepted, or when contacts declined, opted out or bounced. Unreachable contacts come first, as in §4.
- **Add / edit.** Name, relationship chips (Mother, Father, Parent, Spouse, Partner, Sibling, Child, Relative, Friend, Neighbor, Employer, Colleague, Other; *Other* asks for an optional description of up to 40 characters), email, optional phone in international format, and *Pick from my contacts* (system picker, no `READ_CONTACTS`). Add says "We will email them an invitation they must accept"; saving opens the contact, which shows **Pending**. Editing the email warns that a new invitation is sent to the new address and that they must accept again; the server resets the status.
- **Detail.** Status, explanation and next action; email and phone; invitation history (last sent, how many times, accepted); *Resend invitation* (works while pending or after a bounce; off with the reason for accepted, declined and opted-out contacts; after a rate limit it says when to try again); *Edit*; *Remove* behind a confirmation sheet ("Mom will no longer be notified."; instructions are mentioned once they exist).
- **Free-plan limit.** At the limit *Add contact* opens a sheet: "The free plan allows 1 trusted contact. Adding more is part of Premium." with *Close* only (billing does not exist yet, so there is no purchase action). The server stays authoritative: a `plan_limit_reached` answer opens the same sheet.

*Step-up (Phase 5 follow-up; extended in Phase 6).* While check-ins are on, removing a contact who is in a plan stage **or who receives an active instruction**, or changing that contact's email, asks for the password (SECURITY §7); for someone who only receives instructions the sheet says "Removing someone who receives your instructions needs your password because it changes who sees them.": the sheet says "Removing a trusted contact from your plan needs your password because it changes who is told." / "Changing the email address of someone in your plan needs your password because it changes who is told." Closing the sheet changes nothing and shows no error; the same request is sent again once after the password. A contact in no stage, other edits, and everything while check-ins are off never ask. There is no switch for `is_active` in the app yet.

## 9. Instructions

| Flow | Steps |
|---|---|
| **List** | Grouped by category; each card: title, recipients (avatars/initials), stage ("Day 2"), active/inactive |
| **Create** | Category → title → body (multi-line, autosave draft in memory only) → **Who receives this?** (contacts) → **When?** (choose a stage that is ≥ 24 h; shown as "If you haven't checked in for 2 days") → Save |
| **Digital Accounts** | Inline guidance: "Don't paste passwords. Say where they can be found (for example, your password manager's emergency access)." |
| **View/edit** | FLAG_SECURE; shows "Shared with Brother · Stage 2 (after 24 h)"; toggle active; delete with confirmation |
| **Empty state** | Starter templates (same as onboarding) |

*Implementation notes (Phase 6, Android).* The list shows summaries only (no text), grouped by category with a filter; a card has the title, an Active/Inactive chip (icon and word), the recipients' initials and "Mom: After 1 day" (the plan's own offset), and a gentle note for a recipient who has not accepted ("Sam hasn't accepted yet.") or cannot be reached. Create/edit: category, title (1-120), text (1-20,000 characters, plain text, counted as code points), **Who receives this?** (several; somebody who has not accepted is allowed), **When?** (the plan's stages at least 24 h out, "If you haven't checked in for 2 days", **and the times of 1, 2 and 3 days that the plan has no stage for yet: choosing one adds that stage on Save, as one plan save and then the instruction; if the instruction is then refused the plan keeps the stage and the retry reuses it**; one time for everybody or one per person). With a plan that has no stage to follow or no room for another, the form says so and offers *Review your plan*; the instruction can still be saved with nobody to receive it. The free plan holds two stages: a time that would need a third is refused with "Nothing was changed." Recipients are optional: an instruction can be saved and kept for yourself ("Not shared with anyone yet"). Digital Accounts shows the guidance of FR-INS-07. *Start from an example* fills the title and a skeleton (four examples for each of nine categories; examples only, never real data). What is typed is kept in memory only and dropped on save, on *Start over* and at sign-out. Detail: text, "Stage 2: after 1 day" per person, an Active switch, Edit, and Delete behind a confirmation ("It will no longer be shared with anyone, and this can't be undone."). Free plan: at 3 instructions *Add instruction* opens "More instructions are part of Premium" with *Close* only; a `plan_limit_reached` answer opens the same sheet. While check-ins are on, creating an instruction with recipients, changing its recipients, switching off or deleting one that has recipients, asks for the password ("Changing who receives this needs your password because it decides who sees it." / "Switching this off or deleting it needs your password because it changes what is shared."), once for the whole save, and the same request is sent once; text and category edits and switching on never ask. Every screen that shows or edits content, the list titles included, is `FLAG_SECURE`.

## 10. Plan

| Section | UI |
|---|---|
| **Schedule** | "Check in every [1 day] by [8:00 PM]" · reminder · timezone (from profile) |
| **Grace period** | "If you miss a check-in, we'll remind you for [3 hours] before anyone is contacted." |
| **Stages** | Vertical timeline: Stage 1 · "After 3 hours" · Notify: Mom · Releases: — ; Stage 2 · "After 1 day" · Notify: Brother · Releases: House emergency → Brother. Add stage (tier limit); reorder via offsets; remove (blocked if releases are assigned, with an explanation). |
| **Preview** | "If you miss tomorrow's 8:00 PM check-in…" a fully worked timeline with real times |
| **History** | Past incidents: date, outcome (resolved in grace / cancelled / …), who was contacted |
| During an incident | Plan and schedule are read-only, with the banner "Check in first to make changes." |

*Implementation note (Phase 5, Android).* The Plan tab reads the real plan (`GET /v1/plan`): the grace period, the stages with contact names resolved from the contacts list, and the worked preview. It is read-only until the plan editor of Phase 7; "Set up your plan" opens the onboarding plan step, and after saving the app returns to Home, not to the tab. Loading, a retryable error and pull-to-refresh are handled; the server's own message text is never shown. The incident timeline and the history are Phase 7. Saving a changed plan while check-ins are on asks for the password ("Changing your plan needs your password because it decides who is told."); the same plan is sent again once. An identical plan, or any save while check-ins are off, never asks.

## 11. Settings

- **Profile:** name, phone, country, language, timezone (with a device-mismatch suggestion).
  *(Phase 2: language shows English only; the timezone suggestion appears when the phone's zone differs from the profile.)*
- **Check-ins (Phase 4):** *Check-in schedule* (interval 1, 2, 3 or 7 days, time, reminder 0/30/60/120/240 min; activate; deactivating, or making the interval longer while check-ins are on, needs the password) and *Check-in history* (date and time in the profile timezone, from the app or the web).
- **Security:** app lock on/off + timeout; change password; change email; active sessions (revoke); log out everywhere.
- **Notifications:** system permission status; email reminders are always on for incident-related messages (explained).
- **Subscription:** tier, limits and usage; manage via Google Play.
- **Activity:** user-visible audit feed.
- **Privacy & data:** privacy policy, terms, export my data (re-auth), delete account (re-auth + type DELETE; explains the effects and the 30-day purge).
- **Help & about:** FAQ, contact support, version, open-source licences.

## 12. Trusted contact (recipient) journeys

### 12.1 Invitation

```
Email "Diwakar added you as a trusted contact on AfterMe"
  → /c/open#token → /c/invite
      Who: Diwakar (diwakar@example.com)
      What it means: you may get an email if Diwakar misses a check-in;
                     Diwakar may have prepared information for you, viewable securely then.
      No app needed. You can stop at any time.
      [Accept]  [Decline]    (Never contact me about AfterMe again)
  → Accepted: "Thank you. You don't need to do anything now."
```

### 12.2 Alert → release → all-clear

```
Alert email (no content) ──▶ (maybe) Release email "Diwakar left information for you"
   └─▶ /c/open#token → "We'll send a code to d•••@gmail.com" → code → view
         Shows: who it's from, when they last checked in, each instruction (title + body, plain text),
         "Diwakar chose to share this with you if they hadn't checked in for 24 hours."
         Print-friendly. No download, no share buttons.
All-clear email ──▶ portal now shows "This information is no longer available. Diwakar has checked in."
```

### 12.3 Opt-out
Every email has *"Don't want these emails?"* → `/c/optout` with the choice "Stop emails from Diwakar's AfterMe" or "Never contact me about AfterMe again". After opt-out the user sees **Opted out** with an explanation.

## 13. Message copy (1.0 templates)

Tone: calm, specific, kind. Always say who, what happened, what happens next, and how to stop it. Times include the day; contact emails also show the timezone. Pronouns default to **they**.

### 13.1 To the user (push titles / bodies; emails mirror them)

| Template | Title | Body |
|---|---|---|
| `checkin_pre_reminder` | Check-in due at 8:00 PM | Tap to let AfterMe know you're OK. |
| `incident_missed` | You missed your 8:00 PM check-in | Tap I'M OK. Mom will be notified at 11:00 PM if we don't hear from you. |
| `incident_midpoint` | Still waiting for your check-in | Mom will be notified at 11:00 PM. |
| `incident_last_chance` | Mom will be notified in 15 minutes | Tap to check in now. |
| `incident_delayed` | We gave you more time | We had an interruption. Open AfterMe and check in. *(Email: "Mom will be notified at 11:30 PM unless you check in.")* Sent when a stage was overdue because our service was interrupted, and has been put back. |
| `stage_executed` | Mom has been notified | If you're safe, open AfterMe and tap I'M SAFE. |
| `release_final_warning` | In 1 hour, 1 instruction will be shared with Brother | Tap I'M SAFE to stop it. |
| `all_clear_confirmation` | All clear sent | Mom and Brother know you're safe. |
| `contact_accepted` | Mom accepted your invitation | They'll be notified if you miss a check-in. |
| `contact_bounced` | We couldn't reach Mom | Check their email address in People. |

### 13.2 To contacts (email)

**Invitation** · *Subject:* Diwakar added you as a trusted contact on AfterMe
> Hi Mom,
> Diwakar (diwakar@example.com) uses AfterMe to check in regularly, and has asked you to be one of their trusted contacts.
> **What this means:** if Diwakar misses a check-in and doesn't respond to our reminders, we may email you so you can try to reach them. Diwakar may also have prepared information for you, which you could view securely at that time.
> You don't need to install anything. **[Accept]** · [Decline]
> AfterMe is not an emergency service.

**Alert** · *Subject:* Diwakar hasn't checked in
> Hi Mom,
> Diwakar asked us to let you know if they miss a check-in on AfterMe. Their last check-in was **Tuesday 14 Oct, 7:30 PM (India Standard Time)**. They were due by 8:00 PM on Wednesday and haven't responded to our reminders.
> This doesn't necessarily mean anything is wrong. Phones get lost and batteries run out. You may want to try reaching Diwakar or someone close to them.
> If you believe someone is in danger, contact your local emergency services.
> We'll email you when Diwakar checks in.

**Release** · *Subject:* Diwakar left information for you
> Hi Brother,
> Diwakar prepared some information for you in case they couldn't be reached, and chose to share it if they hadn't checked in for 24 hours.
> **[View securely]** For your security, we'll send a one-time code to this email address. This link expires on 14 Nov 2026.

**All-clear** · *Subject:* Diwakar has checked in. All clear.
> Good news: Diwakar checked in on AfterMe at 9:01 PM and confirmed they're safe. No action is needed.
> Any information shared with you during this time is no longer available.

**Alert that carries a release** · *Subject:* Diwakar hasn't checked in
> The alert above, and: Diwakar also prepared some information for you in case they couldn't be reached, and chose to share it with you now. **View it securely:** *link*. For your security we'll send a one-time code to this email address. The link works until *date*.

**One-time code** · *Subject:* Your AfterMe code
> Your code is **482913**. It expires in 10 minutes. If you didn't request it, you can ignore this email.

Every contact email footer: who sent it and why · opt-out link · abuse contact · "AfterMe is not an emergency service."

## 14. Error and empty states

| Situation | Message pattern |
|---|---|
| No connection | "You're offline. Your check-in will be sent when you're back online." |
| Server error | "Something went wrong on our side. Your data is safe. Try again in a moment." |
| Validation | Inline, field-level, specific ("Choose a time at least 24 hours after a missed check-in for sharing instructions.") |
| Rate limited | "Too many attempts. Try again in 10 minutes." |
| Session expired | "Please sign in again." Lost phone? → "You can also check in at <domain>/a/checkin." |
| Upgrade required | "Please update AfterMe to keep your plan running." → Play Store |
| Empty contacts | "Who should know if you can't be reached?" + Add contact |
| Empty instructions | Starter templates |

## 15. Wording rules

| Say | Avoid |
|---|---|
| missed check-in | death, died, deceased, passed away |
| trusted contact | beneficiary, heir, next of kin (legal term) |
| share / release information | unlock secrets, reveal |
| stage, after 1 day | trigger, payload, fire |
| "We'll remind you first" | "Countdown", ticking clocks |
| "This doesn't necessarily mean anything is wrong" | Alarmist language, exclamation marks |
