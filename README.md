# Claude Code Skills

A small collection of custom [Claude Code](https://docs.claude.com/en/docs/claude-code) skills — reusable instruction sets that Claude loads automatically when a task matches, so it follows a consistent, battle-tested procedure instead of improvising each time.

## What's here

| Skill | What it does |
|---|---|
| [`gitlab-api`](gitlab-api/) | Drives GitLab's REST and GraphQL APIs — issues, merge requests, branches, pipelines, labels, epics/work items, members. Authenticates only via an environment variable holding a GitLab token (never from files or CLI config) — see [Environment variable resolution](#environment-variable-resolution) below for how it's chosen among several possible candidates — auto-detects the GitLab host from context instead of assuming `gitlab.com`, and knows when to prefer GraphQL over REST (e.g. epics, vulnerabilities — resources where REST is deprecated or incomplete). |
| [`github-api`](github-api/) | Reads and changes GitHub repository resources through direct REST and GraphQL requests on GitHub.com or a version-checked Enterprise Server. Uses only a selected environment token; covers repository contents, issues, pull requests, releases, checks, and Actions with explicit safeguards for sensitive writes. Use `pr-review` for evidence-based code review; use `github-api` for GitHub resource operations such as listing PR files or posting an authorized review. |
| [`pr-review`](pr-review/) | Turns Claude into a rigorous, evidence-only code reviewer against a live git repository — reads the repo's own conventions first (`CLAUDE.md`, linter config, etc.), verifies claims by actually running tests/lint instead of guessing, and outputs a structured review with severity-tagged findings. |
| [`sonarqube-analysis`](sonarqube-analysis/) | Runs a SonarQube analysis (coverage generation plus the SonarScanner CLI via Docker) and triages what it reports — issues, coverage, duplication — via the Web API. Authenticates only via an environment variable holding a SonarQube user token — see [Environment variable resolution](#environment-variable-resolution) below — judges the codebase exclusively on Overall Code metrics (never the New Code period or the quality-gate endpoint), and either fixes a valid finding in code or transitions a false positive/accepted one with a recorded justification — never both. Opt-in only: it runs when explicitly asked, not as a side effect of other work. |

## Installation

Claude Code loads skills from `~/.claude/skills/` (global, all projects) or `.claude/skills/` inside a specific repo (project-scoped).

```bash
git clone <this-repo-url> /tmp/claude-skills
cp -r /tmp/claude-skills/<skill-name> ~/.claude/skills/
```

Or clone straight into place:

```bash
git clone <this-repo-url> ~/.claude/skills-shared
ln -s ~/.claude/skills-shared/<skill-name> ~/.claude/skills/<skill-name>
```

Claude picks up a skill automatically once its folder is in a recognized skills directory — no restart or registration step needed. Each skill's `SKILL.md` frontmatter (`description:`) is what Claude matches against your request to decide when to trigger it.

## Environment variable resolution

Several skills here (`gitlab-api`, `github-api`, `sonarqube-analysis`) authenticate exclusively
through an environment variable holding a secret token, and refuse to read
that secret from any file, CLI config, or keychain. But the variable's exact
**name** is deliberately not hardcoded to one value (`GITLAB_TOKEN`,
`SONAR_TOKEN`, …), because real environments commonly export more than one
plausible candidate side by side — for example `GITLAB_TOKEN`,
`GITLAB_BOT_TOKEN`, `GITLAB_PERSONAL_TOKEN`, `GITLAB_ANPD_PERSONAL_TOKEN`,
`GITHUB_TOKEN`, `GH_TOKEN`, `GH_ENTERPRISE_TOKEN`, `GITHUB_BOT_TOKEN`, or
`SONAR_TOKEN`, `SONAR_BOT_TOKEN`, `SONARQUBE_PERSONAL_TOKEN` — each scoped to
a different identity, project, or permission level. Silently picking one
would risk acting under the wrong identity.

Every skill that depends on a token-shaped environment variable follows the
same resolution procedure:

1. **Enumerate candidate variable names only, never their values** — in Bash,
   `compgen -e` lists exported names without ever reading values. Filter those
   names with the relevant skill's documented pattern. If using an `env`-based
   approach instead, strip values before displaying or inspecting output.
2. **Exactly one candidate** → use it, no confirmation needed.
3. **Zero candidates** → treat auth as missing and follow the skill's normal
   "not configured" path (usually: stop and hand the user setup steps).
4. **More than one candidate** → don't guess. Ask the user which variable to
   use, unless the conversation already disambiguates it unambiguously (the
   user already named one, or the task only maps to one candidate). This is
   the one case worth pausing for: several correctly-formed tokens can all
   "work" while pointing at different accounts, projects, or scopes, and
   picking the wrong one silently is worse than a single clarifying question.

This procedure is a project-wide convention, not something specific to
GitLab or SonarQube — any new skill added here that authenticates via a
secret environment variable should follow the same three-way logic (single
candidate → use it, none → stop and explain, multiple → ask) rather than
hardcoding one variable name and failing when the user's environment uses a
different one.

## Structure

Each skill is a folder containing:

- `SKILL.md` — the entry point: frontmatter (`name`, `description`, optionally `allowed-tools`) plus the instructions Claude follows.
- `references/` (optional) — supplementary docs too detailed for the main file, which Claude reads on demand.
- `scripts/` (optional) — standalone helper scripts the skill points users to for repeatable manual runs (e.g. `sonarqube-analysis/scripts/run-scanner.sh`), as distinct from commands Claude runs itself inline.

## Contributing

These skills encode specific workflow opinions (e.g. `pr-review`'s evidence-only rule, `gitlab-api`'s env-var-only auth with [multi-candidate resolution](#environment-variable-resolution), `sonarqube-analysis`'s Overall-Code-only rule). If you adapt one, keep the reasoning ("why") comments intact where present — they exist so future edits don't accidentally undo a deliberate constraint.

## License

[MIT](LICENSE) — permissive, simple, and standard for this kind of content: mostly instructional markdown with embedded code/shell examples, no patent-sensitive material that would call for Apache 2.0, and no reason to restrict reuse or adaptation.
