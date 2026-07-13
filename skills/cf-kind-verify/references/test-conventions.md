# Test conventions & gotchas (cf-kind-verify)

Read this when the change involves acceptance/CATS tests, ginkgo suites, or a
helm-chart edit. Contents:

- [CATS: run the root suite with --focus](#cats-run-the-root-suite-with---focus)
- [CATS is already wired in kind-deployment](#cats-is-already-wired-in-kind-deployment)
- [Buildpacks](#buildpacks)
- [Helm-chart changes: render, upgrade, SSA conflict](#helm-chart-changes)
- [Config-contract source of truth](#config-contract-source-of-truth)

## CATS: run the root suite with --focus

Use the bundled **`<skill-dir>/scripts/cats.sh`** — it renders the config and runs a
focused subset the right way, from any cwd:

```bash
bash <skill-dir>/scripts/cats.sh --kind-dir <kind-deployment> \
  --focus "Syslog Drain source type filter over TCP" [--cats-dir <cf-acceptance-tests>] [--timeout 45m]
# or just render the config and stop:
bash <skill-dir>/scripts/cats.sh --kind-dir <kind-deployment> --render-only
```

`--cats-dir` defaults to `<kind-dir>/../cf-acceptance-tests`. This is a script
rather than an inline command because the render writes into the kind-deployment
repo and the run writes `assets/` and accesses the cluster and Docker. Permission
behavior depends on the selected harness and its configuration.

The CATS-specific traps (no `*_suite_test.go` in the package dirs so only the root
suite collects specs; `--focus` not `FDescribe`) are documented in the script's own
header comment — read `<skill-dir>/scripts/cats.sh` if you need to run by hand or change
its behavior.

## CATS is already wired in kind-deployment

Don't hand-roll `integration_config.json` — kind-deployment ships the wiring:

- `scripts/cats.sh` (in kind-deployment) — renders `.github/cats-config.tpl` →
  `.github/cats-config.json` via `python3 os.path.expandvars` after
  `source temp/secrets.sh`, then runs the suite via `<CATS>/bin/test` (with
  `--randomize-all`), forwarding any extra args (kind-deployment PR #489). So a
  focused run is just `scripts/cats.sh --focus="<text>"`. `CATS_PATH` defaults to
  `../cf-acceptance-tests`. The skill's `<skill-dir>/scripts/cats.sh` is a thin shim
  over this — prefer it over calling this one by hand.
- `.github/cats-config.tpl` — full config: `api/apps_domain=…127-0-0-1.nip.io`,
  `admin_user=ccadmin`, `skip_ssl_validation`, the `include_*` suite toggles,
  `timeout_scale: 2`. Secrets (`CC_ADMIN_PASSWORD`, `OAUTH_CLIENTS_SECRET`) come
  from `temp/secrets.sh`.
- `.github/workflows/kind-cats.yaml` — the canonical CI ordering to mirror:
  `make up → login → bootstrap-complete → cf push smoke test → register nfs
  broker → docker compose extra services → setup-cf-tests → bin/test --procs=4`.

## Buildpacks

- **Buildpacks must be uploaded before pushing apps.** Plain `make bootstrap`
  loads only java/nodejs/go/binary; ruby/python/etc. need **`ALL_BUILDPACKS=true`**
  (i.e. `make bootstrap-complete`, or the `--all-buildpacks` flag on
  `lifecycle.sh up`). Symptom otherwise: CATS bails in `SynchronizedBeforeSuite`
  with *"Missing the ruby buildpack specified in the integration_config.json"*.
  The upload script reads `cf curl /v3/buildpacks`, so it needs a **valid login**
  first (a null / `Cannot iterate over null` from `jq` means the token expired —
  re-login).

## Helm-chart changes

`make up`/`helmfile sync` uses the **published** chart, so local chart edits are
only exercised via a direct `helm upgrade` against the local chart dir
(`cf-k8s-releases/<component>/helm/`) — no need to edit
`kind-deployment/helmfile.yaml.gotmpl`.

```bash
cd <kind-deployment>
export KUBECONFIG=temp/kubeconfig                 # written by `make up`
bin/helm get values <release> -n cf-system        # base values
# build /tmp/values.yaml = those + image overrides to your branch :latest build
# validate the render FIRST (use render-check.sh):
bash <skill-dir>/scripts/render-check.sh <release> ../cf-k8s-releases/<component>/helm \
  --kind-dir . --values /tmp/values.yaml --grep 'NEW_ENV|image:'
bin/helm upgrade <release> ../cf-k8s-releases/<component>/helm -n cf-system -f /tmp/values.yaml
kubectl -n cf-system rollout status deployment/<DEPLOYMENT> --timeout=120s
```

- **Override images to your branch `:latest`.** The published image may predate a
  newly-`required` config field and run fine without it, hiding the bug; your
  branch build enforces it.
- **`helm` isn't on PATH** — it's installed into `kind-deployment/bin/` by
  `scripts/tools.sh`. Pass `--kind-dir` so `render-check.sh` uses it.
- **SSA conflict if redeploy ran first:** a prior `kubectl set image`/`set env`
  makes `helm upgrade` fail with `conflict with "kubectl-set"`. Fix:
  `kubectl -n cf-system delete deployment <DEPLOYMENT>` then re-upgrade. Redeploy
  and helm don't compose on the same deployment in one session — **if a chart
  change is involved, prefer helm from the start.**

## Config-contract source of truth

- `<release-repo>/src/cmd/<component>/app/config.go` — `env:"..."` tags,
  `required` markers.
- BOSH job `jobs/<job>/templates/bpm.yml.erb` — correct values/naming.
- CF agents print an **env-struct config report** at startup (every field, its env
  var, whether `required`, resolved value) — the single best signal that chart
  wiring is correct. Grep the startup logs for it.
- Client connections are often **lazy** (dial on first use) — "no connection log
  yet" is normal; trigger the real code path to see it.

## App-level CATS (informs the deferred v2 `app` flow)

When you do need to push an app and run app-level CATS, reuse kind-deployment's
existing CATS wiring (above) rather than reinventing `integration_config.json`.
Mirror the `kind-cats.yaml` ordering and use `--all-buildpacks` at bring-up. This
is not a first-class v1 flow — do it only on explicit request.
