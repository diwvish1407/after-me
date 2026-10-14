# AfterMe infrastructure (Google Cloud, Terraform)

Everything needed to stand up **staging** and **production** in Google Cloud `asia-south1`, written before the projects exist. Read [docs/INFRASTRUCTURE.md](../docs/INFRASTRUCTURE.md) for the design; this file is the **bring-up sequence** and the cost estimate.

> **Status.** `terraform fmt -check -recursive` and `terraform validate` pass for `bootstrap`, `envs/staging` and `envs/prod` (Terraform 1.16.3, provider `google` 7.46.1). **Nothing has been planned or applied, and no `gcloud` command in this file has ever been run.** The first apply is where the assumptions listed in [INFRASTRUCTURE §14](../docs/INFRASTRUCTURE.md#14-assumptions-about-google-cloud-that-were-not-verifiable-offline) get checked. If a step fails, paste the error (it contains no secret) back to the assistant.

```
infra/
  terraform/
    bootstrap/            once per project: enable APIs + versioned state bucket (local state)
    envs/staging|prod/    the environment: variables.tf (sizes), terraform.tfvars.example, backend.tf
    modules/              stack (composes all) · network · database · kms · secrets · iam · registry
                          run · edge · monitoring · dns_records · admin_vm
  scripts/                db_bootstrap.sh · add_app_secrets.sh · check_secrets.sh · set_probe_header.sh
                          smoke.sh · verify_client_ip.sh · load_ready.sh · rollback.sh
.github/workflows/        deploy.yml (build, migrate, deploy, smoke) · infra.yml (fmt, validate)
```

**Rules that hold everywhere.** No secret value is ever a Terraform variable, resource attribute or state entry; secrets are added with `gcloud secrets versions add`. No service-account key is created. `terraform.tfvars`, state and `backend.hcl` are git-ignored. Do staging first, completely, then repeat for production.

## Before you start

Install on your machine: `gcloud` (Google Cloud CLI), `terraform` 1.16 or newer, `gh` (GitHub CLI), `uv` (already used for the backend), `openssl`, `curl`. Sign in: `gcloud auth login` and `gcloud auth application-default login`. You need a Google Cloud billing account. **Each numbered step ends with "Paste back"**: what to give the assistant, never a secret.

## 1. Create the projects and link billing

Project ids are global; if `afterme-staging` / `afterme-prod` are taken choose others (they are variables).

```bash
gcloud projects create afterme-staging --name="AfterMe staging"      # add --organization=ORG_ID if you have one
gcloud projects create afterme-prod    --name="AfterMe prod"
gcloud billing accounts list
gcloud billing projects link afterme-staging --billing-account=XXXXXX-XXXXXX-XXXXXX
gcloud billing projects link afterme-prod    --billing-account=XXXXXX-XXXXXX-XXXXXX
# a budget that e-mails you at 80 % of what you expect (see the cost table; edit the amounts)
gcloud billing budgets create --billing-account=XXXXXX-XXXXXX-XXXXXX --display-name=afterme-prod \
  --budget-amount=500USD --threshold-rule=percent=0.8 --threshold-rule=percent=1.0 \
  --filter-projects=projects/afterme-prod
```

Then in the Firebase console, **Add project → choose the existing Google Cloud project** for each (`afterme-staging`, `afterme-prod`), enable Cloud Messaging (HTTP v1) and register the Android apps ([DEPLOYMENT §10](../docs/DEPLOYMENT.md#10-domain-and-email-deliverability) item 4).

**Paste back:** the two project ids and their project numbers (`gcloud projects describe afterme-staging --format='value(projectNumber)'`); your GitHub `OWNER/REPO` (`gh repo view --json nameWithOwner -q .nameWithOwner`) and its numeric id (`gh api repos/OWNER/REPO --jq .id`).

## 2. Enable the APIs and create the state bucket (bootstrap)

Per project (staging now, prod later):

```bash
cd infra/terraform/bootstrap
terraform init
terraform apply -var project_id=afterme-staging       # enables 19 APIs, creates gs://afterme-staging-tfstate (versioned)
terraform output -raw backend_hcl > ../envs/staging/backend.hcl     # bucket + prefix, no secret
```

The bootstrap keeps its own local state (`terraform.tfstate`, git-ignored). Use one **workspace per project** so the two states do not mix: run `terraform workspace new staging` before the staging apply and `terraform workspace new prod` before the prod one. Keep the state files; losing them only costs a `terraform import` of the bucket.

**Paste back:** nothing but "done" (or the error).

## 3. Foundations: network, database, KMS, secret shells, IAM, registry

```bash
cd ../envs/staging
cp terraform.tfvars.example terraform.tfvars           # then edit: project, domains, the two people, GitHub repository
terraform init -backend-config=backend.hcl
# in terraform.tfvars for this step:   admin_vm_enabled = true   admin_vm_members = ["user:you@example.com"]
terraform plan
terraform apply
```

Creates (no Cloud Run, no load balancer yet: `deploy_services = false`): VPC and subnet, private services access, Cloud SQL (10 to 20 minutes), the KMS key ring and key, twelve **empty** secret shells, the service accounts, the Workload Identity pool, Artifact Registry, and the admin VM.

`terraform output` prints what the later steps need. **Paste back (all non-secret):** `database_private_ip`, `database_instance_name`, `kms_key_name`, `artifact_registry`, `workload_identity_provider`, `cicd_service_account`, `project_number`.

## 4. GitHub: Environments and variables (Workload Identity, no keys)

```bash
R=OWNER/REPO
gh api -X PUT repos/$R/environments/staging
gh variable set GCP_PROJECT_ID                 --env staging --repo $R --body afterme-staging
gh variable set GCP_REGION                     --env staging --repo $R --body asia-south1
gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER --env staging --repo $R --body "$(terraform output -raw workload_identity_provider)"
gh variable set GCP_SERVICE_ACCOUNT            --env staging --repo $R --body "$(terraform output -raw cicd_service_account)"
gh variable set API_URL                        --env staging --repo $R --body https://api.staging.afterme.app
```

Production (later, same five variables with the prod values, `API_URL=https://api.afterme.app`): create the environment `production` in **GitHub → Settings → Environments**, add **Required reviewers** (you and the second on-call person) and **Deployment branches: `main` only**.

### GitHub repository settings (part of the security boundary, required)

The Workload Identity provider of each project accepts a GitHub token only if it comes from this repository (its name **and** its numeric id, `github_repository_id`, now required), from `deploy.yml`, and from a job that runs in **that project's GitHub Environment** (`assertion.environment == 'staging'` in afterme-staging, `'production'` in afterme-prod). GitHub's token cannot prove that a tag was cut from `main`, and the workflow's own check runs from the tagged commit, so these settings are what actually stops "push a tag, get the CI service account" (and through it the api service account's KMS and secrets: treat CI as equivalent to it). Set all of them before the first deploy:

| Setting | Where | Value |
|---|---|---|
| Environment `staging`: deployment branches and tags | Settings → Environments → staging → Deployment branches and tags → **Selected branches and tags** | branch `main`, tag `v*`. Nothing else |
| Environment `production`: deployment branches | Settings → Environments → production | **Selected branches**: `main` only; **Required reviewers**: you and the second on-call person; **Prevent self-review** on |
| Branch protection / ruleset for `main` | Settings → Rules → Rulesets → New branch ruleset, target `main` | require a pull request, block force pushes and deletion |
| Tag ruleset for `v*` | Settings → Rules → Rulesets → New **tag** ruleset, target `v*` | **Restrict creations**, **Restrict updates**, **Restrict deletions**; bypass list: only you (repository admin) |
| Environment secrets | none | the deploy needs no GitHub secret: only the five variables above |

With the CLI (the environment rules; the rulesets are easiest in the web UI):

```bash
gh api -X PUT repos/$R/environments/staging --input - <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
gh api -X POST repos/$R/environments/staging/deployment-branch-policies -f name=main -f type=branch
gh api -X POST repos/$R/environments/staging/deployment-branch-policies -f name='v*' -f type=tag
```

Check: `gh api repos/$R/environments/staging/deployment-branch-policies --jq '.branch_policies[] | [.type, .name]'` lists exactly `branch main` and `tag v*`.

**Paste back:** nothing (the values were non-secret and you set them yourself).

## 5. Build the first image

Terraform needs an image to create Cloud Run with. In GitHub: **Actions → deploy → Run workflow**: environment `staging`, tick **build_only**. It builds `backend/Dockerfile`, pushes it and prints the digest (`…/afterme/backend@sha256:…`) in the run summary.

**Paste back:** that image digest reference.

## 6. Database roles (through the admin VM; the database has no public address)

```bash
P=afterme-staging; Z=asia-south1-b
gcloud sql users set-password postgres --instance=afterme-pg-staging --project=$P --prompt-for-password   # store it in your password manager
gcloud compute scp backend/scripts/provision_roles.sql infra/scripts/db_bootstrap.sh afterme-admin-vm:~ \
  --zone=$Z --tunnel-through-iap --project=$P
gcloud compute ssh afterme-admin-vm --zone=$Z --tunnel-through-iap --project=$P
# on the VM:
chmod +x db_bootstrap.sh
./db_bootstrap.sh afterme-staging staging <database_private_ip>        # asks for the postgres password
exit
```

`db_bootstrap.sh` generates the four role passwords in memory, runs `provision_roles.sql` (exit 0; it refuses weak passwords), and stores the four database URLs (`sslmode=require`) as new secret versions. Nothing is printed or written to disk. (`log_statement = none` on the instance means the `ALTER ROLE … PASSWORD` statements are not logged.) Provisioning can be repeated: it also rotates the four passwords.

**Paste back:** the script's last lines (`stored a new version of secret …` ×4) or its error.

## 7. The other secrets

```bash
cd ../../..                                       # repository root
infra/scripts/add_app_secrets.sh afterme-staging k20261012    # jwt-signing-keys, hmac-pepper, probe-token, email-fallback-webhook-secret
```

The kid you pass must equal `jwt_active_kid` in `terraform.tfvars`. Then the three secrets that come from the providers: copy the value to the clipboard and pipe it in (nothing lands in shell history):

```bash
pbpaste | gcloud secrets versions add email-api-key          --project afterme-staging --data-file=-   # Resend API key
pbpaste | gcloud secrets versions add email-webhook-secret   --project afterme-staging --data-file=-   # Resend webhook signing secret whsec_...
pbpaste | gcloud secrets versions add email-fallback-api-key --project afterme-staging --data-file=-   # Postmark server token
```

Resend's webhook secret exists only after you create the webhook (step 11); create the webhook first with a placeholder URL if needed, or come back to this command. Postmark's webhook password is the `email-fallback-webhook-secret` that was generated for you: read it once when you create the webhook (`gcloud secrets versions access latest --secret email-fallback-webhook-secret --project afterme-staging`) and paste it into the webhook URL's Basic auth.

Check:

```bash
infra/scripts/check_secrets.sh afterme-staging        # every line must say ok; reads no value
```

How each value is generated: JWT key = Ed25519 from `backend/scripts/generate_jwt_key.py`; pepper = `secrets.token_urlsafe(48)` (same script); probe token = 64 random characters from `openssl rand`; Postmark password = 48 random characters; the four database passwords = 40 random characters (`db_bootstrap.sh`).

**Paste back:** the output of `check_secrets.sh`.

## 8. Cloud Run, load balancer, monitoring (stage 2)

The API revision is ready only when the database is reachable **and** its schema is not behind the image (at its Alembic head, or ahead of it after a newer release migrated; `/health/ready` is the startup probe), so the **migration job must exist and run before the API service is created**. Edit `terraform.tfvars`: `deploy_services = true`, `image = "<the digest from step 5>"`, and leave `admin_vm_enabled = true` for now.

```bash
cd infra/terraform/envs/staging
# 1. only the migration job (a targeted apply is the documented exception for this one ordering problem)
terraform apply -target='module.stack.module.run[0].google_cloud_run_v2_job.migrate'
gcloud run jobs execute afterme-migrate --project afterme-staging --region asia-south1 --wait
# 2. everything else
terraform apply
```

The migration job runs `alembic upgrade head` as `afterme_owner` (`migration-database-url`) and must finish green. The full apply then creates the API, the worker pool, the jobs and Cloud Scheduler jobs, the load balancer, the monitoring and the dashboard. Verify:

```bash
gcloud run jobs execute afterme-oncall-status --project afterme-staging --region asia-south1 --wait    # python -m cli.admin status
```

(It exits 1 until the worker has beaten once and the probes have started. **Expect a "Hold entered" page during bring-up:** the first worker tick finds no probe yet and enters the ingestion Hold at once; it ends by itself 10 minutes after the uptime check has been delivering probes, step 10.)

**Paste back:** `terraform output dns_records` and `load_balancer_ip`; `uptime_check_id`.

## 9. DNS in Cloudflare and the certificate

Create exactly the records of `terraform output dns_records` (A records for `api.staging.afterme.app` and `staging.afterme.app`, **proxy OFF / grey cloud**; for prod `api.afterme.app` and `afterme.app`; the CAA records only if the zone already has CAA records). Then wait for the certificate:

```bash
gcloud compute ssl-certificates list --global --project afterme-staging --format='table(name,managed.status,managed.domainStatus)'
# ACTIVE for both domains: 15 to 60 minutes after the records resolve (up to a day)
curl -sS -o /dev/null -w '%{http_code}\n' https://api.staging.afterme.app/health/ready     # 200
```

Mail records (SPF, DKIM, return-path, DMARC) come from the Resend and Postmark dashboards, not Terraform: [INFRASTRUCTURE §9](../docs/INFRASTRUCTURE.md#9-dns-and-mail-cloudflare-by-hand). Add the two webhook URLs there (`https://api.staging.afterme.app/webhooks/email/resend` and `/postmark`; delivered, bounced, complained **and** failed/suppressed; tracking off).

**Paste back:** the certificate status line and the `curl` result.

## 10. The uptime check's token

```bash
infra/scripts/set_probe_header.sh afterme-staging "$(cd infra/terraform/envs/staging && terraform output -raw uptime_check_id)"
```

Copies the probe token from Secret Manager into the check's header through the Monitoring API (Terraform never sees it). Then, in a few minutes: `SELECT count(*), max(received_at) FROM ingestion_probes;` grows once a minute (use the admin VM and `psql`, or run `afterme-oncall-status`, which stops reporting a Hold after 10 minutes of fresh probes). **Send the first probe before the workers start**: on first start a worker that has never seen a probe enters a Hold at once ([GAMEDAYS §3](../docs/GAMEDAYS.md), operational note). If the workers started first: that Hold ends by itself 10 minutes after fresh probes.

**Paste back:** `afterme-oncall-status` output (job log) after ten minutes.

## 11. Verify the client-address rule (required)

On staging, with the final load balancer ([INFRASTRUCTURE §7](../docs/INFRASTRUCTURE.md#7-the-client-address-trusted_proxy_hops)):

```bash
infra/scripts/verify_client_ip.sh https://api.staging.afterme.app spoof       # laptop: must PASS (a 429 appears)
infra/scripts/verify_client_ip.sh https://api.staging.afterme.app plain       # phone on mobile data, within a minute: must PASS (401s)
```

**Paste back:** both outputs. If either fails, change `trusted_proxy_hops` in `terraform.tfvars`, `terraform apply`, redeploy (`deploy` workflow), repeat.

## 12. Alerts: verify the path, then page yourself

1. Console → **Monitoring → Alerting → Edit notification channels → SMS**: each number shows "unverified" until you enter the code Google texts to it. Both on-call people do this. **An unverified SMS channel sends nothing and says nothing.**
2. Each person installs the Google Cloud mobile app and enables alert notifications for the project.
3. Page yourself:
   ```bash
   gcloud logging write afterme-alert-test '{"event":"infra.alert_test"}' --payload-type=json --project afterme-staging
   ```
   Within a few minutes **both** people receive the e-mail and the SMS ("PAGE (TEST): alert path test"). Acknowledge it.
4. Page yourself for real once: run **afterme-oncall-hold-enter**; the "Hold entered" page must arrive; then **afterme-oncall-hold-exit**.
5. Test the second person's access: they run **afterme-oncall-status** from the console on their phone ([docs/ONCALL.md](../docs/ONCALL.md)).

**Paste back:** "SMS and e-mail arrived on both phones" or what did not.

## 13. Check the providers and push

```bash
gcloud run jobs execute afterme-admin --project afterme-staging --region asia-south1 --wait \
  --args="--operator,you,email-test,--to,you@example.com"
```

(Console: Cloud Run → Jobs → afterme-admin → Execute with overrides.) It must print `ok: provider=resend message_id=…` in the job log; repeat after breaking nothing, then `push-test --token <FCM token of your phone>`. Then the game days of [docs/GAMEDAYS.md](../docs/GAMEDAYS.md): OPS-01 to OPS-03, then OPS-04 and OPS-05 (they need the admin VM and, for OPS-04, `db_high_availability = true` for the day).

## 14. Close the administration VM, then production

Set `admin_vm_enabled = false` and `terraform apply` (the VM, its NAT and firewall rule are removed). Then repeat steps 2 to 12 for **production** (`envs/prod`, project `afterme-prod`, `api.afterme.app`, `afterme.app`, prod environment variables in GitHub; production deploys use `workflow_dispatch` on `main`). Prod differs only in sizes: regional HA database, 2 workers, deletion protection, the `production` GitHub Environment. Do OPS-05 up to the clone check on prod before the first tester ([BETA_PLAN §3](../docs/BETA_PLAN.md#3-entry-checklist-before-the-first-tester-is-invited)).

## Everyday operations

| Task | How |
|---|---|
| Deploy | tag `vX.Y.Z` → staging automatically; *Run workflow* → production |
| Roll back | `infra/scripts/rollback.sh <project> asia-south1 <previous image@sha256:…>`: the API, the worker pool and every job together; it tries each one, prints what was and was not rolled back and exits 1 if anything was not (re-run it). Works after a migrating release because migrations are expand-only ([DEPLOYMENT §5](../docs/DEPLOYMENT.md)) |
| Key management | Cloud Run job `afterme-kms` (`kms check`, `kms rewrap`, `kms rotate-user`): [DEPLOYMENT §9](../docs/DEPLOYMENT.md#9-runbooks), Key management |
| Rotate a secret | add a version (`gcloud secrets versions add …`), then redeploy; JWT/pepper rotation steps are in [DEPLOYMENT §9](../docs/DEPLOYMENT.md#9-runbooks) (set `hmac_pepper_previous_enabled = true` while rotating the pepper) |
| Rotate the probe token | new version of `probe-token`, redeploy, then `set_probe_header.sh` |
| Change sizes / flags | edit `terraform.tfvars`, `terraform plan`, `terraform apply` |
| Look at the system | Cloud Run jobs `afterme-oncall-*`; dashboard "AfterMe operations" |

## Cost estimate

**Estimates, not quotes.** Monthly, asia-south1, USD at list prices as remembered when this was written (late 2026), INR at ₹85 to ₹90 per USD. Confirm with the Google Cloud Pricing Calculator before relying on them; prices change and sustained-use / committed-use discounts are not included. Network egress is small (mail and push payloads, HTML pages).

| Item | Staging | Production | Note |
|---|---|---|---|
| Cloud SQL PostgreSQL 17 (Enterprise) | **$55–70** (db-custom-1-3840, zonal, 20 GB SSD) | **$190–240** (db-custom-2-7680, **regional HA**, 20 GB SSD, backups) | the biggest line; HA doubles the instance |
| Cloud Run API (1 vCPU, 1 GiB, **CPU always allocated**, min 1) | $50–60 (min 1) | $50–60 + $0–50 for extra instances | `api_cpu_always_allocated = false` saves ≈ $40 per instance once mail goes through the outbox |
| Cloud Run worker pool (1 vCPU, 512 MiB, always on) | $45–50 (×1) | **$90–100** (×2) | second biggest; no cheaper shape is supported for always-on |
| Cloud Run jobs (watchdog every 2 min, maintenance every 15 min, backup check, migrations) | $2–5 | $3–6 | mostly inside the free tier |
| Global external Application Load Balancer (forwarding rules, static IP in use, data) | $18–22 | $20–30 | one per project |
| Cloud KMS (1 key, a few operations, audit logs) | < $1 | $1–2 | DEKs are cached 5 minutes |
| Secret Manager (12 secrets, few accesses) | < $1 | < $1 | |
| Artifact Registry, Cloud Storage (state), Cloud Scheduler (3 jobs: free) | $1–2 | $1–2 | |
| Cloud Logging / Monitoring (30-day logs, uptime checks 130 k a month, 18 policies, metrics) | $0–5 | $2–10 | the first 50 GiB of logs a month are free |
| Admin VM + Cloud NAT (only while provisioning, a day or two) | ≈ $1 | ≈ $1 | `admin_vm_enabled = false` otherwise |
| **Google Cloud total** | **≈ $170–215 (₹14,500–19,500)** | **≈ $370–490 (₹31,500–44,000)** | |
| Resend (primary) | $0 up to 3,000 mails a month, then from $20 | same | invitations, reminders, rare alerts |
| Postmark (fallback) | $0–15 (keep dormant on the free tier; paid plans from $15 for 10,000) | $15 | only used when Resend fails |
| Domain, Cloudflare DNS | ≈ $1 | (shared) | `.app` is about $14 a year |
| Play Console one-off | — | $25 once | |

**Biggest drivers:** (1) Cloud SQL regional HA, (2) always-on CPU: two workers and the API, (3) the load balancer. **Ways to spend less, ranked by safety:** staging on `db-g1-small` and `deploy_services = false` between sessions; turn the API's always-on CPU off after the mail outbox exists; run one worker in staging only. **Do not** save on production HA, the second worker, PITR or the watchdog: they are what the safety promise rests on. SMS and WhatsApp to contacts (roadmap 1.1) would be the main variable cost later; Cloud Monitoring's SMS pages cost nothing extra.
