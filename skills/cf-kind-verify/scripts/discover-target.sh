#!/usr/bin/env bash
set -euo pipefail
# discover-target.sh — find which (deployment, container) runs a given image.
#
# Usage: discover-target.sh <image> [--cluster <name>]
#
# Deployment name != image name != container name, and these charts often use a
# bare `app: <name>` label with no `app.kubernetes.io/name`, so `set image` by
# guessed name fails. Instead we walk every pod's containers, match the image
# substring, and map the owning pod back to its Deployment via the ReplicaSet
# ownerRef. Prints one line per match:
#
#   DEPLOYMENT CONTAINER NAMESPACE
#
# so callers can `read DEPLOYMENT CONTAINER NAMESPACE < <(discover-target.sh ...)`.
#
# JSON parsing lives in _discover_target.py

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="cfk8s"
IMAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    -*) echo "discover-target.sh: unknown arg: $1" >&2; exit 2 ;;
    *) IMAGE="$1"; shift ;;
  esac
done

[[ -n "$IMAGE" ]] || { echo "discover-target.sh: usage: discover-target.sh <image> [--cluster <name>]" >&2; exit 2; }

# A single kubectl call (vs. one per pod) keeps this to one allowlist entry.
kubectl get pods,replicasets,deployments -A -o json 2>/dev/null | \
IMAGE="$IMAGE" CLUSTER="$CLUSTER" python3 "$SCRIPT_DIR/_discover_target.py"
