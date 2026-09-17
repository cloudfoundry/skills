# Cloud Foundry Skills

A collection of portable [Agent Skills](https://agentskills.io/) for AI coding
agents that work with Cloud Foundry.

## Available skills

| Skill | Description |
| --- | --- |
| [`cf-kind-verify`](./skills/cf-kind-verify/) | Verify CF component changes on a local cf-on-kind cluster. |

## Install

### GitHub CLI

Install with [GitHub CLI v2.90.0 or later](https://github.blog/changelog/2026-04-16-manage-agent-skills-with-github-cli/).
Use `--scope project` to install it in the current repository.

```bash
gh skill install cloudfoundry/skills <skill-name> \
  --agent opencode --scope user
```

Supported `--agent` values include `opencode`, `claude-code`, `github-copilot`,
`cursor`, `codex`, `gemini-cli`, and `cline`. Compatible harnesses use the
portable `.agents/skills/` project path.

### Agent Skills CLI

Install with [Open Agent Skills](https://www.skills.sh/) installer:

```bash
npx skills add cloudfoundry/skills --skill <skill-name>
```

### Claude Code marketplace

The repository also exposes a Claude Code marketplace adapter:

```
/plugin marketplace add cloudfoundry/skills
/plugin install <skill-name>@cloudfoundry-skills
```

### Manual fallback

You can also manually clone to install them in a harness e.g. due to
lacking `gh skill` support.

Copy or symlink a `skills/<skill-name>` directory into a
directory the harness discovers. Common user-level locations are:

| Harness | Location |
| --- | --- |
| OpenCode | `~/.agents/skills/` or `~/.config/opencode/skills/` |
| Claude Code | `~/.claude/skills/` |
| GitHub Copilot | `~/.agents/skills/` or `~/.copilot/skills/` |
| Cursor | `~/.agents/skills/` or `~/.cursor/skills/` |

For example, OpenCode reads the shared Agent Skills location:

```bash
git clone https://github.com/cloudfoundry/skills
ln -s "$(pwd)/skills/skills/<skill-name>" \
  ~/.agents/skills/<skill-name>
```

## Contributing

See [`CONTRIBUTING.md`](./CONTRIBUTING.md).
