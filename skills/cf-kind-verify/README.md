# cf-kind-verify

Verify a Cloud Foundry component change on a local
[cf-on-kind](https://github.com/cloudfoundry/kind-deployment) cluster:
build, load, redeploy, roll out, and test.

- **Build:** create the changed component image with `docker buildx bake`.
- **Load:** import that local image into the kind cluster.
- **Redeploy:** find the running Deployment and container, then point it at the new image.
- **Rollout:** wait for Kubernetes to replace the old Pods and report the Deployment ready.
- **Test:** run the component's relevant test command against the updated cluster.

## What it does

Given a change in a CF release repo, the skill follows this sequence:

1. Check prerequisites with `prereqs.sh`.
2. **Agent:** offer and, when approved, manage cluster lifecycle with `lifecycle.sh`.
3. For Helm-chart changes, render the chart before mutating the cluster with `render-check.sh`.
4. **Agent:** select and explain the changed image, then build, load, redeploy, and roll out with `redeploy.sh` (which invokes `discover-target.sh` to find the Deployment, container, and namespace).
5. Verify containers and report the rollout with `verify-status.sh`.
6. **Agent:** select, explain, and run focused CATS with `cats.sh` when appropriate.

## Claude Code permissions

The skill works without additional configuration, though Claude Code prompts for
the docker/kind/kubectl steps. To reduce those prompts, merge
[`docs/claude-code/settings.json`](./docs/claude-code/settings.json)
into your project `.claude/settings.json`, then restart the session.

See [`docs/claude-code/permissions.md`](./docs/claude-code/permissions.md)
for what to edit, how the config works, and the security trade-offs of running
these commands unsandboxed.

## Scripts

| Script | Purpose |
| --- | --- |
| `prereqs.sh` | Tools + `cfk8s` cluster + kube-context ready? |
| `lifecycle.sh` | `up` / `down` / `status` |
| `redeploy.sh` | Build → load → redeploy (discover + set image) → rollout → status |
| `discover-target.sh` | Map an image to its `(deployment, container, namespace)` |
| `cats.sh` | Render the kind-deployment CATS configuration and run focused CATS tests |
| `verify-status.sh` | Per-container ready/restarts/image for a deployment |
| `render-check.sh` | `helm template … \| grep` render validation |

## Scope

**v1:** CF component verification + cluster up/down. **Deferred (v2):** first-class
`cf push` app testing, discovery cache, prereq auto-install. App-level CATS notes:
[`references/test-conventions.md`](./references/test-conventions.md).

## References

- [cf-on-kind local development guide](https://github.com/cloudfoundry/kind-deployment/blob/main/docs/local-development-guide.md)
- [`references/test-conventions.md`](./references/test-conventions.md) — CATS focus gotcha, helm SSA conflict, config-contract sources.
