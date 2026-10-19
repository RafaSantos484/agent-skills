# Remediation Workflow

The full triage procedure behind the condensed version in `SKILL.md` → "5.
Triage every issue before touching code." Read `SKILL.md` first — it covers
authentication, project identification, and running the scan; this file picks
up once you have Overall Code measures and an issue list in hand.

## Principle: Overall Code, never New Code

Every decision here is driven by **Overall Code** (`violations`, `coverage`,
`duplicated_lines_density`), never the `new_`-prefixed counterparts and never
the quality-gate endpoint. New Code measures a moving period defined by the
project's baseline setting (previous version, a date, a number of days) — it
tells you nothing about the codebase's actual state, and a project can pass
its gate while carrying a large backlog of Overall Code issues.

## Step 1 — Triage each open issue

For every issue returned by `/api/issues/search`, decide **legitimate vs. not**
using the rule's description and the target project's own standards — not the
severity label alone. Read the project's own contributor guide first (root
`AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, a linter config, a documented
style guide) if one exists, since "legitimate" is defined by that project, not
by SonarQube's default rule text alone.

### Valid issue → fix the code

Apply the project's actual engineering standards: SOLID/DRY/KISS where the
project follows them, its type-safety rules, its localization rules if it has
any, accessibility, its architectural boundaries. A SonarQube finding is
**never** license for:

- A shortcut that violates a standard the project otherwise enforces.
- A suppression comment (`// NOSONAR`, `@SuppressWarnings`, inline rule
  disables) as a substitute for an actual fix.
- A cross-cutting refactor beyond the one issue, unless the user asked for
  broader remediation.

Update the project's own tests and docs alongside the code change, exactly as
its normal contribution conventions require — a SonarQube-driven fix is not
exempt from the project's usual "tests/docs travel with behavior" rule.

### False positive or not worth changing → transition it, leave the code alone

Typical cases: a rule that misreads an intentional pattern the project
documents elsewhere, a finding on generated or vendor/adapter code, or a "fix"
that would itself violate a project standard (e.g. a rule wanting a magic
number extracted where the project's own convention is to inline small,
self-explanatory literals).

**Never edit source purely to silence a finding you believe is correct as
written.** If the finding is real but deliberately not worth fixing right now,
that is `accept`, not code changes and not `falsepositive`.

```bash
AUTH=(-H "Authorization: Bearer $SONAR_TOKEN")

# The issue does not describe a real defect.
curl -sS -X POST "${AUTH[@]}" \
  "$SONAR_URL/api/issues/do_transition" \
  --data-urlencode "issue=$ISSUE_KEY" \
  --data-urlencode "transition=falsepositive"

# The issue is real but deliberately accepted as-is.
# `accept` on SonarQube 10.4+; older servers use `wontfix`.
curl -sS -X POST "${AUTH[@]}" \
  "$SONAR_URL/api/issues/do_transition" \
  --data-urlencode "issue=$ISSUE_KEY" \
  --data-urlencode "transition=accept"

# Always record why, so the decision survives the next analysis.
curl -sS -X POST "${AUTH[@]}" \
  "$SONAR_URL/api/issues/add_comment" \
  --data-urlencode "issue=$ISSUE_KEY" \
  --data-urlencode "text=<justification>"
```

Report every transition to the user with its justification. Resolving an
issue you cannot justify in one sentence is worse than leaving it open — when
in doubt, leave it open and flag it to the user instead of guessing.

## Step 2 — Coverage and duplication

Improve these **only where the change is justified on its own merits**, never
purely to move a percentage.

- **Coverage.** Add tests for behavior that genuinely deserves them, following
  the project's own testing conventions (fake ports/mocks the way its existing
  tests already do; query the way its existing tests already do). Do **not**
  add placeholder or assertion-free tests. If a file drags the number down
  because it only *declares* values (constants, types, style objects, barrel
  re-exports) rather than behaving, it is a candidate for the project's
  coverage-exclusion mechanism instead of a test — but only if the project
  already has one (e.g. a `coverage.exclude` in its test runner config mirrored
  into `sonar.coverage.exclusions`); don't invent that mechanism as part of a
  remediation task. Never exclude a file just because it is untested or
  awkward to test — that is a real gap and should stay measured.
- **Duplication.** Extract shared code only where it is genuine duplication of
  logic, types, or tokens, landing wherever the project's own structure puts
  shared code. Near-identical test setup, or two features that merely
  resemble each other, are not automatically duplication — a premature
  abstraction can cost more than the duplication it removes.

## Step 3 — Validate and re-check

Run whatever the target project defines as its own validation routine (type
checking, linting, formatting, tests, build — check its `package.json`
scripts or equivalent manifest rather than assuming a fixed set of commands).
Every change from this workflow must pass that routine before being reported
as done.

Then re-run the coverage + scan step from `SKILL.md` → "3. Produce a fresh
analysis" and re-read the Overall Code measures (`SKILL.md` → "4. Fetch
Overall Code measures") to confirm the findings actually moved. Summarize for
the user, in one pass:

- What was fixed in code (with file references).
- What was transitioned in SonarQube and why.
- What was left open, and why (e.g. needs a decision only the user can make).
