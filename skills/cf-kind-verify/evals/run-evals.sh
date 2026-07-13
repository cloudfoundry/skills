#!/usr/bin/env bash
set -euo pipefail
# run-evals.sh — benchmark the working-tree cf-kind-verify skill against a
# baseline git ref, grade both, and print a version-vs-version delta table.
#
# Usage:
#   skills/cf-kind-verify/evals/run-evals.sh [--] [options]
#
# Options:
#   --against <git-ref>   baseline to compare the working tree against  (default: HEAD)
#   --runs-per-query <n>  runs per config per eval (noise averaging)     (default: 3)
#   --timeout <secs>      per claude -p call wall-clock budget           (default: 120)
#   --only <ids>          comma-separated eval ids to run                (default: all)
#   --jobs <n>            max concurrent runs (batch size)               (default: 5)
#   --model <id>          model for executor+grader claude -p     (default: anthropic--claude-sonnet-latest)
#   --no-viewer           skip launching the HTML results viewer
#   --verbose             stream per-run progress
#   --                    no-op separator (matches pre-authorized invocation)
#
# WHY THIS EXISTS (see README.md "Version-vs-version runner"):
# skill-creator already provides grading (agents/grader.md), aggregation
# (aggregate_benchmark.py), and the viewer (generate_review.py) — this script
# reuses all of them verbatim. What it adds is the glue skill-creator's
# agent-driven flow does not: an --against <git-ref> baseline, a contamination
# fix for a *user-level installed* skill, and the run-dir layout the aggregator
# expects. Delta = new_skill - old_skill.
#
# CONTAMINATION FIX (critical): cf-kind-verify is installed user-level
# (~/.claude/skills/cf-kind-verify -> ~/claude/cf-kind-verify), so any `claude -p`
# would otherwise see the ambient skill regardless of cwd. Both configs instead
# run --disable-slash-commands from an isolated $TMPDIR cwd, are handed the
# materialized SKILL.md via --append-system-prompt, and are told never to read a
# .claude dir. Neither side uses the ambient installed skill — symmetric.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
EVALS_JSON="$SCRIPT_DIR/evals.json"

AGAINST="HEAD"
RUNS_PER_QUERY=3
TIMEOUT=120
ONLY=""
JOBS=5
MODEL="anthropic--claude-sonnet-latest"
VIEWER=1
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --against) AGAINST="$2"; shift 2 ;;
    --runs-per-query) RUNS_PER_QUERY="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --no-viewer) VIEWER=0; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --) shift ;;
    -*) echo "run-evals.sh: unknown arg: $1" >&2; exit 2 ;;
    *) echo "run-evals.sh: unexpected positional arg: $1" >&2; exit 2 ;;
  esac
done

log() { echo "==> $*"; }
vlog() { [[ "$VERBOSE" == 1 ]] && echo "    $*" || true; }
die() { echo "run-evals.sh: $*" >&2; exit 1; }

command -v claude >/dev/null 2>&1 || die "claude CLI not found on PATH"
command -v git >/dev/null 2>&1 || die "git not found on PATH"
[[ -f "$EVALS_JSON" ]] || die "evals.json not found at $EVALS_JSON"

# Resolve skill-creator harness (reused for aggregation + viewer + grader.md).
# shellcheck disable=SC2012  # glob over ~/.claude paths; filenames are controlled
SC="$(ls -d "$HOME"/.claude/plugins/marketplaces/*/plugins/skill-creator/skills/skill-creator 2>/dev/null | head -1 || true)"
[[ -n "$SC" && -d "$SC" ]] || die "skill-creator harness not found under ~/.claude/plugins/marketplaces/"
GRADER_MD="$SC/agents/grader.md"
[[ -f "$GRADER_MD" ]] || die "grader.md not found at $GRADER_MD"

# Resolve the baseline SHA up front (fail fast on a bad ref).
BASE_SHA="$(git -C "$REPO_ROOT" rev-parse --verify "$AGAINST^{commit}" 2>/dev/null)" \
  || die "--against '$AGAINST' is not a valid git ref in $REPO_ROOT"

