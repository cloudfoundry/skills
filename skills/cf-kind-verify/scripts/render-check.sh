#!/usr/bin/env bash
set -euo pipefail
# render-check.sh — validate a local helm-chart change renders as expected
# BEFORE applying it, by templating the chart and grepping the output.
#
# Usage:
#   render-check.sh <release> <chart-dir> [options]
#
#   <release>     helm release name (e.g. log-cache, gorouter)
#   <chart-dir>   path to the LOCAL chart (e.g. cf-k8s-releases/<comp>/helm)
#
# Options:
#   --namespace <ns>   default: cf-system
#   --values <file>    extra values file (repeatable)   [-f passthrough]
#   --grep <pattern>   extended regex to highlight       (default: 'image:|env:')
#   --kind-dir <path>  clone of cloudfoundry/kind-deployment (recommended, as for
#                      lifecycle.sh/cats.sh); helm is taken from <kind-dir>/bin/helm
#                      where kind-deployment installs it. Without it, `helm` on PATH
#                      is used.
#
# Why render first: `make up`/helmfile uses the PUBLISHED chart, so local chart
# edits are only exercised via a direct helm template/upgrade against the local
# dir. Templating and grepping for your new env var / image ref confirms the
# change actually lands in the manifest before you mutate the cluster.

NS="cf-system"
GREP='image:|env:'
KIND_DIR=""
RELEASE=""
CHART_DIR=""
VALUES_ARGS=()

positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --values) VALUES_ARGS+=("-f" "$2"); shift 2 ;;
    --grep) GREP="$2"; shift 2 ;;
    --kind-dir) KIND_DIR="$2"; shift 2 ;;
    -*) echo "render-check.sh: unknown arg: $1" >&2; exit 2 ;;
    *) positional+=("$1"); shift ;;
  esac
done

RELEASE="${positional[0]:-}"
CHART_DIR="${positional[1]:-}"
[[ -n "$RELEASE" && -n "$CHART_DIR" ]] || { echo "render-check.sh: usage: render-check.sh <release> <chart-dir> [--kind-dir d] [--values f] [--grep re]" >&2; exit 2; }
[[ -d "$CHART_DIR" ]] || { echo "render-check.sh: chart dir '$CHART_DIR' not found" >&2; exit 1; }

# Resolve helm the same way as the rest of the skill: prefer the copy
# kind-deployment installs under <kind-dir>/bin/helm (pass --kind-dir, as for
# lifecycle.sh/cats.sh); otherwise fall back to `helm` on PATH. Both are trusted
# inputs — a user-confirmed --kind-dir clone or a real helm on PATH — so there's no
# arbitrary-binary path to allowlist here.
if [[ -n "$KIND_DIR" ]]; then
  [[ -d "$KIND_DIR" ]] || { echo "render-check.sh: kind-dir '$KIND_DIR' not found" >&2; exit 1; }
  HELM_BIN="$KIND_DIR/bin/helm"
  [[ -x "$HELM_BIN" ]] || { echo "render-check.sh: '$HELM_BIN' not found or not executable — is '$KIND_DIR' a kind-deployment clone with helm installed (make up)?" >&2; exit 1; }
elif command -v helm >/dev/null 2>&1; then
  HELM_BIN="helm"
else
  echo "render-check.sh: no helm found — pass --kind-dir <kind-deployment-clone> (uses its bin/helm) or put helm on PATH" >&2
  exit 1
fi

echo "render-check.sh: helm template $RELEASE $CHART_DIR -n $NS ${VALUES_ARGS[*]:-}"
echo "render-check.sh: highlighting /$GREP/"
echo "---"
# Capture the rendered manifest so we can distinguish "chart produced nothing"
# (gated off — e.g. loggregator-agent needs --set forwarderAgent.enabled=true) from
# "pattern not found in non-empty output". Both used to funnel into one error.
if ! rendered="$("$HELM_BIN" template "$RELEASE" "$CHART_DIR" -n "$NS" "${VALUES_ARGS[@]+"${VALUES_ARGS[@]}"}")"; then
  echo "render-check.sh: '$HELM_BIN template' failed (see helm error above)" >&2
  exit 1
fi
if [[ -z "${rendered//[[:space:]]/}" ]]; then
  echo "render-check.sh: helm produced NO manifests — the chart likely rendered nothing" >&2
  echo "render-check.sh: (a subchart/feature gated off?). Try enabling it via --values/--set." >&2
  exit 1
fi
printf '%s\n' "$rendered" \
  | grep -nE "$GREP" \
  || { echo "render-check.sh: pattern '/$GREP/' not found in the (non-empty) rendered output — did the change take?" >&2; exit 1; }
