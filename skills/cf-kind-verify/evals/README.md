# Running the cf-kind-verify evals

`evals.json` is the eval set — 5 cases (3 should-trigger, 2 near-misses), each with a
`prompt` and an `expected_output` describing the **flow** we expect (which script is
called, `redeploy.sh --src`, ROOT CATS with `--focus`, etc.), not just whether the skill
triggers.

The runner writes benchmark artifacts to a temporary directory and prints its path.
Set `KEEP_SCRATCH=1` to retain them after the run.

## How to rerun

There are two paths, depending on what you're doing:

### A. Version-vs-version regression check (after editing the skill) — `run-evals.sh`

When you've edited the skill and want to know **did this get better or worse?**, run
the committed wrapper:

```bash
# Compare the working tree against the last commit, 2 runs each, then open the viewer:
bash ./skills/cf-kind-verify/evals/run-evals.sh -- --verbose --runs-per-query 2 --timeout 90 --against HEAD

# Against a specific baseline (tag / SHA / branch):
bash ./skills/cf-kind-verify/evals/run-evals.sh -- --against v1.0 --runs-per-query 3
```

It benchmarks the **working-tree** skill (`new_skill`, includes uncommitted edits)
against a **baseline git ref** (`old_skill`, default `HEAD`), grades both, and prints a
`delta = new_skill − old_skill` table plus the HTML viewer.

`run-evals.sh` is a thin wrapper — it **reuses** skill-creator's `aggregate_benchmark.py`,
`generate_review.py`, and `agents/grader.md` verbatim. It only adds what skill-creator's
interactive flow doesn't: an `--against <git-ref>` baseline, a fix for the
installed-skill contamination trap (see gotcha 3 below), and the run-dir layout the
aggregator expects. Key flags: `--against <ref>`, `--runs-per-query <n>`,
`--timeout <secs>`, `--only <ids>`, `--jobs <n>`, `--model <id>`, `--no-viewer`,
`--verbose`.

**Must run unsandboxed** (ProcessPoolExecutor — see gotcha 1). Full runs take
~20–30 min, so background them.

### B. Skill-vs-no-skill / interactive exploration — `skill-creator`

**Invoke the `skill-creator` skill** and ask it to benchmark this skill:

> Benchmark the skill at `~/.claude/skills/cf-kind-verify` against its `evals/evals.json`.

Skill-creator *is* the harness. It drives the documented benchmark workflow — spawns a
with-skill and a baseline subagent per eval, grades the outputs against each eval's
expectations, aggregates the stats, and opens an HTML review. Use this for a fresh
skill-vs-baseline benchmark or exploratory iteration. Don't wrap it in another testing
skill; skill-creator's own SKILL.md says so.

## Three gotchas (learned the hard way)

1. **Run unsandboxed.** The Python harness uses `ProcessPoolExecutor`, which the command
   sandbox blocks — you'll see `os.sysconf("SC_SEM_NSEMS_MAX")` → `PermissionError:
   Operation not permitted`. Run the benchmark/aggregate/viewer commands outside the
   sandbox (see `/sandbox`). `run-evals.sh` runs the aggregate + viewer steps directly,
   so invoke the whole script unsandboxed.

2. **Do NOT use skill-creator's `scripts/run_eval.py` / `run_loop.py` for this skill.**
   Those are a *triggering probe*: they register a throwaway slash-command holding only the
   description and check whether `claude -p` invokes that probe by name. But `cf-kind-verify`
   is installed as a **user-level skill** (`~/.claude/skills/`), so `claude -p` sees the
   **real** skill from any cwd and invokes *it* instead of the probe — every case scores 0
   triggers even when triggering is correct. The probe assumes the skill isn't installed
   yet; ours is. Use the benchmark workflow above instead.

3. **Contamination: the installed skill leaks into any `claude -p`.** Because
   `~/.claude/skills/cf-kind-verify` is a symlink to this repo, a plain baseline `claude -p`
   still sees the ambient skill from any cwd — a skill-creator `cp -r` snapshot doesn't
   isolate it. `run-evals.sh` closes this by running both configs with
   `--disable-slash-commands` from an isolated `$TMPDIR` cwd, feeding the materialized
   `SKILL.md` via `--append-system-prompt`, parsing the answer from the JSON envelope (so no
   output path is ever handed to the model to follow), and instructing the model never to
   read a `.claude` dir. Both sides are treated symmetrically.

## Regenerate stats / report from existing runs

If you already have graded run dirs and just want to re-aggregate or re-open the viewer,
run these from the skill-creator dir (resolve `$SC` first), unsandboxed:

```bash
SC=$(ls -d ~/.claude/plugins/marketplaces/*/plugins/skill-creator/skills/skill-creator | head -1)
WS=<benchmark-artifacts-dir>

cd "$SC"
python3 -m scripts.aggregate_benchmark "$WS" --skill-name cf-kind-verify
python3 eval-viewer/generate_review.py "$WS" --skill-name cf-kind-verify --benchmark "$WS/benchmark.json"
```

## Note: expectations are populated

Each case in `evals.json` now carries a populated `expectations` array (bare strings —
the concrete flow-reasoning assertions each eval checks). Both `run-evals.sh` and
skill-creator grade against these: `run-evals.sh` bridges the strings into the grader's
`{text, passed, evidence}` objects; skill-creator reads them directly. Edit the
`expectations` in `evals.json` to change what's graded.