# Scratch lives in $TMPDIR — ephemeral, never in the repo. mktemp -d respects it.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/cfkv-evals.XXXXXX")"
BENCH="$SCRATCH/bench"
NEW_SKILL="$SCRATCH/new_skill_src"
OLD_WORKTREE="$SCRATCH/old_worktree"
mkdir -p "$BENCH"

# Cleanup: remove the git worktree (never mutates the main tree) and scratch dir.
cleanup() {
  if [[ -d "$OLD_WORKTREE" ]]; then
    git -C "$REPO_ROOT" worktree remove --force "$OLD_WORKTREE" >/dev/null 2>&1 || true
  fi
  git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
  [[ -n "${KEEP_SCRATCH:-}" ]] || rm -rf "$SCRATCH"
}
trap cleanup EXIT

log "Comparing working tree (new_skill) vs $AGAINST @ ${BASE_SHA:0:12} (old_skill)"
log "runs/config/eval=$RUNS_PER_QUERY  timeout=${TIMEOUT}s  jobs=$JOBS  model=$MODEL"
log "scratch: $SCRATCH"

# --- Materialize NEW = copy of the working-tree skill (includes uncommitted edits)
# Must be a COPY, not a worktree: we want the dirty working tree, and we must not
# touch the real repo. tar-pipe avoids an rsync dependency.
log "Materializing new_skill (working-tree copy)…"
mkdir -p "$NEW_SKILL"
( cd "$SKILL_DIR" && tar -c -f - . ) | tar -x -C "$NEW_SKILL" -f -
[[ -f "$NEW_SKILL/SKILL.md" ]] || die "new_skill copy has no SKILL.md (unexpected)"

# --- Materialize OLD = detached worktree at the baseline ref --------------------
log "Materializing old_skill (git worktree @ ${BASE_SHA:0:12})…"
git -C "$REPO_ROOT" worktree add --detach "$OLD_WORKTREE" "$BASE_SHA" >/dev/null 2>&1 \
  || die "git worktree add failed for $BASE_SHA"
OLD_SKILL="$OLD_WORKTREE/skills/cf-kind-verify"
[[ -f "$OLD_SKILL/SKILL.md" ]] || die "baseline ref has no skills/cf-kind-verify/SKILL.md"

# --- Parse evals.json (embedded python, no jq) ----------------------------------
# Emits one TSV line per (selected) eval: id \t name \t <b64 prompt> \t
# <b64 newline-joined expectations>. b64 avoids any tab/newline in the fields
# corrupting the TSV.
EVAL_TSV="$SCRATCH/evals.tsv"
ONLY="$ONLY" EVALS_JSON="$EVALS_JSON" python3 /dev/fd/3 3<<'PY' >"$EVAL_TSV"
import base64, json, os
with open(os.environ["EVALS_JSON"]) as f:
    data = json.load(f)
only = os.environ.get("ONLY", "").strip()
sel = set(int(x) for x in only.split(",")) if only else None
def b64(s): return base64.b64encode(s.encode()).decode()
for ev in data["evals"]:
    if sel is not None and ev["id"] not in sel:
        continue
    exps = "\n".join(ev.get("expectations", []))
    print("\t".join([str(ev["id"]), ev["name"], b64(ev["prompt"]), b64(exps)]))
PY

[[ -s "$EVAL_TSV" ]] || die "no evals selected (check --only '$ONLY')"
NUM_EVALS=$(wc -l <"$EVAL_TSV" | tr -d ' ')
log "Selected $NUM_EVALS eval(s); $((NUM_EVALS * 2 * RUNS_PER_QUERY)) total runs"

