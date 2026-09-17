## Contributing

Contributions are welcome. This is a collection of portable Cloud Foundry Agent
Skills.

For Cloud Foundry Foundation repositories, contributors must sign the
[Contributor License Agreement](https://corporate.v1.easycla.lfx.linuxfoundation.org/).
EasyCLA prompts you when you open your first pull request.

### Dev setup

```bash
git clone https://github.com/cloudfoundry/skills
cd skills
mkdir -p ~/.config/opencode/skills
ln -s "$(pwd)/skills/<skill-name>" ~/.config/opencode/skills/<skill-name>
```

This symlink is the recommended edit-test workflow: changes to a skill are
available in new OpenCode sessions without reinstalling it. `gh skill install
--from-local` copies files rather than creating a symlink, so use it only to
test the installation flow. Remove a copied installation before creating the
symlink:

```bash
rm -rf ~/.config/opencode/skills/<skill-name>
```

### Checks

Run before opening a PR — CI runs the same target:

```bash
make check   # Claude marketplace + shellcheck + JSON validation
```

### Making changes

- Each skill lives in `skills/<skill-name>/`; keep scripts and references with its `SKILL.md`.
- Keep `SKILL.md` portable. Put harness-specific packaging or configuration under the skill's `docs/<harness>/` directory.

### Commits and PRs

- Fork the repository, create a branch, and open a pull request from that branch.
- Small, focused PRs.
### Getting help

- Report bugs or propose skills with an issue in this repository.
- Ask usage questions in [#wg-ai](https://cloudfoundry.slack.com/archives/C0B214KJ1HA) channel within Cloud Foundry Slack.
- Discuss broader agent-workload design with the [Agentic Runtime working group](https://github.com/cloudfoundry/community/blob/main/toc/working-groups/WORKING-GROUPS.md#agentic-runtime).

### Code of conduct

This project follows the [Cloud Foundry Code of Conduct](./CODE_OF_CONDUCT.md).

Licensed under Apache-2.0.
