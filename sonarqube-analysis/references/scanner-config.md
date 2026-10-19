# Writing `sonar-project.properties`

Minimal skeleton for a project that has none yet:

```properties
sonar.projectKey=<kebab-case, e.g. the repo/package name>
sonar.projectName=<human-readable name>
sonar.sources=<main source root, e.g. src>
sonar.sourceEncoding=UTF-8
```

Extend it once you know the stack:

| Concern                | Key                                                    |
| ----------------------- | ------------------------------------------------------- |
| Test file locations      | `sonar.tests=<root>` (can equal `sonar.sources` when tests are colocated — see below) |
| Classifying test files   | `sonar.test.inclusions=<globs>` |
| Excluding generated/vendor code | `sonar.exclusions=<globs>` |
| Coverage report ingestion | `sonar.javascript.lcov.reportPaths=<path>` (JS/TS), `sonar.python.coverage.reportPaths=<path>` (Python), `sonar.go.coverage.reportPaths=<path>` (Go), etc. — the key is language-specific; check `$SONAR_URL/web_api` or the language plugin's docs for the exact property. |
| Coverage-measurement exclusions | `sonar.coverage.exclusions=<globs>` — files still analyzed for issues but not counted for coverage (see below). |

## Colocated tests

When a project colocates tests with source (`Foo.tsx` next to
`Foo.test.tsx`), set `sonar.sources` and `sonar.tests` to the **same** root
and let `sonar.test.inclusions` pick the test files out of it — SonarQube
classifies anything matching `test.inclusions` as test code and excludes it
from being indexed as main source, rather than needing a physically separate
test directory.

## The brace-glob pitfall (critical)

**Never use brace alternation in this file.** SonarQube splits every property
value on commas **before** pattern matching, so a glob like
`src/**/*.{test,spec}.{ts,tsx}` is torn into the three nonsense fragments
`src/**/*.{test`, `spec}.{ts`, `tsx}` — none of which match anything. The
scanner reports **no error**; the pattern simply never applies, silently.

Spell every combination out on its own line instead:

```properties
sonar.test.inclusions=\
  src/**/*.test.ts,\
  src/**/*.test.tsx,\
  src/**/*.spec.ts,\
  src/**/*.spec.tsx
```

This is not a hypothetical failure mode: on at least one project, the brace
form left every unit test indexed as main source with no coverage entry —
each one counted as 0%-covered and dragged reported coverage from a real ~89%
down to ~47%. After changing any pattern, confirm the scanner logs it back
correctly — it prints `Excluded sources:`, `Included tests:`, and `Excluded
sources for coverage:` near the start of a run — and check that a known test
file is no longer reported as covered main source.

Other tools reading similar globs from a different config file (e.g. a JS
test runner's own config) may support brace expansion just fine — the
restriction is specific to how `sonar-project.properties` values are parsed,
not a general glob limitation.

## Coverage-measurement exclusions

`sonar.coverage.exclusions` marks files that are still **analyzed for
issues** but excluded from the **coverage percentage** — for modules that
declare rather than behave (constants, type-only files, style-object
modules, barrel re-exports) with no branch, loop, or I/O, where a test could
only assert a literal equals itself.

If the target project's own test runner has an equivalent coverage-exclude
setting (e.g. Vitest/Jest's `coverage.exclude`, pytest's `--cov-config`
omit list), **mirror the same list in both places** — excluding a file from
only one tool's report skews that tool's number relative to the other's
(commonly: the test runner drops it from its coverage file entirely, and
SonarQube then reports its lines as *uncovered*, the opposite of the
intent). Never treat "hard to test" or "untested today" as grounds for
exclusion — that is a real coverage gap and should stay measured; the
exclusion is for files that have no testable behavior at all.
