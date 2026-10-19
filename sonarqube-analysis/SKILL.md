---
name: sonarqube-analysis
description: Run a SonarQube analysis and act on its findings. Generates coverage, runs the SonarScanner CLI through Docker, reads Overall Code issues, coverage, and duplication through the SonarQube Web API, fixes valid issues, and transitions false positives or accepted findings with a recorded justification. Use only when the user explicitly asks for SonarQube work, such as "run SonarQube", "fix the SonarQube issues", "check code quality with SonarQube", "improve SonarQube coverage or duplication", or "set up SonarQube for this project", including projects that have no sonar-project.properties yet.
compatibility: Requires Bash, git, curl 7.55 or later (for reading headers from a file with -H @file), jq, Docker, and network access to a SonarQube server. The documented scanner command uses --network host, which works on Linux only. Credentials come only from an exported environment variable.
---

# SonarQube analysis and remediation

This skill produces a SonarQube analysis for any codebase and acts on what it
reports. It covers authentication, running the scanner, reading **Overall
Code** measures, and sorting issues into real fixes and transitioned false
positives.

This is an **opt-in** workflow. Run it only when the user explicitly asks for
a SonarQube run, a fix of SonarQube findings, or a quality-score improvement.
Never start it because a change "looks quality-related," and never fold it
into an unrelated task's validation.

Resolve these in order before touching code or the API:

