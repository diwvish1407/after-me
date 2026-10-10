# AfterMe: the escalation engine, walked through

*Generated from a real run of the test suite (`tests/engine/test_walkthrough.py`) on 2026-10-10; the clock is simulated, everything else is the real system: the HTTP API, the worker process logic, the outbox dispatcher and PostgreSQL.*

The person lives in Asia/Kolkata and checks in daily by 20:00. Their plan: a 3-hour grace period, then Mom is notified; 24 hours after the start, Brother is notified as well.

| When | What happens | State afterwards |
|---|---|---|
| Tue 13 Oct 19:00:00 IST | Account set up: daily check-in by 20:00, grace 3 h, stage 1 notifies Mom, stage 2 (after 24 h) notifies Brother | schedule **active** |
| Tue 13 Oct 19:30:00 IST | **I'M OK** at 19:30 | schedule **active**; next deadline Wed 14 Oct 20:00 |
| Wed 14 Oct 19:00:00 IST | one hour before the deadline | schedule **active**; reminder email queued and sent to the user |
| Wed 14 Oct 20:00:00 IST | **deadline passes**: the worker opens an incident and writes its whole timeline | incident **grace**, nobody told; 'You missed your 8:00 PM check-in' to the user |
| Wed 14 Oct 22:45:00 IST | last-chance reminder (15 minutes before grace ends) | incident **grace**, nobody told |
| Wed 14 Oct 23:00:00 IST | grace ends: **stage 1 runs** | incident **escalating**, nobody told; Mom's message is queued behind the 5-minute settle delay; nothing has left |
| Wed 14 Oct 23:05:00 IST | settle delay over: Mom is emailed, the incident now counts as 'contacts messaged' | incident **escalating**, contacts told; incident_last_chance → the user, contact_alert → Mom, stage_executed → the user |
| Thu 15 Oct 20:05:00 IST | 24 h after the start: **stage 2 runs**, Brother is emailed | incident **escalated**, contacts told; stage_executed → the user, stage_executed → the user, contact_alert → Brother |
| Thu 15 Oct 21:00:00 IST | the user returns and taps I'M OK | incident **escalated**, contacts told; **refused** (`safe_required`): contacts were told, so I'M SAFE is required |
| Thu 15 Oct 21:01:00 IST | password, then **I'M SAFE** | last incident **cancelled** (user_safe); contact_all_clear → Brother, contact_all_clear → Mom, all_clear_confirmation → the user |
| Fri 16 Oct 19:00:00 IST | a day of ticks later | last incident **cancelled** (user_safe); no further contact-facing message for that incident (0 new) |

## Things to notice

* **Nobody is contacted before the grace period ends,** and Mom's email waits five more minutes (the *settle delay*): a check-in in that window cancels it and nobody ever knows.
* **Once a contact has been emailed, I'M OK is no longer enough.** The app is told to use I'M SAFE (which needs the password and sends an all-clear to everyone who was told).
* **The API cannot start any of this.** Incidents, timeline actions and messages are created only by the worker; the database refuses the API role the `INSERT`.
* **Fail-safe.** If anything is uncertain (inconsistent data, an outage, a Hold), the engine does nothing and raises an alert instead of contacting anyone.

