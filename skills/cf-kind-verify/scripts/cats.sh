#!/usr/bin/env bash
set -euo pipefail
# cats.sh — render the CATS config and run a FOCUSED subset of the CF Acceptance
# Tests against the local cf-on-kind cluster, from any cwd.
#
# Usage:
#   cats.sh --kind-dir <path> --focus "<Describe/It text>" [options]
#
# Options:
#   --kind-dir <path>   clone of cloudfoundry/kind-deployment (has scripts/cats.sh,
#                       .github/cats-config.tpl, temp/secrets.sh, temp/kubeconfig)  [required]
#   --cats-dir <path>   clone of cf-acceptance-tests   (default: <kind-dir>/../cf-acceptance-tests)
#   --focus <text>      ginkgo --focus regex; selects specs on the ROOT suite       [required]
#   --timeout <dur>     ginkgo --timeout                                            (default: 45m)
#   --render-only       render the config and stop (don't run any specs)
#
# Thin shim over kind-deployment's own scripts/cats.sh, which renders
# .github/cats-config.json and forwards extra args to cf-acceptance-tests/bin/test.
# We resolve paths cwd-independently, forward --focus/--timeout, and run outside
# the sandbox. See references/test-conventions.md.

KIND_DIR=""
CATS_DIR=""
FOCUS=""
TIMEOUT="45m"
RENDER_ONLY=""

# Accept both `--flag value` and `--flag=value` forms.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind-dir) KIND_DIR="$2"; shift 2 ;;
    --kind-dir=*) KIND_DIR="${1#*=}"; shift ;;
    --cats-dir) CATS_DIR="$2"; shift 2 ;;
    --cats-dir=*) CATS_DIR="${1#*=}"; shift ;;
    --focus) FOCUS="$2"; shift 2 ;;
    --focus=*) FOCUS="${1#*=}"; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --timeout=*) TIMEOUT="${1#*=}"; shift ;;
    --render-only) RENDER_ONLY=1; shift ;;
    -*) echo "cats.sh: unknown arg: $1" >&2; exit 2 ;;
    *) echo "cats.sh: unexpected positional arg: $1" >&2; exit 2 ;;
  esac
done

log() { echo "==> $*"; }
die() { echo "cats.sh: $*" >&2; exit 1; }

[[ -n "$KIND_DIR" ]] || { echo "cats.sh: usage: cats.sh --kind-dir <path> --focus \"<text>\" [--cats-dir <path>] [--timeout <dur>] [--render-only]" >&2; exit 2; }
[[ -d "$KIND_DIR" ]] || die "kind-dir '$KIND_DIR' does not exist (pass a clone of cloudfoundry/kind-deployment)"

# Resolve to absolute paths so the rest of the script is cwd-independent.
KIND_DIR="$(cd "$KIND_DIR" && pwd)"
CATS_DIR="${CATS_DIR:-$KIND_DIR/../cf-acceptance-tests}"
[[ -d "$CATS_DIR" ]] || die "cats-dir '$CATS_DIR' does not exist (pass --cats-dir <clone of cf-acceptance-tests>)"
CATS_DIR="$(cd "$CATS_DIR" && pwd)"

[[ -f "$KIND_DIR/scripts/cats.sh" ]] || die "'$KIND_DIR' is not a kind-deployment clone (no scripts/cats.sh)"
[[ -f "$KIND_DIR/temp/secrets.sh" ]] || die "'$KIND_DIR/temp/secrets.sh' missing — is the cluster up? (make up writes temp/)"
[[ -f "$KIND_DIR/temp/kubeconfig" ]] || die "'$KIND_DIR/temp/kubeconfig' missing — is the cluster up? (make up writes temp/)"

if [[ -z "$RENDER_ONLY" && -z "$FOCUS" ]]; then
  die "no --focus given. Pass --focus \"<Describe/It text>\", or --render-only to just render the config."
fi

CATS_CONFIG="$KIND_DIR/.github/cats-config.json"

if [[ -n "$RENDER_ONLY" ]]; then
  # Render only. Run from the kind-dir so its relative paths resolve.
  log "render-only: RENDER_ONLY=1 scripts/cats.sh (in $KIND_DIR) -> .github/cats-config.json"
  ( cd "$KIND_DIR" && RENDER_ONLY=1 CATS_PATH="$CATS_DIR" bash scripts/cats.sh ) \
    || die "render failed (check $KIND_DIR/.github/cats-config.tpl and temp/secrets.sh)"
  [[ -f "$CATS_CONFIG" ]] || die "expected rendered config at '$CATS_CONFIG' but it's missing"
  log "done (render-only). Config: $CATS_CONFIG"
  exit 0
fi

# Render + run via kind-deployment's scripts/cats.sh; forward --focus/--timeout.
log "run: scripts/cats.sh --focus=\"$FOCUS\" --timeout=$TIMEOUT (in $KIND_DIR)"
( cd "$KIND_DIR" && CATS_PATH="$CATS_DIR" bash scripts/cats.sh --focus="$FOCUS" --timeout="$TIMEOUT" ) \
  || die "focused CATS run failed (see ginkgo output above)"

echo
log "done. focused CATS run completed for --focus=\"$FOCUS\"."
