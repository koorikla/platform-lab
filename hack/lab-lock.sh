#!/usr/bin/env bash
# One shared lab, many parallel workers: whoever mutates the live hub/workers (pushes to main that Argo applies,
# kubectl writes, Kargo promotions, cluster rebirths) must hold this lock. It is a coordination.k8s.io Lease on the hub,
# so it works for humans and agents alike and survives terminals closing.
#   hack/lab-lock.sh acquire <holder> [ttl-minutes]   (fails if someone else holds an unexpired lock)
#   hack/lab-lock.sh release <holder>
#   hack/lab-lock.sh status
# <holder> should name the work, e.g. "issue-12/alice". An expired lock (ttl passed) may be taken over.
set -euo pipefail
CTX=${CTX:-mgmt} NS=${NS:-default} NAME=lab-lock
k() { kubectl --context "$CTX" -n "$NS" "$@"; }
now() { date -u +%Y-%m-%dT%H:%M:%S.000000Z; }
epoch() { date -u -j -f %Y-%m-%dT%H:%M:%S "${1%%.*}" +%s 2>/dev/null || date -u -d "${1%%.*}" +%s; }

status() {
  k get lease "$NAME" -o jsonpath='{.spec.holderIdentity}{" since "}{.spec.acquireTime}{" ttl "}{.spec.leaseDurationSeconds}{"s\n"}' 2>/dev/null ||
    echo "free"
}

acquire() {
  local holder=$1 ttl=$(( ${2:-120} * 60 )) body
  body=$(printf '{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"name":"%s"},"spec":{"holderIdentity":"%s","leaseDurationSeconds":%d,"acquireTime":"%s","renewTime":"%s"}}' \
    "$NAME" "$holder" "$ttl" "$(now)" "$(now)")
  if k create -f - <<<"$body" >/dev/null 2>&1; then echo "acquired by $holder"; return; fi
  local cur renew dur
  cur=$(k get lease "$NAME" -o jsonpath='{.spec.holderIdentity}')
  if [ "$cur" = "$holder" ]; then k patch lease "$NAME" --type merge -p "{\"spec\":{\"renewTime\":\"$(now)\"}}" >/dev/null; echo "renewed by $holder"; return; fi
  renew=$(k get lease "$NAME" -o jsonpath='{.spec.renewTime}'); dur=$(k get lease "$NAME" -o jsonpath='{.spec.leaseDurationSeconds}')
  if [ $(( $(epoch "$renew") + dur )) -lt "$(date -u +%s)" ]; then
    k replace -f - <<<"$(k get lease "$NAME" -o json | jq --arg h "$holder" --arg t "$(now)" --argjson d "$ttl" \
      '.spec.holderIdentity=$h | .spec.acquireTime=$t | .spec.renewTime=$t | .spec.leaseDurationSeconds=$d')" >/dev/null
    echo "acquired by $holder (took over expired lock from $cur)"; return
  fi
  echo "lab is locked by $cur (renewed $renew, ttl ${dur}s)" >&2; exit 1
}

release() {
  local cur; cur=$(k get lease "$NAME" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
  [ -z "$cur" ] && { echo "already free"; return; }
  [ "$cur" = "$1" ] || { echo "held by $cur, not $1" >&2; exit 1; }
  k delete lease "$NAME" >/dev/null && echo "released by $1"
}

case ${1:-status} in
  acquire) acquire "${2:?holder}" "${3:-}";; release) release "${2:?holder}";; status) status;;
  *) echo "usage: $0 acquire <holder> [ttl-min] | release <holder> | status" >&2; exit 2;;
esac
