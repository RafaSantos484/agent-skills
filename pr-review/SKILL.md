---
name: pr-review
description: Perform an evidence-based code review against a live git repository the agent can read, search, and run commands in. Use when the user asks to review a pull request, their changes, a branch, or a diff; asks whether code is ready to merge; wants a second opinion before opening a PR; or wants an architecture, SOLID, or best-practices assessment of real code. Accepts a PR number or URL, a branch compared with its base, or uncommitted working-tree changes. Applies to requests like "review this PR", "review my changes", "is this ready to merge", or "check this diff against our conventions", even without the word PR.
compatibility: Requires git and the ability to read files, search the repository, and run shell commands. The GitHub CLI (gh) is optional and used only for read-only pull request lookups.
---

# Pull request review

Review a change the way a careful senior engineer would, working directly in
the repository. Every claim must trace back to a file, line, command output,
or test result you actually examined. Do not guess, invent issues, or offer
generic advice that isn't grounded in this repository and this change.

## Required capabilities

You need to read files, search file names and contents, and run shell
commands (`git`, plus the project's own test and lint tooling). The GitHub
CLI (`gh`) is optional and is used only for read-only pull request lookups.
If your environment is missing one of these, say which and narrow the review
accordingly instead of filling the gap with assumptions.

## Why this matters

A review that isn't grounded in the actual repository is just generic
linting advice. Read the repo's own conventions first, then judge the
change against *those*, not against an abstract idea of "good code."
Repository instructions (agent instruction files, `README.md`,
`CONTRIBUTING.md`, and similar) outrank generic best practices when the two
conflict.

Working in the live repository also means you can run the test suite, the
linter, or a type checker to verify a claim instead of inferring it from the
code. Use that. A diff that looks fine is not a reason to skip verification.

## Step 1: Determine what you're reviewing

Don't ask by default — infer the scope, state your assumption in one line,
and proceed. Only ask if genuinely ambiguous (e.g. multiple open PRs and no
clue which one).

- **User gave a PR number or URL** → use the `gh` CLI without checking out
  the branch:
  ```bash
  gh pr view <n> --json title,body,author,baseRefName,headRefName
  gh pr diff <n>
  gh pr view <n> --comments
  gh pr checks <n>
  ```
  If `gh` is unavailable or not authenticated and the remote is GitHub,
  fetch the PR head read-only with `git fetch origin pull/<n>/head` and
  compare `FETCH_HEAD` with the base branch. Say in the review that PR
  metadata and CI status were not available.
- **No PR number, but a feature branch with a tracked upstream/base** →
  diff against the base:
  ```bash
  git fetch origin
  git log origin/main..HEAD --oneline
  git diff origin/main...HEAD
  ```
  (swap `main` for the repo's actual default branch — check
  `git remote show origin` or `gh repo view --json defaultBranchRef` if unsure)
- **Neither of the above, but there are uncommitted or staged changes** →
  review the working tree:
  ```bash
  git status
  git diff HEAD
  ```
- If you truly can't tell what to review (e.g. clean working tree, no branch
  divergence, no PR reference given), ask the user which of the above they mean.

State which mode you used at the top of your review so the user can correct
you if you guessed wrong.

## Step 2: Read the repo's own conventions before forming any opinion

Don't jump straight to the changed files — you need surrounding context
(sibling modules, existing patterns, test conventions) to judge whether the
change fits in. Look for, in this order of authority:

1. Agent instruction files at the repo root and in any subdirectory the
   change touches, since they can be nested: `AGENTS.md`, `CLAUDE.md`,
   `GEMINI.md`, `.github/copilot-instructions.md`,
   `.github/instructions/*.instructions.md`, `.cursor/rules/`, or
   `.cursorrules`. Read whichever exist; they all describe the same
   project.
2. `README.md` and `CONTRIBUTING.md`
3. Linter/formatter/type-checker config that encodes conventions objectively
   (`.eslintrc*`, `pyproject.toml`, `.golangci.yml`, `rustfmt.toml`, etc.)
4. Any other docs relevant to architecture or the specific feature area
   (`docs/architecture.md`, module-level READMEs, ADRs)

Search the tree for these by file name and read the ones that exist. Treat
them as the primary source of truth. If repo conventions conflict with
generic best practice, the repo wins, and say so when it comes up.

## Step 3: Understand what the change is actually trying to do

From the PR description/comments (if using `gh`) or the commit messages (if
diffing branches), identify:
- The stated goal of the change
- The files it touches
- The actual diff content — read it as a diff, not just a description

Then go beyond the diff itself. Open each changed file **in full**, not just
the diff hunk, because a three-line hunk can look fine in isolation and
still be wrong given the rest of the function. Search the repository for
other call sites of anything changed (renamed functions, changed
signatures, modified exports) and confirm they were updated consistently.
Check whether a sibling test file exists and whether it was updated
alongside the logic.

Ignore changes clearly unrelated to the stated goal unless they affect
correctness — but note substantial unrelated changes exist, since reviewers
usually want to know.

