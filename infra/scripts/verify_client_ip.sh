#!/usr/bin/env bash
# Check AFTERME_TRUSTED_PROXY_HOPS against the real front end. Run it against STAGING before the
# first user, and again after any change to the load balancer. docs/INFRASTRUCTURE.md section 7.
#
#   infra/scripts/verify_client_ip.sh https://api.staging.afterme.app spoof
#   infra/scripts/verify_client_ip.sh https://api.staging.afterme.app plain    # from a SECOND network
#
# It sends WRONG-token probes only. Those spend a separate budget (10 a minute per client network)
# and never touch the budget of the real monitor.
#
# spoof : 13 requests, each with a different forged X-Forwarded-For.
#         Correct hop count   -> forged values are ignored, the client is you, the 11th answer is 429.
#         Hop count too HIGH  -> forged values are believed, you never reach 429  => FAIL (clients choose their address).
# plain : 3 requests from a different network (a phone on mobile data). Run `plain` AFTER `spoof`
#         within one minute, from the other network: it must answer 401, not 429.
#         429 means both networks share one bucket => hop count too LOW (everybody is "the load balancer").
set -euo pipefail
base="${1:?usage: verify_client_ip.sh <https://api...> <spoof|plain>}"
mode="${2:?spoof or plain}"
code() { curl -sS -o /dev/null -m 10 -w '%{http_code}' -X POST -H 'X-Probe-Token: wrong-on-purpose-0000000000000000' "$@" "$base/internal/probe"; }

case "$mode" in
  spoof)
    got429=0
    for i in $(seq 1 13); do
      c="$(code -H "X-Forwarded-For: 203.0.113.$i")"; echo "request $i -> $c"
      [ "$c" = "429" ] && got429=1
    done
    if [ "$got429" = 1 ]; then echo "PASS: forged X-Forwarded-For values are ignored"; else echo "FAIL: forged addresses were believed (TRUSTED_PROXY_HOPS too high)"; exit 1; fi
    ;;
  plain)
    for i in 1 2 3; do c="$(code)"; echo "request $i -> $c"; [ "$c" = "401" ] || { echo "FAIL: expected 401 from a fresh network, got $c (TRUSTED_PROXY_HOPS too low: all clients share one address)"; exit 1; }; done
    echo "PASS: this network has its own bucket"
    ;;
  *) echo "mode: spoof or plain" >&2; exit 2 ;;
esac
