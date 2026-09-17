#!/usr/bin/env bash
set -euo pipefail
# lifecycle.sh — bring the local cf-on-kind cluster up or down.
#
# Usage:
#   lifecycle.sh up    --kind-dir <path> [--cluster <name>] [--all-buildpacks]
#   lifecycle.sh down  --kind-dir <path> [--cluster <name>]
#   lifecycle.sh status [--cluster <name>]
#
#   --kind-dir        path to a clone of cloudfoundry/kind-deployment (required
#                     for up/down; that's where the Makefile lives)
#   --cluster         kind cluster name (default: cfk8s)
#   --all-buildpacks  on `up`, run `make bootstrap-complete` (ALL_BUILDPACKS) so
#                     ruby/python/etc. are uploaded — needed for full CATS.
#                     Default is plain `make bootstrap` (java/nodejs/go/binary).
#
# `up` = make up && make login && make bootstrap[-complete] from --kind-dir.
# `down` = make down. These wrap the canonical kind-deployment targets rather
# than reinventing them; see kind-deployment/docs/local-development-guide.md.
#
# NOTE: `up` is slow (pulls images, boots a cluster, bootstraps CF) and is
# destructive-ish (down tears the cluster down). Only run when the user asked to
# start/stop the cluster — never as a silent side effect of a verify request.

CLUSTER="cfk8s"
KIND_DIR=""
ALL_BP=0

CMD="${1:-}"; shift || true
[[ -n "$CMD" ]] || { echo "lifecycle.sh: usage: lifecycle.sh <up|down|status> [options]" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind-dir) KIND_DIR="$2"; shift 2 ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    --all-buildpacks) ALL_BP=1; shift ;;
    -*) echo "lifecycle.sh: unknown arg: $1" >&2; exit 2 ;;
    *) echo "lifecycle.sh: unexpected arg: $1" >&2; exit 2 ;;
  esac
done

log() { echo "==> $*"; }
die() { echo "lifecycle.sh: $*" >&2; exit 1; }

need_kind_dir() {
  [[ -n "$KIND_DIR" ]] || die "--kind-dir <path-to-kind-deployment-clone> is required for '$CMD'"
  [[ -f "$KIND_DIR/Makefile" ]] || die "'$KIND_DIR' has no Makefile — is it a kind-deployment clone?"
  # We run `make` from $KIND_DIR below, so require the Makefile to define the real
  # kind-deployment targets — not just exist. Backstop, not a guarantee: --kind-dir
  # must be a user-confirmed path.
  local t missing=()
  for t in up down login bootstrap; do
    grep -qE "^${t}[[:space:]]*:" "$KIND_DIR/Makefile" || missing+=("$t")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "'$KIND_DIR/Makefile' is missing expected kind-deployment target(s): ${missing[*]} — refusing to run 'make' in a dir that isn't a kind-deployment clone"
  fi
}

case "$CMD" in
  status)
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
      echo "cluster '$CLUSTER': UP"
      kubectl config current-context 2>/dev/null || true
      kubectl get nodes 2>/dev/null || true
    else
      echo "cluster '$CLUSTER': DOWN (not in \`kind get clusters\`)"
      exit 1
    fi
    ;;

  up)
    need_kind_dir
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
      log "cluster '$CLUSTER' already up — skipping 'make up'"
    else
      log "[up] make up   (this pulls images and boots a kind cluster — slow)"
      ( cd "$KIND_DIR" && make up ) || die "'make up' failed in $KIND_DIR"
    fi
    log "[up] make login"
    ( cd "$KIND_DIR" && make login ) || die "'make login' failed"
    if [[ "$ALL_BP" -eq 1 ]]; then
      log "[up] make bootstrap-complete   (ALL_BUILDPACKS — needed for full CATS)"
      ( cd "$KIND_DIR" && make bootstrap-complete ) || die "'make bootstrap-complete' failed"
    else
      log "[up] make bootstrap"
      ( cd "$KIND_DIR" && make bootstrap ) || die "'make bootstrap' failed"
    fi
    log "up complete — cluster '$CLUSTER' ready"
    ;;

  down)
    need_kind_dir
    log "[down] make down   (tears down cluster '$CLUSTER')"
    ( cd "$KIND_DIR" && make down ) || die "'make down' failed in $KIND_DIR"
    log "down complete"
    ;;

  *)
    die "unknown command '$CMD' (expected up|down|status)"
    ;;
esac