1. **Auth token** — [1. Authentication](#1-authentication)
2. **Project identity** — [2. Identify the project](#2-identify-the-project)
3. **A fresh analysis** — [3. Produce a fresh analysis](#3-produce-a-fresh-analysis)
4. **Overall Code data** — [4. Fetch Overall Code measures](#4-fetch-overall-code-measures)
5. **Triage** — [5. Triage every issue before touching code](#5-triage-every-issue-before-touching-code)

## 1. Authentication

Authenticate **only** through an exported environment variable holding a
**User Token**. A Project Analysis Token can submit scans but cannot read or
transition issues. The variable's name is not fixed to `SONAR_TOKEN`, because
real setups often export several candidates side by side (`SONAR_TOKEN`,
`SONAR_BOT_TOKEN`, `SONARQUBE_PERSONAL_TOKEN`, …). Discover which ones exist
before picking one.

- **List candidate variable names only, never their values:**
  ```bash
  compgen -e | LC_ALL=C sort -u | grep -iE '^[A-Z0-9_]*SONAR[A-Z0-9_]*TOKEN[A-Z0-9_]*$'
  ```
  `compgen -e` prints exported variable names without reading their values,
  so no token can appear in the output.
- **Exactly one candidate** → use it, referring to it as `$SONAR_TOKEN` in the
  rest of this doc regardless of its actual name (every command below is
  written against that placeholder — substitute the real name you resolved).
- **Zero candidates** → treat auth as missing (see below).
- **More than one candidate** → do not guess which one is "the" token. Ask
  the user which variable to use, unless something in the conversation
  already disambiguates it (e.g. the user already named one, or the task
  explicitly targets a project/org that only one candidate's name plausibly
  maps to). When genuinely in doubt, ask — silently picking one risks acting
  under the wrong identity or permission set.
- This workflow **never** reads the token from a file (`.env`,
  `.env.local`, CI variable files, IDE settings, shell profiles, or anything
  inside a repo) and never prompts for it. The variable must already be
  exported in the environment the agent runs in.
- **Never print, log, echo, decode, or summarize the token.** Never put it in
  a URL query string (`curl -v`/`--trace` dumps headers — avoid those flags on
  authenticated calls too). Send it only in an `Authorization: Bearer`
  header, and never place it directly on a command line, because command
  arguments are visible to other processes. Every example below passes it
  as `-H @<(printf 'Authorization: Bearer %s\n' "$SONAR_TOKEN")`: `printf`
  is a Bash builtin, so the value only travels through a pipe and curl's
  argument list shows `@/dev/fd/N`. A process substitution can be read once,
  so give each `curl` call its own. Never copy the token into a file,
  commit, test fixture, or message to the user.
- **If no candidate variable is set, stop.** Do not call the API, do not fall
  back to an unauthenticated request, and do not guess a token. Give the user
  this setup procedure and end the workflow:

  1. In SonarQube → avatar → **My Account** → **Security** → **Generate
     Tokens** → choose **User Token**. The account needs **Browse** and
     **Administer Issues** permission on the target project (and on every
     other project this same global token will be used for).
  2. Export it in the shell that starts the agent session, under any
     SonarQube-token-shaped name (`SONAR_TOKEN` by default, or a more
     specific name if the user already has a naming convention). Reading it
     without echo keeps it out of shell history:
     ```bash
     read -r -s -p 'SonarQube token: ' SONAR_TOKEN; printf '\n'; export SONAR_TOKEN
     ```
     To make it available in every session, load it from a secret manager
     when the shell starts rather than writing the token itself into a
     plaintext profile such as `~/.bashrc`.
  3. Never put it in a project file. The environment is the only place this
     workflow looks.

  Re-run the workflow in a session where the variable is exported.

The only interactive token prompt is in the standalone scanner runner
described in [3. Produce a fresh analysis](#3-produce-a-fresh-analysis). That
script is meant for a person at a terminal, and the agent workflow never
relies on it.

## 2. Identify the project

**Host.** The default is `http://localhost:9000`; `SONAR_HOST_URL` overrides
it for a remote or differently-ported server. Never assume `localhost:9000`
is correct without checking `SONAR_HOST_URL` first — some setups point at a
shared or cloud instance.

**Project key.** Look for `sonar-project.properties` at the repository root
and read `sonar.projectKey=` from it — never hardcode a key guessed from the
directory name:

```bash
SONAR_PROJECT_KEY="$(sed -n 's/^sonar\.projectKey=//p' sonar-project.properties)"
SONAR_URL="${SONAR_HOST_URL:-http://localhost:9000}"
```

**No `sonar-project.properties` yet?** This is a first-time setup, not a
blocker — create a minimal one at the repo root before scanning:

```properties
sonar.projectKey=<kebab-case-name, e.g. the repo/package name>
sonar.projectName=<human-readable name>
sonar.sources=<the main source root, e.g. src>
sonar.sourceEncoding=UTF-8
```

Add a coverage report path (`sonar.javascript.lcov.reportPaths`,
`sonar.python.coverage.reportPaths`, …) and test/exclusion globs once you know
the stack — see `references/scanner-config.md` for language-specific keys and
the comma-splitting pitfall with brace globs. Check whether the project
already has coverage-exclusion conventions (declaration-only files with no
branch/loop/I-O) documented anywhere before inventing new ones; mirror
whatever the project's own test runner already excludes from coverage so the
two stay in agreement.

## 3. Produce a fresh analysis

Skip this step if the server already has an analysis current with the working
tree. Check concretely rather than assuming:

```bash
LAST_REVISION="$(curl -sS -H @<(printf 'Authorization: Bearer %s\n' "$SONAR_TOKEN") \
  "$SONAR_URL/api/project_analyses/search?project=$SONAR_PROJECT_KEY&ps=1" \
  | jq -r '.analyses[0].revision // empty')"
git rev-parse HEAD
```

If `LAST_REVISION` matches `git rev-parse HEAD` and `git status --porcelain` is
empty (no uncommitted changes), the server's analysis already reflects the
working tree — skip to step 4. An empty/missing `revision` (scanner run
without git present, or an old analysis predating this check) means freshness
can't be confirmed this way; re-scan rather than guess.

Otherwise:

1. **Generate a coverage report**, if the project has tests. Use whatever the
   project's own manifest already exposes for this (e.g. a `test:coverage` /
   `coverage` script in `package.json`, `pytest --cov`, `go test -cover`, …).
   Don't invent a new coverage command; find and reuse the project's existing
   one, and don't add one if none exists. Skipping this step still lets the
   scanner run — it will just report 0% coverage.
2. **Run the SonarScanner CLI via Docker** — no native install required:

   ```bash
   docker run --rm --network host \
     -e SONAR_HOST_URL -e SONAR_TOKEN \
     -v "$(pwd):/usr/src" \
     --user "$(id -u):$(id -g)" \
     sonarsource/sonar-scanner-cli
   ```

   `-e SONAR_HOST_URL` / `-e SONAR_TOKEN` (no `=value`) copy the values from
   the **calling shell's** environment, so the token never appears in the
   `docker` command's own arguments. Docker still stores it in the
   container's environment, which anyone with access to the Docker daemon can
   read through `docker inspect` until `--rm` removes the container. Run the
   scan only on a Docker host whose daemon access you already trust with the
   token.

   If the variable resolved in step 1 has a different name (e.g.
   `SONAR_BOT_TOKEN`), set the name the scanner expects for this one command
   only, rather than exporting it into the session:

   ```bash
   SONAR_TOKEN="$SONAR_BOT_TOKEN" docker run --rm --network host \
     -e SONAR_HOST_URL -e SONAR_TOKEN \
     -v "$(pwd):/usr/src" \
     --user "$(id -u):$(id -g)" \
     sonarsource/sonar-scanner-cli
   ```

   The prefix assignment is expanded by the shell into the `docker`
   process's environment, not its arguments. Never write
   `-e SONAR_TOKEN="$SONAR_BOT_TOKEN"`, which puts the value in the argument
   list.

   `--network host` is
   Linux-only and is what lets a `localhost:9000` server on the host be
   reachable from inside the container; it does not work under Docker Desktop
   on macOS/Windows, where the host's SonarQube must instead be reached via
   `host.docker.internal`. `--user "$(id -u):$(id -g)"` keeps files the
   scanner writes into the bind mount (`.scannerwork/`) owned by the calling
   user, not root.

   `scripts/run-scanner.sh` wraps this exact command for people who want a
   repeatable local scan without asking an agent each time. Point the user at
   it (`bash <path-to-skill>/scripts/run-scanner.sh`, or copy it into the
   project as `scripts/sonar.sh`). When run from a terminal, it prompts for
   any value that isn't exported: `SONAR_HOST_URL`, where blank input means
   `http://localhost:9000`, and `SONAR_TOKEN`, with hidden input. Without a
   terminal it never prompts and exits if `SONAR_TOKEN` is missing.

   When you run the scan as the agent, do not use the script. Run the
   `docker run` command above directly, with the token and host already
   resolved from the environment in step 1, so nothing can prompt mid-task.

3. Confirm the scanner logs `EXECUTION SUCCESS` before moving on to the API
   steps — a failed scan leaves stale data on the server that step 4 would
   otherwise silently read as current.

## 4. Fetch Overall Code measures

**Use Overall Code metrics only.** Never use or prioritize New Code metrics
(`new_coverage`, `new_violations`, `new_duplicated_lines_density`, …), and
never pass `inNewCodePeriod=true` to `/api/issues/search` — New Code measures
a moving period, not the state of the codebase. Do not judge the project by
the quality-gate endpoint either: the default gate is conditioned almost
entirely on New Code, so a passing gate says nothing about Overall Code. Read
the Overall Code measures directly.

```bash
# Overall Code measures
curl -sS -H @<(printf 'Authorization: Bearer %s\n' "$SONAR_TOKEN") \
  "$SONAR_URL/api/measures/component?component=$SONAR_PROJECT_KEY&metricKeys=violations,coverage,uncovered_lines,duplicated_lines_density,duplicated_blocks,ncloc" \
  | jq '.component.measures'

# Open issues (no inNewCodePeriod filter — Overall Code)
curl -sS -H @<(printf 'Authorization: Bearer %s\n' "$SONAR_TOKEN") \
  "$SONAR_URL/api/issues/search?components=$SONAR_PROJECT_KEY&resolved=false&ps=500" \
  | jq '.issues[] | {key, rule, severity, component, line, message}'
```

A `401`/`403` means the token is invalid or lacks permission — report that and
stop; it is not a reason to retry unauthenticated. `references/api-reference.md`
catalogs the rest of the endpoints (pagination, filtering by severity/rule/
file, hotspots) beyond the two used here.

Focus areas, in priority order: **issues**, then **test coverage**, then
**code duplication**. Full triage procedure, including how to fix vs.
transition an issue and the API calls for `do_transition`/`add_comment`, is in
`references/remediation-workflow.md` — read it before touching any issue.

## 5. Triage every issue before touching code

The short version (full detail in `references/remediation-workflow.md`):

- **Valid issue → fix the code**, following the project's own standards.
  Read its agent instruction files (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`,
  `.github/copilot-instructions.md`, or similar), `CONTRIBUTING.md`, and
  style guide, whichever exist, before editing. A SonarQube finding never justifies a shortcut, a
  suppression comment, or a cross-cutting refactor the user did not ask for.
  Update the project's own tests and docs alongside the fix, as its
  conventions require.
- **False positive or not worth changing → transition it via the API, leave
  the code alone.** Never edit source purely to silence a finding.
- **Always record why** with `add_comment` so the decision survives the next
  analysis, and report every transition to the user with its justification.
- **Improve coverage/duplication only where genuinely justified** — no
  placeholder tests, no speculative extractions just to move a number.
- **Re-run validation** (the project's own lint/typecheck/test/build commands)
  after any code change, then re-scan and re-read Overall Code measures to
  confirm the findings actually moved.

## Reference files

- `references/remediation-workflow.md` — the full triage procedure: deciding
  fix vs. transition, the `do_transition`/`add_comment` calls, coverage and
  duplication guidance, and the re-validation loop.
- `references/api-reference.md` — SonarQube Web API catalog: measures, issue
  search/filtering, transitions, comments, hotspots, pagination.
- `references/scanner-config.md` — writing or extending
  `sonar-project.properties` for a given language/stack, and the
  brace-glob-splits-on-commas pitfall.
- `scripts/run-scanner.sh` — standalone runner for people at a terminal:
  prompts for `SONAR_HOST_URL` (blank → `http://localhost:9000`) and hidden
  `SONAR_TOKEN` when unset, then runs the Docker scanner command from step 3.
  Not used by the agent workflow.
