## What and why

<!-- One or two sentences. Link the requirement IDs (e.g. FR-CHK-02) or doc sections. -->

## How it was verified

<!-- Commands run, tests added, manual checks. -->

## Safety and security checklist

- [ ] Every new route is registered in the authorization-matrix policy (tests fail otherwise)
- [ ] Owned resources are queried with the owner's ID; not-owned returns 404
- [ ] Request models forbid unknown fields; nothing client-supplied decides escalation state or time
- [ ] No sensitive data (passwords, tokens, codes, instruction content, contact addresses) in logs, errors, notifications or audit metadata
- [ ] Failure paths are fail-safe (uncertain → don't contact, don't release)
- [ ] Migrations are reviewed, reversible where practical, and grant the right roles
- [ ] Docs updated if behaviour or contracts changed
