# Agent Skills

Reusable skills for AI coding agents. Each skill is a self-contained folder of Markdown instructions, reference material, and, where useful, helper scripts that walk an agent through a recurring task: talking to the GitHub or GitLab API, running and acting on a SonarQube analysis, or reviewing a change against a repository's own conventions.

The skills follow the [Agent Skills specification](https://agentskills.io/specification), so a client that implements it can load them as they are. The instructions themselves are plain Markdown and shell, and any agent that can read files and run commands can follow them once you point it at the right `SKILL.md`.

## Included skills

| Skill | Purpose |
|---|---|
| [`github-api`](github-api/) | Reads and changes GitHub resources through direct REST and GraphQL requests on GitHub.com, Enterprise Cloud with data residency, or a version-checked Enterprise Server. Covers repository contents, issues, pull requests, releases, checks, and Actions, with extra safeguards for elevated writes. |
| [`gitlab-api`](gitlab-api/) | Reads and changes GitLab resources on gitlab.com or a self-hosted instance. Detects the host from context instead of assuming gitlab.com, and knows when GraphQL is the only complete option, as with epics, work items, and vulnerabilities. |
| [`pr-review`](pr-review/) | Reviews a pull request, branch, or working-tree diff against the repository's own conventions. Findings must cite a file, line, or command output, and the agent runs tests or linters where it can instead of guessing. |
| [`sonarqube-analysis`](sonarqube-analysis/) | Runs a SonarQube scan through Docker, reads Overall Code issues, coverage, and duplication through the Web API, then either fixes each valid finding or transitions it with a recorded justification. Runs only when explicitly requested. |

`github-api` handles GitHub resource operations, while `pr-review` handles judgment about code. When a request needs both, such as "review this PR and post the result", the review comes first and the write happens through `github-api` only after it is authorized.

## Compatibility model

Agents differ in how they discover, trigger, and sandbox skills. This repository separates what carries over unchanged from what you may need to adapt.

**Portable across agents**

- The Markdown instructions in each `SKILL.md`, including the step order, safety rules, and output formats.
- Everything under `references/`, which `SKILL.md` links with relative paths.
- Standalone scripts under `scripts/`. They are ordinary Bash and do not depend on any agent.
- The conventions for credential handling, write confirmation, pagination, and response validation.

**May need adaptation**

- **Location.** Each client looks for skills in its own directories, and some have no skill directory at all.
- **Frontmatter.** Every skill uses the spec's `name` and `description`, plus `compatibility` to state environment requirements. Clients that do not read YAML frontmatter will simply see it as text at the top of the file.
- **Automatic triggering.** Clients that support skills usually match the request against `description`. Others need you to reference the skill explicitly.
- **Tool permissions.** No skill here declares `allowed-tools`. The spec marks that field experimental, and the syntax for pre-approving commands differs between clients. Grant permissions in your client's own configuration if you want fewer prompts.
- **Shell and tooling.** The commands assume Bash with `curl` and `jq`. Each skill's `compatibility` field lists anything else it needs, such as Docker or `git`.

## Installation

A skill is installed by making its folder visible to your agent. Copy or symlink the folder whole, because `SKILL.md` refers to its `references/` and `scripts/` by relative path.

```bash
git clone https://github.com/RafaSantos484/claude-code-skills.git ~/src/agent-skills
```

Then follow whichever case applies to your agent.

**Clients that implement the Agent Skills format.** Copy or symlink the folder into the skills directory your client documents:

```bash
ln -s ~/src/agent-skills/<skill-name> <your-client-skills-dir>/<skill-name>
```

The folder name must stay identical to the `name` field in its `SKILL.md`.

**Example: Claude Code.** User-level skills live in `~/.claude/skills/` and project-level skills in `.claude/skills/` at the repository root. A skill becomes available once its folder is in either location.

```bash
mkdir -p ~/.claude/skills
ln -s ~/src/agent-skills/<skill-name> ~/.claude/skills/<skill-name>
```

Claude Code also accepts an `allowed-tools` frontmatter field that pre-approves commands for a skill. It is left out here on purpose. If you want it for `pr-review`, add it to your local copy using Claude Code's syntax, for example `allowed-tools: Bash(git diff *), Bash(git log *), Read, Grep, Glob`.

**Agents without native skill support.** Keep the folder somewhere the agent can read, and tell it to follow the skill when the task comes up. You can do that in your prompt or in a repository instruction file such as `AGENTS.md`, for example: "For GitLab tasks, follow `tools/agent-skills/gitlab-api/SKILL.md`." The agent then reads the references and scripts from the same folder as needed. Triggering is manual in this mode.

The Claude Code example is the setup this repository is maintained in. The other two describe the general approach and have not been tested against specific clients. None of this implies official support from any vendor, so check your agent's documentation for its current skill locations.

## Credential handling

`github-api`, `gitlab-api`, and `sonarqube-analysis` authenticate only through an exported environment variable. They never read tokens from `.env` files, `.netrc`, CLI configuration, keychains, shell profiles, or anything inside a repository. A single source keeps the agent from picking up a stale or wrongly scoped credential without anyone noticing.

The variable's name is not hardcoded, because many environments export several plausible tokens side by side, such as `GITHUB_TOKEN`, `GH_TOKEN`, and `GITHUB_BOT_TOKEN`, or `SONAR_TOKEN` and `SONARQUBE_PERSONAL_TOKEN`, each tied to a different identity or scope. Every skill resolves the name the same way:

1. **List names only.** In Bash, `compgen -e` prints exported variable names without touching their values. Filter that list with the skill's documented pattern. In other shells, strip values before inspecting anything.
2. **One candidate:** use it.
3. **No candidates:** stop and give the user setup steps.
4. **Several candidates:** ask which one to use, unless the conversation already settles it. Several valid tokens can all succeed against different accounts, so a single question is cheaper than acting under the wrong identity. The skills never probe tokens one by one to find one that works.

Token values are never printed, logged, written to files, or placed in URLs or command arguments. Command arguments can be read by other processes on the same machine, so no example puts a token on a `curl` command line. `github-api` passes the header through a transient curl config. `gitlab-api` and `sonarqube-analysis` pass it as `--header @<(printf ...)`, so curl reads it from a pipe. The SonarScanner container is the one place a token leaves the agent's shell. `docker run -e SONAR_TOKEN` with no `=value` keeps it out of the command's arguments, but Docker stores it in the container's environment. Anyone with access to the Docker daemon can read it there until the container is removed, so run scans only on a Docker host you trust with the token.

How the variable gets into the environment is up to you. Prefer exporting it in the shell that launches the agent, ideally from a secret manager. A line such as `export GITLAB_TOKEN="$(secret-tool lookup service gitlab)"` keeps the token out of plaintext dotfiles. The skills will not write a token into a shell profile for you.

## Repository structure

```text
<skill-name>/
├── SKILL.md       # Frontmatter (name, description, compatibility) and the instructions
├── references/    # Optional: detailed material the agent reads when a step needs it
└── scripts/       # Optional: standalone helpers a person can run directly
```

`scripts/` holds tools for repeatable manual runs, such as `sonarqube-analysis/scripts/run-scanner.sh`. They are separate from the commands an agent runs inline while following `SKILL.md`.

### Naming convention

Skill names take the form `<subject>-<activity>`, in lowercase kebab-case, and the folder name always matches the frontmatter `name`.

- The subject is the service or artifact the skill works on, such as `github`, `gitlab`, `sonarqube`, or `pr`.
- The activity says what the skill does with it. `api` means the skill operates a service only through its HTTP API. Anything broader gets a more specific word: `sonarqube-analysis` also runs a scanner and changes code, and `pr-review` produces an assessment rather than API calls.

New skills should follow the same pattern and avoid names that commonly collide with clients' built-in commands.

## Contributing

These skills encode deliberate constraints. Examples include environment-only credentials, confirmation before outward-facing writes, `pr-review`'s rule that every finding needs evidence, and `sonarqube-analysis`'s exclusive use of Overall Code metrics. If you change a skill, keep the explanations of why each constraint exists. They are there so a later edit does not quietly undo one.

Any new skill that authenticates with a secret should use the resolution procedure above instead of a single hardcoded variable name. Keep agent-specific details out of `SKILL.md`. If something only applies to one client, document it in this README as a labeled example.

## License

[MIT](LICENSE)
