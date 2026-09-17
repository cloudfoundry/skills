#!/usr/bin/env bash
set -euo pipefail
# verify-status.sh — print per-container health for a deployment's pods.
#
# Usage: verify-status.sh <deployment> [--namespace <ns>] [--cluster <name>]
#   --namespace  default: cf-system
#
# Verify per CONTAINER, not per pod: a pod can be "Running" while a sidecar
# crash-loops. Prints, for each container of each matching pod:
#
#   <container> ready=<t/f> restarts=<n> image=<ref>
#
# restarts=0 on a branch image that ENFORCES required config fields is itself
# proof the chart wiring is correct — that's the signal the model should read.
#
# JSON parsing lives in _status_selector.py / _status_containers.py

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="cf-system"
DEP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --cluster) shift 2 ;;  # accepted for symmetry; kubectl uses the current context
    -*) echo "verify-status.sh: unknown arg: $1" >&2; exit 2 ;;
    *) DEP="$1"; shift ;;
  esac
done

[[ -n "$DEP" ]] || { echo "verify-status.sh: usage: verify-status.sh <deployment> [--namespace <ns>]" >&2; exit 2; }

# Read the deployment's selector matchLabels and turn them into a k1=v1,k2=v2
# string for `kubectl get pod -l`. Exits 1 (matching the old behavior) if the
# deployment is missing or has no selector.
labels="$(
  kubectl -n "$NS" get deployment "$DEP" -o json 2>/dev/null | \
  DEP="$DEP" NS="$NS" python3 "$SCRIPT_DIR/_status_selector.py"
)"

echo "verify-status.sh: deployment/$DEP (ns=$NS) selector=$labels"

# List every container of every matching pod as: <container> ready/restarts/image,
# grouped under a "pod <name>" line — per-container so a crash-looping sidecar in
# an otherwise-Running pod is visible.
kubectl -n "$NS" get pod -l "$labels" -o json 2>/dev/null | \
python3 "$SCRIPT_DIR/_status_containers.py"

echo "verify-status.sh: rollout ->"
kubectl -n "$NS" rollout status deployment/"$DEP" --timeout=5s 2>&1 || true
