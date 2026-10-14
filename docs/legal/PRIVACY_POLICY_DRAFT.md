# AfterMe — Privacy policy (DRAFT for legal review)

> **Not legal advice and not ready to publish.** This draft was written from what the product *actually does* as built through Phase 10 ([SECURITY §14](../SECURITY.md#14-privacy), [DATABASE §5](../DATABASE.md#5-retention), [PLAY_STORE §7–§8](../PLAY_STORE.md)). It must be reviewed and adapted by a qualified lawyer in the launch jurisdiction before it is shown to anyone. Everything in `[square brackets]` is a decision or a fact that only the owner or counsel can supply. The notes in *italics* are for counsel and are removed before publication.

**Effective date:** [date] **Version:** [x]

## 1. Who we are

[Legal name and form of the operator] ("**we**", "**AfterMe**") provides the AfterMe app and the web pages at [production domain]. Contact for privacy questions: [privacy@domain]. [Where required: Data Protection Officer or grievance officer name and address; registered office; EU/UK representative.]

## 2. What AfterMe does, in one paragraph

You choose people (your **trusted contacts**) and information (your **instructions**). You check in on a schedule. If you do not, we first remind you; if you still do not answer, we follow the plan you set: we tell the contacts you chose and, later, let them read the information you chose for each of them. This policy explains what information that takes, who sees it and for how long.

## 3. Information we process

| What | Where it comes from | Why we need it |
|---|---|---|
| **Account:** email address, password (stored only as a one-way hash) | You | To create and secure your account and to send security emails |
| **Profile:** display name, optional phone number, country, time zone, language | You | To run your schedule in your time zone, to show your name to your contacts |
| **Trusted contacts:** name, your relationship label, email address, optional phone number | You | To invite them and to send them what you decided |
| **Instructions:** title and text, the category, which contacts receive which instruction and at which stage | You | To share them with the contacts you chose, only as you configured. The title and text are **encrypted at rest** |
| **Check-ins and plan:** schedule, each check-in (time, whether from the app or the web), the plan and its history, incidents (what happened and when), notices sent | Your use of the app | To do the service and to show you your own history |
| **Device information:** device identifier we generate, platform, app and OS version, language, **push notification token** | Your phone | To deliver reminders, to protect your account, and to diagnose problems |
| **Security records:** sign-ins, password and email changes, account actions; a **one-way hash** of the IP address; the browser or app user agent | Your use | To protect your account and to investigate abuse |
| **Delivery records:** which message went to which recipient, when, and whether it was delivered, bounced or reported as spam (no message text) | Email and push providers | To make sure alerts arrive and to stop sending to addresses that cannot receive |
| **Purchase status** [if billing is enabled] | Google Play | To know whether Premium is active |

We do **not** collect your location, your phone's contact list, photos or files, microphone or camera data, or an advertising identifier. We do not use advertising or third-party analytics. [Crash reports: *none are collected in the current build; update this row if a crash reporter is added, and the Data safety form with it.*]

### Information about your trusted contacts

If you add someone, you give us their name and email address so that we can invite them. We email them to ask whether they agree (you can send the invitation again, within limits), with a clear way to decline or to opt out of all AfterMe messages for ever. Until they accept, we do not send them alerts or information. If someone chooses "never contact me about AfterMe again", or reports a message as unwanted, or an address cannot receive mail at all (a hard bounce), we keep a **one-way hash of that address** so that no AfterMe user can email it again; we cannot read the address back from the hash. (If they only stop the emails of one person, that choice is recorded for that person alone.) When a contact accepts or declines, and when they open a page of ours, we record the time, a one-way hash of their IP address and, for the invitation, which version of the consent text they saw; you can see whether and when a contact opened something you shared.

### Information shown to your contacts

An alert says that you did not check in, when you last did and when you were due, and gives your display name and your email address so that they can recognise you. It never contains the text of your instructions. When something is to be shared with a contact, the same email or a separate one carries a link (never the text); to read an instruction a contact must open that link and enter a **one-time code** that we send to the address you gave. When you check in or confirm you are safe, the link stops working and everyone who was told receives an all-clear.

## 4. Why we may process it, and on what basis

*[Counsel: complete per jurisdiction. Suggested mapping below.]*

| Purpose | GDPR / UK GDPR | India (DPDP Act 2023) |
|---|---|---|
| Providing the service you asked for (account, schedule, reminders, releases) | Contract (Art. 6(1)(b)) | Consent / legitimate use for the service requested |
| Security of accounts and the service, abuse prevention | Legitimate interests (Art. 6(1)(f)) | Legitimate uses |
| Messages to your contacts | Contract with you; legitimate interests; the contact's consent to the invitation | Consent of the data principal for the contact; you confirm you may share their details |
| Legal obligations, claims | Legal obligation / legitimate interests | Legitimate uses |

You are responsible for having the right to give us your contacts' details. Do not add anyone who would not expect to hear from you.

## 5. Who we share it with

| Recipient | Why | What they receive |
|---|---|---|
| **Your trusted contacts** | The purpose of the service | Only what you configured: your name and email in alerts; instructions you assigned to them once released |
| **Hosting provider** [Google Cloud, region …] | To run the service | All data, encrypted in transit; instructions encrypted at rest with keys held in a key-management service |
| **Email delivery provider(s)** [Resend / Postmark: confirm] | To send email | Recipient address, subject, message text (never instruction text) |
| **Google (Firebase Cloud Messaging)** | To deliver push notifications | Your push token, a message type and an incident number, and a short generic notice that names nobody and contains no instruction text, for example "You missed your check-in" or, once contacts have been told, "Your contacts have been notified". Firebase also keeps its own installation identifier for the app |
| **Google Play** | App distribution and [purchases] | As described in Google's terms |
| **Authorities** | Where the law requires | The minimum required |

We do not sell personal data and we do not share it for advertising. *[Counsel: list processors by name and country once chosen; add transfer mechanisms (SCCs/adequacy) where data leaves the region.]*

## 6. Security, and an honest limit

We use TLS for every connection, encrypt instruction text at rest with a separate key per person wrapped by a key-management service, hash passwords with a modern memory-hard algorithm, limit what each of our own components can do, and keep audit records of security-relevant actions. Our instruction text is **not end-to-end encrypted**: the service must be able to decrypt it itself in order to release it to your contacts when your plan says so, and our staff are bound by access controls and audit records but are technically able to administer the system. We tell you this plainly because it matters to your choices.

## 7. How long we keep it

| Data | Kept for |
|---|---|
| Account, profile, contacts, instructions, plan | Until you delete them or your account |
| Check-in history | 400 days, then deleted |
| Incident history and releases | Life of the account |
| Delivery records | 90 days |
| Security (audit) records: sign-ins, changes, who did what and when, with an account number and a one-way hash of the IP address, **no name or email** | [1 year, set by configuration: *counsel to confirm*]. They are **kept in this pseudonymous form after an account is deleted** until that period ends |
| Sessions and one-time tokens | Removed 30 days after they expire or are revoked |
| Backups | Up to 35 days; deleted data leaves backups as they expire |
| Address hashes of people who opted out or complained | As long as needed to honour the opt-out |
| **Deleted accounts** | Access stops at once; the encryption key for your instructions is destroyed at once; the account's records are erased 30 days later. What remains: the pseudonymous security records above, and the one-way address hashes of anyone who opted out or whose address bounced |

## 8. Your choices and rights

- **Access and copy:** *Settings → Privacy and data → Export my data* gives you a file with your account, contacts, instructions, plan and your check-in, incident and activity history (long lists are capped). It does not include device and security records: write to us for those.
- **Correction:** edit your profile, contacts, instructions and plan in the app.
- **Deletion:** *Settings → Privacy and data → Delete account* or the page [domain]/a/delete (works without the app, with an emailed link and your password).
- **Contacts:** anyone you add can decline, withdraw, or opt out of all AfterMe messages from any email.
- **Withdrawing consent, objecting, complaints:** write to [privacy@domain]. You may complain to your data-protection authority [name].
- **Children:** AfterMe is for people 18 and over and is not directed at children. If you believe a child has an account, tell us and we will delete it.

*[Counsel: add regional sections (EU/UK, India, US states) and any required wording on automated decision-making: the plan is configured by you, not decided by us.]*

## 9. Cookies on our web pages

The check-in, deletion and contact pages use **only strictly necessary cookies**: a short-lived sign-in cookie for the web check-in pages (about an hour), a session cookie for the contact page (about an hour), and a security token that protects forms. No analytics or advertising cookies are used.

## 10. Changes

We will tell you in the app or by email before a material change takes effect. The version and date are at the top.

## 11. Open points for counsel (remove before publication)

1. Operator identity, registered office, grievance/DPO details and the lawful basis per market (PRD D3).
2. **Processors and countries:** hosting, email provider(s), FCM: complete when chosen (PRD D12/D13, Phase 8 owner actions).
3. **Crash reporting:** none today; the Play Data safety draft still lists crash logs as collected. Align the form and this policy with reality before submission.
4. Retention of audit records (PRD D10) and of backups.
5. Whether instruction text may be stored in a different region from the account, and what that means for the transfer wording.
6. How to describe our staff's technical ability to administer the system truthfully but proportionately (§6).
7. Whether the beta uses a **separate or the same** database as production, and what happens to beta accounts at launch ([BETA_PLAN §10](../BETA_PLAN.md#10-decisions-for-the-owner)); testers need to be told before the beta starts.
8. **Key management:** the build can only wrap keys with a locally held key; the cloud key-management adapter does not exist yet and production refuses the local one. Section 6 describes the intended production state: confirm it is true before publishing.
9. Phone numbers (yours and a contact's) are stored but nothing sends SMS or WhatsApp in 1.0; devices (platform, app and OS version, language) have no automatic deletion yet.
10. Server request logs (route, status, latency, a request id, never a query string) and hashed rate-limit keys exist and are not listed above: decide whether to list them.
11. The wording for deceased-person situations is deliberately absent from the product ([USER_FLOWS §15](../USER_FLOWS.md#15-wording-rules)); counsel to confirm that nothing in the policy or terms needs to refer to it.
