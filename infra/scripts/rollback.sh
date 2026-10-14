#!/usr/bin/env bash
# Roll the API, the worker pool and every job back to an earlier image DIGEST, together.
#
#   infra/scripts/rollback.sh <project-id> <region> <image@sha256:...>
#
# The schema stays as migrated. That works because every migration is expand-only (additive;
# drops and renames ship one release later: docs/DEPLOYMENT.md §5) and because /health/ready
# accepts a schema that is AHEAD of the image (a revision the image does not know) while it
# refuses one that is behind. The previous API image therefore becomes ready on the newer schema.
#
# Every resource is attempted even when an earlier one fails: stopping half-way would leave the
# worker on one release and the API on another without saying so. At the end the script prints
# what was and was not rolled back and exits non-zero if anything failed (re-run it: updating a
# resource to the image it already has is harmless).
#
# Find the previous digest in the last successful deploy run's summary, or:
#   gcloud run revisions list --service afterme-api --region <region> --project <p>
#   gcloud run revisions describe <revision> --region <r> --project <p> --format='value(spec.containers[0].image)'
set -uo pipefail
project="${1:?project}"; region="${2:?region}"; image="${3:?image@sha256:...}"
case "$image" in *@sha256:*) ;; *) echo "pass an image digest reference (name@sha256:...)" >&2; exit 2;; esac

# Keep in step with deploy.yml and infra/terraform/modules/run (cli_jobs, kms job).
JOBS=(afterme-maintenance afterme-migrate afterme-status-check afterme-admin afterme-kms
      afterme-oncall-status afterme-oncall-hold-status afterme-oncall-hold-enter afterme-oncall-hold-exit)

done_list=()
failed_list=()

attempt() {
  local what="$1"; shift
  echo "--> ${what}"
  if "$@" --project "$project" --region "$region" --image "$image" --quiet; then
    done_list+=("$what")
  else
    echo "::error::rollback of ${what} FAILED" >&2
    failed_list+=("$what")
  fi
}

# The API first: it is what people reach. Its startup probe is /health/ready.
attempt "service afterme-api" gcloud run services update afterme-api
attempt "worker pool afterme-worker" gcloud beta run worker-pools update afterme-worker
for job in "${JOBS[@]}"; do
  attempt "job ${job}" gcloud run jobs update "$job"
done

echo
echo "Rolled back to ${image}:"
for item in "${done_list[@]+"${done_list[@]}"}"; do echo "  ok      ${item}"; done
for item in "${failed_list[@]+"${failed_list[@]}"}"; do echo "  FAILED  ${item}"; done

if [ "${#failed_list[@]}" -gt 0 ]; then
  echo "NOT everything was rolled back (${#failed_list[@]} failed). The release is MIXED: fix the cause and re-run this script." >&2
  exit 1
fi
echo "Everything was rolled back."
