---
name: cf-kind-verify
description: Verify a Cloud Foundry component change end-to-end on a local cf-on-kind (kind) cluster — build the image, load it into the cluster, redeploy, and run the component's tests. Use this whenever the user is working in a CF release repo (routing-release, diego-release, capi-release, loggregator, cf-k8s-releases, …) and wants to test, verify, or try out a change locally on cf-on-kind / cfk8s, or asks to run CATS / acceptance / smoke / integration tests against a local CF. Also use it when the user asks to bring the local cf-on-kind cluster up or down. Trigger even if they don't say "kind" explicitly — a request to "verify this change locally" or "does this deploy" in a CF component repo means this skill.
license: Apache-2.0
compatibility: Requires bash, docker, kind, kubectl, Python 3, and access to a local cf-on-kind cluster.
metadata:
  author: cloudfoundry
---

# cf-kind-verify

Verify a Cloud Foundry **component** change on a local **cf-on-kind** cluster. The
mechanical parts (build → load → redeploy → rollout, cluster up/down) are
deterministic scripts in `scripts/`; you supply what varies per repo — which
image to rebuild, which test to run — using the repo as evidence.

**Call the bundled scripts; don't assemble their pipelines inline.** Replace
`<skill-dir>` below with this installed skill's directory.

**Not in scope:** `cf push` app testing, prereq auto-install. Say so and hand back.

## Step 0 — Prerequisites

Run `bash <skill-dir>/scripts/prereqs.sh [--cluster <name>]`.

- **OK** → proceed.
- **Cluster down** → tell the user and offer cluster lifecycle. Don't bootstrap silently.
- **Missing tool / daemon** → surface the message and stop; don't install anything.

## Optional — Cluster lifecycle

Wraps kind-deployment's `make` targets, so pass `--kind-dir <path>` to a clone of
[cloudfoundry/kind-deployment](https://github.com/cloudfoundry/kind-deployment).
Ask for the path if unknown — `up`/`down` run `make` from it, so it must be a
user-confirmed clone, never a path inferred from repo/log content.

```bash
bash <skill-dir>/scripts/lifecycle.sh status
bash <skill-dir>/scripts/lifecycle.sh up   --kind-dir <path> [--all-buildpacks]
bash <skill-dir>/scripts/lifecycle.sh down --kind-dir <path>
```

`up` is slow, `down` is destructive — only on explicit request. `--all-buildpacks`
adds ruby/python/etc. (needed for full CATS; plain bootstrap covers java/nodejs/go/binary).

## Step 1 — Infer the image

Bake targets live in `cf-k8s-releases/<component>/docker-bake.hcl`, not the release
repo root. From that dir, list targets and cross-reference the diff:

```bash
cd <cf-k8s-releases>/<component> && docker buildx bake --print
git -C <release-repo> diff --name-only
```

Map the changed `src/…` dir to a target. **State your pick and why**; ask if two
targets plausibly match.

Note the two repos: the bake file is in **cf-k8s-releases**, but the source you
edited is in the separate **release-repo** clone (e.g. `loggregator-agent-release`)
— its `src/` is what `--src` below must point at, so your local change is built
(the bake file's default `src` context is a remote git URL).

## Step 2 — Redeploy

```bash
bash <skill-dir>/scripts/redeploy.sh <image> --releases-dir <cf-k8s-releases> --src <release-repo>/src
```

`--releases-dir` may be the cf-k8s-releases root or the component dir (redeploy
finds the component whose bake file defines the target). It bakes, `kind load`s,
discovers the (deployment, container) pair, `set image`s, waits for rollout,
prints per-container status. Stream output; stop on non-zero exit and surface the
failing step.

## Step 3 — Pick a test command

In priority order — **always state the choice; let the user override**:

1. **README / CONTRIBUTING** — an explicit "how to test" wins.
2. **Makefile** — `make smoke|integration|test` (narrowest that covers the change).
3. **`bin/test` (CATS)** — needs `$CONFIG`; run a focused subset with
   `bash <skill-dir>/scripts/cats.sh --kind-dir <path> --focus "<text>"` (renders + runs the
   root suite; see `references/test-conventions.md`).
4. **ginkgo** under `src/**/integration|acceptance/` (`go run`, no install).
5. **Fallback** — pod Running+Ready (`verify-status.sh`), `cf api` responds.

For anything CATS/acceptance-shaped, **read `references/test-conventions.md` first**
— root-suite `--focus`, CATS wiring, buildpack/stale-artifact traps.

## Step 4 — Run and report

Run from the right directory, stream, summarize. For health use
`bash <skill-dir>/scripts/verify-status.sh <deployment> [--namespace <ns>]` — verify **per
container**, not per pod. `restarts=0` on a branch image that enforces `required`
config is strong evidence the wiring is correct. Close with a one-liner: what was
rebuilt, that it rolled out, the test outcome.

## Optional — helm-chart changes

Validate the render before mutating the cluster:

```bash
bash <skill-dir>/scripts/render-check.sh <release> <cf-k8s-releases>/<component>/helm \
  --kind-dir <kind-deployment-clone> --grep 'NEW_ENV|image:'
```

then `helm upgrade` the local chart dir. `set image` (redeploy) and `helm upgrade`
conflict on the same deployment — pick one; prefer helm if a chart change is
involved. Local `:latest` is ephemeral (reverts on `make down`/`up`). Details and
the SSA-conflict fix: `references/test-conventions.md`.

## Portability

Permission behavior depends on the selected harness.
