# Permission setup

This Claude Code adapter is optional. The skill works without it, but prompts for
the docker/kind/kubectl steps. To silence them, merge
[`settings.json`](./settings.json) into your **project** `.claude/settings.json`
(not `~/.claude/`), replacing:

- `/Users/YOU` → your home directory
- the script paths → wherever the skill lives (the plugin cache under
  `~/.claude/plugins/cache/…`, or your clone)

`sandbox.*` changes need a session restart.

> Not bundled with the plugin: Claude Code ignores permission/sandbox blocks in a
> plugin's `settings.json`, so this is a manual step.

## What the config does

Two paired blocks — a command needs **both**:

- `sandbox.excludedCommands` — runs docker/kind/kubectl/scripts **outside** the
  sandbox so they reach the daemon.
- `permissions.allow` — stops those same commands from prompting.

It allowlists the shipped scripts plus a short list of explicit read verbs
(`kubectl get pods/deployment/nodes/replicasets`, `docker buildx bake --print`,
`kind get/load`) — tighter than a `kubectl *` / `docker *` / `kubectl get *`
wildcard (which would allow `get secret` exfil).

## Security note

`excludedCommands` runs a command **unsandboxed** — outside the filesystem
`denyRead` and network-egress limits the sandbox otherwise enforces — so it is
inherently **less safe than a properly isolated environment**. To keep that
exposure small, the config allowlists only the shipped scripts plus explicit read
verbs (rather than broad `kubectl *` / `docker *` wildcards), and the scripts
validate their own sensitive inputs.

These measures reduce the blast radius but are **not a hard boundary** — a
permission allowlist can't fully constrain an unsandboxed command. Treat the
script validations as backstops, and only pass paths/flags the user supplied,
never ones inferred from repo or log content.

If a hard boundary matters, prefer an isolated environment with scoped
credentials (ephemeral container/VM, limited RBAC) over widening
`excludedCommands` — and don't open the sandbox to `~/.kube` / `~/.docker` / the
docker socket to silence prompts.

Zero-prompt read-only spot-checks also depend on your global
`sandbox.autoAllowBashIfSandboxed`; without it, ad-hoc read-only commands the
allowlist doesn't enumerate will prompt.