# Instruction block appended to every executor prompt. It (a) forbids reading any
# .claude dir — closing the contamination path a breadcrumb could open — and (b)
# asks for a describe-the-flow answer (these evals are about triggering + script
# orchestration reasoning, not actually mutating a cluster).
read -r -d '' EXEC_GUARD <<'GUARD' || true
You are answering a user request. A candidate skill's instructions are appended
to your system prompt above. Decide whether that skill applies; if it does, follow
it. Describe the exact flow you WOULD take — which scripts you would call, in what
order, with which arguments, and state your reasoning and assumptions. Do NOT
actually build images, deploy, or run cluster-mutating commands. Do NOT read any
.claude directory or any installed-skill path; rely only on the appended skill
instructions and the request itself.
GUARD

# run_one <config> <skill_dir> <eval_id> <name> <b64prompt> <b64exps> <run_k>
# Executes one eval run: executor claude -p (JSON) -> summary.md + transcript.md +
# timing.json, then grader claude -p -> run-<k>/grading.json. Isolated cwd, skill
# fed via --append-system-prompt, output parsed from JSON (.result) so no output
# path is ever handed to the model.
run_one() {
  local config="$1" skill_dir="$2" eid="$3" name="$4" b64p="$5" b64e="$6" k="$7"
  local run_dir="$BENCH/eval-${eid}-${name}/${config}/run-${k}"
  local out_dir="$run_dir/outputs"
  mkdir -p "$out_dir"

  local prompt exps skill_md
  prompt="$(printf '%s' "$b64p" | base64 --decode)"
  exps="$(printf '%s' "$b64e" | base64 --decode)"
  skill_md="$(cat "$skill_dir/SKILL.md")"

  # Isolated cwd — nothing here references the ambient installed skill.
  local work; work="$(mktemp -d "$SCRATCH/cwd.XXXXXX")"

  # --- Executor -------------------------------------------------------------
  local exec_json="$run_dir/exec.json"
  local sys_prompt="$EXEC_GUARD

# Candidate skill: cf-kind-verify (materialized from $config)
$skill_md"

  set +e
  # shellcheck disable=SC1007  # CLAUDECODE= deliberately clears the var for the child
  ( cd "$work" && CLAUDECODE= claude -p "$prompt" \
      --model "$MODEL" \
      --output-format json \
      --disable-slash-commands \
      --append-system-prompt "$sys_prompt" ) >"$exec_json" 2>/dev/null &
  local pid=$!
  _wait_with_timeout "$pid" "$TIMEOUT"
  local exec_rc=$?
  set -e

  if [[ "$exec_rc" -ne 0 ]]; then
    vlog "eval $eid $config run $k: executor failed/timeout (rc=$exec_rc)"
    printf '# executor failed (rc=%s)\n' "$exec_rc" >"$out_dir/summary.md"
  else
    # Extract .result (summary), token usage, duration from the JSON envelope.
    EXEC_JSON="$exec_json" OUT_DIR="$out_dir" RUN_DIR="$run_dir" \
      python3 /dev/fd/3 3<<'PY'
import json, os
env = os.environ
try:
    with open(env["EXEC_JSON"]) as f:
        d = json.load(f)
except Exception:
    d = {}
result = d.get("result", "") or ""
with open(os.path.join(env["OUT_DIR"], "summary.md"), "w") as f:
    f.write(result if result else "# (empty executor result)\n")
# Transcript: for these describe-the-flow evals the final result IS the transcript.
with open(os.path.join(env["OUT_DIR"], "transcript.md"), "w") as f:
    f.write(result if result else "# (empty)\n")
u = d.get("usage", {}) or {}
tokens = (u.get("input_tokens", 0) or 0) + (u.get("output_tokens", 0) or 0)
dur = (d.get("duration_ms", 0) or 0) / 1000.0
with open(os.path.join(env["RUN_DIR"], "timing.json"), "w") as f:
    json.dump({"total_duration_seconds": round(dur, 2), "total_tokens": tokens}, f)
PY
  fi

  # --- Grader ---------------------------------------------------------------
  # Single-shot text grading: the executor's answer is inlined into the prompt
  # and the grader RETURNS grading.json as its .result (no file reads, no file
  # writes, no tool use — those would hang/time out from the isolated cwd). We
  # write .result to run-<k>/grading.json ourselves, at the layout the aggregator
  # needs. grader.md supplies the rubric + exact schema.
  local summary_text; summary_text="$(cat "$out_dir/summary.md")"
  local grader_prompt; grader_prompt="$(cat "$GRADER_MD")

## This grading task

You are grading a single eval run. Everything you need is inlined below — do NOT
read or write any files, and do NOT use any tools. Respond with ONLY the
grading JSON (no prose, no code fences).

### Expectations (grade each; one per line)
$exps

### Executor's answer (the transcript/output to grade)
<<<TRANSCRIPT
$summary_text
TRANSCRIPT

Emit exactly this schema and nothing else:
{\"expectations\":[{\"text\":\"…\",\"passed\":true,\"evidence\":\"…\"}],\"summary\":{\"passed\":N,\"failed\":N,\"total\":N,\"pass_rate\":0.0}}"

  set +e
  # shellcheck disable=SC1007  # CLAUDECODE= deliberately clears the var for the child
  ( cd "$work" && CLAUDECODE= claude -p "$grader_prompt" \
      --model "$MODEL" \
      --output-format json \
      --disable-slash-commands ) >"$run_dir/grader.json" 2>/dev/null &
  local gpid=$!
  _wait_with_timeout "$gpid" "$TIMEOUT"
  set -e

  # The grader returns grading.json as its .result envelope; extract and write it
  # to run-<k>/grading.json. Fall back to an all-fail grading only if unrecoverable
  # (a missing grading.json is silently dropped by the aggregator -> 0 runs).
  RUN_DIR="$run_dir" GRADER_OUT="$run_dir/grader.json" EXPS="$exps" \
    python3 /dev/fd/3 3<<'PY'
import json, os
env = os.environ
gpath = os.path.join(env["RUN_DIR"], "grading.json")
def valid(p):
    try:
        with open(p) as f: json.load(f)
        return True
    except Exception:
        return False
if not valid(gpath):
    # Extract the grading JSON from the grader's .result envelope.
    recovered = None
    try:
        with open(env["GRADER_OUT"]) as f:
            d = json.load(f)
        txt = d.get("result", "") or ""
        s, e = txt.find("{"), txt.rfind("}")
        if s != -1 and e != -1:
            recovered = json.loads(txt[s:e+1])
    except Exception:
        recovered = None
    if recovered is None:
        # Last resort: emit an all-fail grading so the aggregator still counts
        # the run (a missing grading.json is silently dropped -> 0 runs).
        exps = [x for x in env["EXPS"].split("\n") if x.strip()]
        recovered = {
            "expectations": [
                {"text": t, "passed": False, "evidence": "grading unavailable (executor/grader error)"}
                for t in exps
            ],
            "summary": {"passed": 0, "failed": len(exps), "total": len(exps), "pass_rate": 0.0},
        }
    with open(gpath, "w") as f:
        json.dump(recovered, f, indent=2)
PY

  vlog "eval $eid $config run $k: done"
}

# _wait_with_timeout <pid> <secs> — poll a backgrounded child up to <secs>, kill
# on timeout. macOS bash 3.2 has no `wait -n` and no coreutils `timeout`, so we
# poll. Returns the child's exit code, or 124 on timeout.
_wait_with_timeout() {
  local pid="$1" secs="$2" waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$waited" -ge "$secs" ]]; then
      kill "$pid" 2>/dev/null
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null
  return $?
}

# --- Build the run queue, execute in batches of $JOBS ---------------------------
# Each job is one (config, eval, run) unit; executor+grader run together inside
# run_one. Batch-of-N concurrency (bash 3.2-safe). set +e around the batch wait so
# a failing child never aborts the runner.
declare -a JOB_ARGS=()
while IFS=$'\t' read -r eid name b64p b64e; do
  for k in $(seq 1 "$RUNS_PER_QUERY"); do
    JOB_ARGS+=("new_skill|$NEW_SKILL|$eid|$name|$b64p|$b64e|$k")
    JOB_ARGS+=("old_skill|$OLD_SKILL|$eid|$name|$b64p|$b64e|$k")
  done
done <"$EVAL_TSV"

TOTAL=${#JOB_ARGS[@]}
log "Dispatching $TOTAL runs in batches of ${JOBS}…"
i=0
while [[ "$i" -lt "$TOTAL" ]]; do
  declare -a pids=()
  batch_n=0
  while [[ "$batch_n" -lt "$JOBS" && "$i" -lt "$TOTAL" ]]; do
    IFS='|' read -r c s eid name b64p b64e k <<<"${JOB_ARGS[$i]}"
    vlog "start [$((i + 1))/$TOTAL] eval $eid $c run $k"
    run_one "$c" "$s" "$eid" "$name" "$b64p" "$b64e" "$k" &
    pids+=($!)
    i=$((i + 1))
    batch_n=$((batch_n + 1))
  done
  set +e
  for p in "${pids[@]}"; do wait "$p"; done
  set -e
  log "…$i/$TOTAL runs complete"
done

# --- eval_metadata.json per eval dir (aggregator reads eval_id from it) ---------
while IFS=$'\t' read -r eid name b64p b64e; do
  ed="$BENCH/eval-${eid}-${name}"
  [[ -d "$ed" ]] || continue
  EID="$eid" NAME="$name" B64P="$b64p" ED="$ed" python3 /dev/fd/3 3<<'PY'
import base64, json, os
env = os.environ
meta = {
    "eval_id": int(env["EID"]),
    "name": env["NAME"],
    "prompt": base64.b64decode(env["B64P"]).decode(),
}
with open(os.path.join(env["ED"], "eval_metadata.json"), "w") as f:
    json.dump(meta, f, indent=2)
PY
done <"$EVAL_TSV"

# --- Aggregate + viewer (MUST run unsandboxed: ProcessPoolExecutor) -------------
log "Aggregating (reusing skill-creator aggregate_benchmark.py)…"
( cd "$SC" && python3 -m scripts.aggregate_benchmark "$BENCH" \
    --skill-name cf-kind-verify --skill-path "$NEW_SKILL" ) \
  || die "aggregation failed (must run unsandboxed — ProcessPoolExecutor)"

BENCH_MD="$BENCH/benchmark.md"
BENCH_JSON="$BENCH/benchmark.json"
if [[ -f "$BENCH_MD" ]]; then
  echo
  cat "$BENCH_MD"
  echo
fi

# Extract the headline delta for a one-line summary.
if [[ -f "$BENCH_JSON" ]]; then
  BENCH_JSON="$BENCH_JSON" python3 /dev/fd/3 3<<'PY'
import json, os
with open(os.environ["BENCH_JSON"]) as f:
    d = json.load(f)
delta = (d.get("run_summary") or d).get("delta", {}) if isinstance(d, dict) else {}
if not delta:
    delta = d.get("delta", {})
pr = delta.get("pass_rate", "?")
print(f"==> DELTA (new_skill - old_skill): pass_rate {pr}  "
      f"time {delta.get('time_seconds','?')}s  tokens {delta.get('tokens','?')}")
PY
fi

log "Benchmark artifacts: $BENCH"
log "  (set KEEP_SCRATCH=1 to preserve $SCRATCH after exit)"

if [[ "$VIEWER" == 1 ]]; then
  log "Launching results viewer on http://127.0.0.1:3117 …"
  ( cd "$SC" && python3 eval-viewer/generate_review.py "$BENCH" \
      --skill-name cf-kind-verify --benchmark "$BENCH_JSON" ) \
    || log "viewer failed to launch (aggregation still succeeded; see $BENCH)"
else
  log "Viewer skipped (--no-viewer)."
fi