## Step 4: Evaluate against the repo's own standards

For each changed file, check whether it:
- Fits the existing architecture (layering, module boundaries, where logic
  is supposed to live)
- Follows naming, export, styling, folder, and dependency conventions you
  actually observed elsewhere in the repo
- Respects SOLID principles and general maintainability (readability,
  testability, reusability)
- Avoids duplicating logic that already exists elsewhere in the repo
  (search the repository before asserting duplication)
- Preserves backward compatibility where that matters
- Comes with tests/docs if the repo's conventions expect them for this kind
  of change
- Doesn't introduce regressions, hidden coupling, or inconsistencies with
  neighboring code

Every issue you raise must be traceable to a specific file and line you can
point to. If you suspect a problem but can't point to evidence, say so as an
open question rather than asserting it as a finding.

## Step 5: Verify empirically where it's cheap to do so

Before asserting something a tool could check, check it:

1. Look for how the project builds/tests/lints — `package.json` scripts,
   `Makefile`, `pyproject.toml`, `go.mod`+`Makefile`, `Cargo.toml`, CI config
   under `.github/workflows/`.
2. Run the narrowest relevant command, favoring speed:
   - A type checker or linter on just the changed files, if that's supported
   - The specific test file(s) touching the changed code, before falling
     back to the full suite
3. Only run commands that are read-only with respect to the outside world
   (no deploys, no DB migrations, no publishing, no `git push`, no posting
   comments). If a check requires secrets, network access you don't have, or
   takes too long to be practical, skip it and say so explicitly in the
   review rather than silently omitting it.
4. If the PR is on GitHub, `gh pr checks <n>` shows you CI results that
   already ran — check those before re-running things locally.
5. A failing test or lint error you triggered yourself is a **blocking**
   finding backed by direct evidence — cite the command and the relevant
   output.

## Step 6: Write the review

Use the exact output structure below. Do not skip sections — if a section
has nothing to report, say so explicitly (e.g., "No blocking issues found.")
rather than omitting it.

## Output format

```markdown
### Scope
[Which mode from Step 1 was used, and against what base/PR/commit range]

### Verdict
Accept | Accept with minor changes | Reject

### Summary
[2-5 sentences: what the change does, whether it works, whether it fits the repo]

### Blocking issues
[One block per issue, using the template below. If none: "No blocking issues found."]

#### [Issue title]
- **Severity:** Blocking
- **Files affected:** `path/to/file.ts:42`, `path/to/other.ts:10-18`
- **Problem:** [what's wrong and why it matters]
- **Evidence:** [quoted code, diff snippet, or command output with exact location]
- **Impact:** [practical consequence]
- **Suggested fix:** [how to resolve]
- **Fix example:**
```text
[concrete patch or code, when possible from evidence]
```

### Non-blocking improvements
[Same per-issue template as above, but Severity: Non-blocking. If none: "No non-blocking improvements identified."]

### Verification
[What you actually ran — tests, lint, type-check, CI status via `gh pr checks` — and the result of each. For anything you didn't run, say why (too slow, needs secrets, no test runner configured, etc.)]

### Architecture and design assessment
[Separation of concerns, coupling/cohesion, reusability, testability, consistency with existing patterns, any regressions or improvements — be specific, tie back to evidence]

### Final recommendation
[Clear merge / don't-merge statement and why]
```

## Step 7 (optional): Posting the review

Publishing a review is a separate, outward-facing step. Do it only when the
user asks, after confirming the exact target, content, and review state
(comment, approve, or request changes). Never post automatically because a
review is finished. If the `github-api` skill is available, use it for the
write so its target and identity checks apply. Otherwise use
`gh pr comment` or `gh pr review`, and show the user the exact command
before you run it.

## Ground rules (why these matter, not just what they are)

- **Don't invent issues.** A review padded with speculative concerns erodes
  trust. If evidence is thin, say the evidence is thin — that's a valid and
  useful finding on its own.
- **Every finding needs a file:line reference.** "This could be cleaner"
  isn't actionable; "in `src/api/users.ts:42`, this duplicates the
  validation already in `src/lib/validators.ts:10`" is.
- **Prefer running a check over speculating about its outcome.** If you
  catch yourself writing "this might break the build" or "tests may fail
  here," run the build or the test instead, unless it's genuinely
  impractical — then say explicitly that you didn't verify it and why.
- **Fewer, higher-quality findings beat a long list of nitpicks.** Reviewers
  act on precision, not volume.
- **Every suggested fix should be concrete enough to paste as a review
  comment.** Where a code-level fix is possible from the evidence, show it.
- **If the diff and the current repo state are inconsistent** (e.g. the diff
  touches a file that no longer exists on the base branch, or the branch is
  badly out of date with its base), flag that explicitly — it affects how
  much confidence to place in the review.
- **Never take a mutating action** (commit, push, merge, post a comment,
  approve/request-changes) without explicit confirmation, even if the review
  itself concludes "Accept."
