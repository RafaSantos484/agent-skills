# SonarQube Web API Reference

Endpoint catalog for the calls this skill makes. All calls authenticate with
`Authorization: Bearer $SONAR_TOKEN` — a placeholder for whichever environment
variable name was resolved per `SKILL.md` → "1. Authentication" (candidate
discovery, ask-if-ambiguous); substitute the real variable name in every
command below. `$SONAR_URL` is the resolved host (`SONAR_HOST_URL` or
`http://localhost:9000` default). Full official reference is served by the
SonarQube instance itself at `$SONAR_URL/web_api` — fetch that for anything
not covered here, since the
API surface differs slightly across SonarQube versions.

## Measures

```bash
curl -sS -H "Authorization: Bearer $SONAR_TOKEN" \
  "$SONAR_URL/api/measures/component?component=$SONAR_PROJECT_KEY&metricKeys=violations,coverage,uncovered_lines,duplicated_lines_density,duplicated_blocks,ncloc"
```

Useful `metricKeys` (Overall Code — never the `new_` prefixed twins):

| Key                         | Meaning                                    |
| ---------------------------- | ------------------------------------------- |
| `violations`                 | Total open issues.                          |
| `bugs` / `vulnerabilities` / `code_smells` | Issues by type.               |
| `coverage`                   | Overall line coverage percentage.           |
| `uncovered_lines`            | Absolute count of uncovered lines.          |
| `duplicated_lines_density`   | Percentage of duplicated lines.             |
| `duplicated_blocks`          | Absolute count of duplicated blocks.        |
| `ncloc`                      | Non-comment lines of code (size context).   |
| `security_hotspots`          | Open security hotspots (see below — not the same list as issues). |

## Analyses (checking whether a re-scan is needed)

```bash
curl -sS -H "Authorization: Bearer $SONAR_TOKEN" \
  "$SONAR_URL/api/project_analyses/search?project=$SONAR_PROJECT_KEY&ps=1"
```

Returns the most recent analysis first, including a `revision` field holding
the git SHA the scanner auto-detected at analysis time (when a `.git`
directory was present and not excluded). Compare it against `git rev-parse
HEAD` to decide whether `SKILL.md` → "3. Produce a fresh analysis" can be
skipped. `revision` is absent on analyses run without git present — treat
that as "can't confirm freshness," not as "up to date."

## Issue search

```bash
curl -sS -H "Authorization: Bearer $SONAR_TOKEN" \
  "$SONAR_URL/api/issues/search?components=$SONAR_PROJECT_KEY&resolved=false&ps=500"
```

Useful filters (combine with `&`):

| Param              | Meaning                                                             |
| ------------------- | --------------------------------------------------------------------- |
| `resolved=false`    | Open issues only. Omit to include resolved ones.                     |
| `severities=BLOCKER,CRITICAL` | Restrict by severity.                                      |
| `types=BUG,VULNERABILITY,CODE_SMELL` | Restrict by issue type.                             |
| `rules=<repo:rule>` | Restrict to a specific rule (e.g. `typescript:S1234`).               |
| `componentKeys=<file path key>` | Restrict to one file.                                    |
| `p` / `ps`          | Page number / page size (`ps` max is 500).                           |

**Never add `inNewCodePeriod=true`** — that switches the whole query to New
Code, which this workflow deliberately ignores (`SKILL.md` → "4. Fetch Overall
Code measures").

`ps=500` covers most projects in one page; if `total` in the response exceeds
what you fetched, page with `p=2`, `p=3`, … rather than reporting a partial
list as complete.

## Transitions

```bash
curl -sS -X POST -H "Authorization: Bearer $SONAR_TOKEN" \
  "$SONAR_URL/api/issues/do_transition" \
  --data-urlencode "issue=$ISSUE_KEY" \
  --data-urlencode "transition=<transition>"
```

Common `transition` values: `confirm`, `falsepositive`, `wontfix` (older
servers) / `accept` (SonarQube 10.4+), `reopen`, `resolve`. Available
transitions depend on the issue's current status — a `400` response's body
names the valid ones from the current state if the requested transition isn't
legal.

## Comments

```bash
curl -sS -X POST -H "Authorization: Bearer $SONAR_TOKEN" \
  "$SONAR_URL/api/issues/add_comment" \
  --data-urlencode "issue=$ISSUE_KEY" \
  --data-urlencode "text=<justification>"
```

Always pair a transition with a comment explaining why — the next analysis
run does not preserve context otherwise.

## Security hotspots (separate from issues)

Hotspots are not returned by `/api/issues/search`; they have their own
endpoint and their own review statuses (`TO_REVIEW`, `REVIEWED` with
resolution `FIXED`/`SAFE`):

```bash
curl -sS -H "Authorization: Bearer $SONAR_TOKEN" \
  "$SONAR_URL/api/hotspots/search?project=$SONAR_PROJECT_KEY&status=TO_REVIEW"

curl -sS -X POST -H "Authorization: Bearer $SONAR_TOKEN" \
  "$SONAR_URL/api/hotspots/change_status" \
  --data-urlencode "hotspot=$HOTSPOT_KEY" \
  --data-urlencode "status=REVIEWED" \
  --data-urlencode "resolution=SAFE" \
  --data-urlencode "comment=<justification>"
```

`resolution` accepts `FIXED`, `SAFE`, or `ACKNOWLEDGED` (real risk, deliberately accepted without a code change — distinct from `SAFE`, which means no real risk exists).

Only fetch/act on these if the user's request covers hotspots, not just
issues — they are a distinct SonarQube concept (potentially-sensitive code
that needs a human security judgment) rather than a rule violation.

## Errors

- `401` — token missing or invalid. Stop; do not retry unauthenticated.
- `403` — token valid but lacks permission (Browse / Administer Issues) on
  this project. Stop and report which permission is missing.
- `404` on a project/component — usually a wrong `sonar.projectKey`; re-check
  `sonar-project.properties` rather than guessing a key.
- `400` on `do_transition` — the requested transition isn't legal from the
  issue's current status; the response body lists the legal ones.
