#!/usr/bin/env bash
set -euo pipefail
# prereqs.sh — verify the local toolchain and cf-on-kind cluster are ready.
#
# Usage: prereqs.sh [--cluster <name>]
#   --cluster  kind cluster name (default: cfk8s)
#
# Exit 0 when everything is ready. On the first failure, exit non-zero and
# print to stderr what is missing and (where useful) how to fix it. The model
# reads that message and decides whether to offer a bootstrap (see lifecycle.sh)
# or to stop and hand back to the user.

CLUSTER="cfk8s"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    *) echo "prereqs.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "prereqs.sh: $*" >&2; exit 1; }

# 1. Required tools on PATH. `cf` and `helm` are checked but only warned about:
#    redeploy works without them; only test discovery / helm flows need them.
missing=()
for t in docker kind kubectl; do
  command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  fail "missing required tool(s): ${missing[*]} (install and re-run)"
fi
for t in cf helm; do
  command -v "$t" >/dev/null 2>&1 || echo "prereqs.sh: note: '$t' not on PATH — some flows (tests / helm) will be limited" >&2
done

# 2. docker daemon reachable.
docker info >/dev/null 2>&1 || fail "docker daemon not reachable (is Docker running?)"

# 3. kind cluster exists.
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  fail "kind cluster '$CLUSTER' not found — cluster is down. Bring it up with: lifecycle.sh up --kind-dir <path>"
fi

# 4. kubectl context points at the cluster.
ctx="$(kubectl config current-context 2>/dev/null || true)"
if [[ "$ctx" != "kind-$CLUSTER" ]]; then
  fail "kubectl context is '$ctx', expected 'kind-$CLUSTER' — run: kubectl config use-context kind-$CLUSTER"
fi

# 5. At least one Ready node. Check the STATUS column (field 2) exactly, rather
#    than a substring match — "Ready" vs "NotReady"/"Ready,SchedulingDisabled".
if ! kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -qx "Ready"; then
  fail "no Ready nodes in cluster '$CLUSTER' — cluster may be starting or unhealthy"
fi

echo "prereqs.sh: OK — docker up, kind cluster '$CLUSTER' present, context kind-$CLUSTER, node(s) Ready"
