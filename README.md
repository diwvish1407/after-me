# AfterMe

*If you can't answer, your instructions can.*

AfterMe is a personal contingency-planning app. Check in on your own schedule. If you miss a check-in and don't respond to reminders, AfterMe follows the plan you set in advance: it notifies the trusted contacts you chose and, later, shares the specific information you prepared for each of them. Confirming "I'M SAFE" stops everything and sends an all-clear.

## Status

**Phase 1 — development foundation: built, review in progress.**
Backend (`backend/`, FastAPI + PostgreSQL): signup with emailed code, login, refresh rotation, sessions, re-authentication, audit log, rate limits. Mobile (`mobile/`, Flutter Android): flavors, API client, secure storage, router, design system. Run instructions: [backend/README.md](backend/README.md), [mobile/README.md](mobile/README.md).
Design documents: Phase 0, approved.

## Documentation

| Document | What it covers |
|---|---|
| [PRD](docs/PRD.md) | Product vision, scope, requirements, rules, tiers, **decisions needed** |
| [ESCALATION_ENGINE](docs/ESCALATION_ENGINE.md) | The safety-critical core: invariants, deadline math, incident lifecycle, worker, safety gate, Hold, failure scenarios |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | System design, repo layout, backend and mobile architecture, technology decisions |
| [DATABASE](docs/DATABASE.md) | PostgreSQL schema, deletion, retention, roles and grants, migrations |
| [API_SPEC](docs/API_SPEC.md) | REST API contract, errors, web routes, rate limits |
| [SECURITY](docs/SECURITY.md) | Threat model, controls, cryptography, privacy, audit |
| [USER_FLOWS](docs/USER_FLOWS.md) | Design language, onboarding, screens, message copy |
| [TEST_PLAN](docs/TEST_PLAN.md) | Test strategy, engine and security tests, release criteria |
| [DEPLOYMENT](docs/DEPLOYMENT.md) | Environments, local setup, hosting, CI/CD, monitoring, runbooks |
| [PLAY_STORE](docs/PLAY_STORE.md) | Play requirements, listing, Data safety, timeline |
| [ROADMAP](docs/ROADMAP.md) | Phases 1–13 with exit criteria |

## Core principle

**Fail-safe, not fail-trigger.** If the system is uncertain, it does not contact anyone and does not release anything. The backend is authoritative; the app never decides whether an escalation happens.
