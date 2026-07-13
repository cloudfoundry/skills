#!/usr/bin/env bash
set -euo pipefail
# redeploy.sh — build a CF component image from source, load it into the local
# cf-on-kind cluster, and roll the running deployment onto it.
#
# Usage:
#   redeploy.sh <image> [options]
#
#   <image>            bake target / image name (e.g. syslog-agent, gorouter)
#
# Options:
#   --src <path>          local-path context for the src/ subdir  (default: $PWD/src)
#   --releases-dir <path> dir containing <component>/docker-bake.hcl to build from
#                         (default: $PWD — i.e. run from cf-k8s-releases/<component>)
#   --namespace <ns>      namespace of the target deployment      (default: cf-system)
#   --cluster <name>      kind cluster name                        (default: cfk8s)
#   --tag <tag>           image tag to load & deploy               (default: latest)
#
# Notes baked in from real runs (see PLAN.md "Key facts"):
#  - Build runs from cf-k8s-releases/<component>/ where the Dockerfile + bake
#    file live — NOT the release repo root (kind-deployment's releases/ is empty).
#  - The bake `src` context resolves to <release-repo>/src; the Dockerfile does
#    `COPY --from=src . /<repo>/src`, so point --src at the src/ subdir.
#  - buildx needs --allow=fs.read=<src> for a local-path context, plus
#    output=type=docker so the image lands in the daemon (kind load can see it).
#  - deployment/container/image names all differ; discover the pair rather than
#    guessing (discover-target.sh).
#  - imagePullPolicy=IfNotPresent is usually already set; the patch is a no-op.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE=""
SRC="$PWD/src"
RELEASES_DIR="$PWD"
NS="cf-system"
CLUSTER="cfk8s"
TAG="latest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    --releases-dir) RELEASES_DIR="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    -*) echo "redeploy.sh: unknown arg: $1" >&2; exit 2 ;;
    *) IMAGE="$1"; shift ;;
  esac
done

[[ -n "$IMAGE" ]] || { echo "redeploy.sh: usage: redeploy.sh <image> [--src <path>] [--releases-dir <path>] [--namespace <ns>] [--cluster <name>]" >&2; exit 2; }

log() { echo "==> $*"; }
die() { echo "redeploy.sh: $*" >&2; exit 1; }

[[ -d "$SRC" ]] || die "src context '$SRC' does not exist (pass --src <path-to-src-dir>)"
[[ -d "$RELEASES_DIR" ]] || die "releases dir '$RELEASES_DIR' does not exist (pass --releases-dir <path>)"

# The docker-bake.hcl + Dockerfiles live in cf-k8s-releases/<component>/, not the
# releases root (fact #1). Resolve the build dir: if RELEASES_DIR already has a
# bake file, build there; otherwise find the component subdir whose bake file
# defines this target. This lets the caller pass either the component dir or the
# releases root without needing to know the layout.
resolve_build_dir() {
  if [[ -f "$RELEASES_DIR/docker-bake.hcl" ]]; then
    echo "$RELEASES_DIR"; return 0
  fi
  # Prefer a subdir whose bake file names the target; fall back to a subdir named
  # like the image.
  local hit
  hit="$(grep -rl -E "\"?$IMAGE\"?" --include=docker-bake.hcl "$RELEASES_DIR" 2>/dev/null | head -1 || true)"
  if [[ -n "$hit" ]]; then
    dirname "$hit"; return 0
  fi
  [[ -f "$RELEASES_DIR/$IMAGE/docker-bake.hcl" ]] && { echo "$RELEASES_DIR/$IMAGE"; return 0; }
  return 1
}
BUILD_DIR="$(resolve_build_dir)" \
  || die "no docker-bake.hcl defining target '$IMAGE' under '$RELEASES_DIR' (pass --releases-dir <cf-k8s-releases-or-component-dir>)"

# 1. Build. Run from the resolved component dir so bake + Dockerfiles resolve.
log "[1/5] build: bake '$IMAGE' from '$BUILD_DIR' (src=$SRC)"
( cd "$BUILD_DIR" && \
  docker buildx bake --allow=fs.read="$SRC" "$IMAGE" \
    --set "$IMAGE.contexts.src=$SRC" \
    --set "$IMAGE.output=type=docker" \
) || die "bake failed for target '$IMAGE' (check the target name: docker buildx bake --print)"

# 2. Load into kind.
log "[2/5] load: kind load docker-image '$IMAGE:$TAG' --name '$CLUSTER'"
kind load docker-image "$IMAGE:$TAG" --name "$CLUSTER" \
  || die "kind load failed (image built? cluster '$CLUSTER' up?)"

# 3. Discover the (deployment, container) pair for this image.
log "[3/5] discover: target for image '$IMAGE'"
target="$(bash "$SCRIPT_DIR/discover-target.sh" "$IMAGE" --cluster "$CLUSTER" | head -1)"
[[ -n "$target" ]] || die "could not find a running container using image '$IMAGE' (is it deployed?)"
read -r DEP CONT TNS <<<"$target"
[[ -n "${TNS:-}" ]] && NS="$TNS"
log "    -> deployment=$DEP container=$CONT namespace=$NS"

# 4. Point the container at the freshly loaded image; ensure IfNotPresent.
log "[4/5] set image: deployment/$DEP $CONT=$IMAGE:$TAG (ns=$NS)"
kubectl -n "$NS" set image "deployment/$DEP" "$CONT=$IMAGE:$TAG"
# Harmless no-op if the chart already sets IfNotPresent — don't treat as error.
kubectl -n "$NS" patch deployment "$DEP" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"IfNotPresent\"}]" \
  >/dev/null 2>&1 || true

# 5. Wait for the rollout.
log "[5/5] rollout: deployment/$DEP (timeout 180s)"
kubectl -n "$NS" rollout status "deployment/$DEP" --timeout=180s \
  || die "rollout did not complete — check: kubectl -n $NS describe deployment/$DEP"

echo
log "done. verify with: bash $SCRIPT_DIR/verify-status.sh $DEP --namespace $NS"
bash "$SCRIPT_DIR/verify-status.sh" "$DEP" --namespace "$NS" || true
