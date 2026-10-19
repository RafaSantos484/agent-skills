---
name: gitlab-api
description: Read or change GitLab resources on gitlab.com or a self-hosted instance through the REST or GraphQL API, including issues, merge requests, branches, pipelines, labels, milestones, epics and work items, members, and vulnerabilities. Use whenever a task involves reading data from or performing an action in a GitLab project, such as creating and assigning an issue, listing open merge requests, triggering a pipeline, or checking who is assigned to an epic, even if the request does not mention the API.
compatibility: Requires Bash, curl 7.76 or later (for --fail-with-body and reading headers from a file with -H @file), jq, and network access to the target GitLab host. Credentials come only from an exported environment variable.
---

# GitLab API Operations

This skill covers authenticating to GitLab's REST and GraphQL APIs, identifying the right GitLab instance, and choosing the API that fits each task.

Fetch the official docs directly when you need exact parameters, response shapes, or anything not covered here:

- REST reference: https://docs.gitlab.com/api/rest/
- GraphQL reference: https://docs.gitlab.com/api/graphql/
- GraphQL schema reference: https://docs.gitlab.com/api/graphql/reference/

Before doing anything else on a GitLab task, resolve these in order:

1. **Auth token** — [Authentication](#1-authentication)
2. **GitLab host** — [Finding the GitLab host](#2-finding-the-gitlab-host)
3. **Verify the connection** — [Verifying before you act](#3-verifying-before-you-act)
4. **REST or GraphQL** for the specific data/action — [REST vs GraphQL](#4-rest-vs-graphql)

Only then start making requests.

## 1. Authentication

Authenticate **only** through an exported environment variable, never through a file or a CLI's stored credentials. This is a hard rule. The variable's name is not fixed to `GITLAB_TOKEN`, because real setups often export several candidates side by side (`GITLAB_TOKEN`, `GITLAB_BOT_TOKEN`, `GITLAB_PERSONAL_TOKEN`, `GITLAB_ANPD_PERSONAL_TOKEN`, …). Discover which ones exist before picking one.

- **List candidate variable names only, never their values:**
  ```bash
  compgen -e | LC_ALL=C sort -u | grep -iE '^[A-Z0-9_]*GITLAB[A-Z0-9_]*TOKEN[A-Z0-9_]*$'
  ```
  `compgen -e` prints exported variable names without reading their values, so no token can appear in the output. Widen the pattern (for example, to also match `GL_TOKEN`) if the obvious one finds nothing.
- **Exactly one candidate** → use it, referring to it as `$GITLAB_TOKEN` in the rest of this doc regardless of its actual name (every command below is written against that placeholder — substitute the real name you resolved).
- **Zero candidates** → treat auth as missing (see below).
- **More than one candidate** → do not guess which one is "the" token. Ask the user which variable to use, unless something in the conversation already disambiguates it (e.g. the user already named one, or the task explicitly targets an org/instance that only one candidate's name plausibly maps to). When genuinely in doubt, ask — silently picking one risks acting under the wrong identity or scope.
- **Never** look anywhere else for it — not in `.netrc`, `.git-credentials`, `.env` files, CI/CD variable files, `glab` CLI config, editor/IDE settings, OS keychains, or any file inside a repo. Even if a file appears to contain a GitLab token, don't use it. The environment variable is the single source of truth by design: it keeps token discovery predictable and avoids silently picking up a stale or wrong-scoped credential sitting in some file.
- For the same reason, **don't fall back to the `glab` CLI** to work around a missing token — `glab` reads its own stored credentials, which routes around this rule.
- If no candidate variable is set, stop and tell the user rather than working around it. Nearly every useful endpoint requires auth, and unauthenticated calls are heavily rate-limited anyway.

When none is set, tell the user how to set one up:

1. Create a Personal Access Token in GitLab: **avatar → Edit profile → Access tokens**, or go directly to `https://<gitlab-host>/-/user_settings/personal_access_tokens`.
2. Grant the right scope:
   - `api` — full read/write. Needed for anything that creates or changes data, and for **all** GraphQL mutations.
   - `read_api` — read-only. Enough for listing/reading via REST and for GraphQL queries.
3. Export it in the shell that starts the agent session, under any GitLab-token-shaped name (`GITLAB_TOKEN` by default, or a more specific name like `GITLAB_BOT_TOKEN` if the user already has a naming convention). Reading it without echo keeps it out of shell history:
   ```bash
   read -r -s -p 'GitLab token: ' GITLAB_TOKEN; printf '\n'; export GITLAB_TOKEN
   ```
4. To make it available in every session, load it from a secret manager when the shell starts (for example, `export GITLAB_TOKEN="$(secret-tool lookup service gitlab)"`) rather than writing the token itself into `~/.bashrc` or another plaintext profile. Never write the token into a profile on the user's behalf.

Personal, project, and group access tokens and OAuth 2.0 access tokens all work with the requests in this skill, whatever the variable is named.

CI/CD job tokens (`CI_JOB_TOKEN`) are not supported. GitLab accepts them only in a `JOB-TOKEN` header, only on a restricted allowlist of endpoints that excludes `GET /user` and issues, never for GraphQL, and only while the job runs. If a job token is the only credential available, stop and tell the user. Do not send it as `PRIVATE-TOKEN` or `Bearer`, and do not adapt the procedures below to it. A `401` from the `GET /user` check in [step 3](#3-verifying-before-you-act) can mean the selected variable holds a job token.

**Never echo the token** into output shown to the user, into a file, or into a commit. Never place it directly on a command line or in a URL, because command arguments are visible to other processes. Pass it to curl the way every example below does: `--header @<(printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN")`. `printf` is a Bash builtin, so the value only travels through a pipe and curl's argument list shows `@/dev/fd/N` instead of the token. A process substitution can be read once, so give each `curl` call its own rather than storing it in a variable.

## 2. Finding the GitLab host

Never assume `gitlab.com`. GitLab is very commonly self-hosted (e.g. `https://gitlab.<company>.com.br`), and hitting the wrong host fails in confusing ways — wrong project, wrong auth realm, cryptic 404s. Resolve the host in this order, stopping as soon as one source gives a confident answer:

1. **The user said it directly** — a pasted URL, "our GitLab instance", or a project path given with a host. Use it as-is.
2. **Infer it from a git repo in context.** If you're working inside a clone:

   ```bash
   git remote -v
   git config --get remote.origin.url
   ```

   Parse the host out, handling both remote styles:
   - HTTPS: `https://gitlab.example.com/group/project.git` → host `gitlab.example.com`
   - SSH: `git@gitlab.example.com:group/project.git` → host `gitlab.example.com`

   Note the SSH host may differ from the web host on some setups (custom SSH endpoints); if the SSH-derived host doesn't respond, check for an HTTPS remote or ask.

3. **Read local files that mention the host** — `.gitlab-ci.yml`, `.git/config`, README badges, `CI_SERVER_URL` in CI config. (The file-reading prohibition applies only to the **token**, never to the host.)
4. **Ask the user.** If none of the above resolve it, don't guess.

Once you have the host, build the base URLs:

- REST: `https://<host>/api/v4`
- GraphQL: `https://<host>/api/graphql`

**Relative URL roots:** some self-hosted instances live under a subpath (e.g. `https://intranet.example.com/gitlab`). There the API is at `https://intranet.example.com/gitlab/api/v4`, not at the domain root. If a remote URL contains a path segment before the group name, preserve it in the base URL.

## 3. Verifying before you act

Before any write, confirm the token and host actually work together — one cheap call that costs far less than a misdirected `POST`:

```bash
curl -sf --header @<(printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN") "https://<host>/api/v4/user"
```

This returns the authenticated user, and confirms in one shot that the host is right, reachable, and the token is valid for it. `GET /api/v4/version` additionally reports the instance version, which matters when a feature's availability is version-dependent.

**Confirm before writing.** Creating issues, MRs, or comments is outward-facing — other people see it, and it can't always be cleanly undone. Before the first write of a task, state plainly what you're about to do and where: the host, the project path, the action. For **destructive or hard-to-reverse** actions specifically — deleting branches/issues/MRs, merging an MR, closing things in bulk, removing members, changing visibility — ask for explicit confirmation first unless the user already authorized that exact action.

Read-only calls need no confirmation.

## 4. REST vs GraphQL

**Default to REST** for straightforward, single-resource CRUD — creating/reading/updating/deleting an issue, merge request, branch, label, milestone. It's simpler to construct and covers most day-to-day GitLab automation.

**Reach for GraphQL** when:

- **You need related data from several resources in one round trip** — e.g. a project with its open issues, their assignees, and pipeline status together — instead of chaining multiple REST calls.
- **You want to fetch exactly a few fields** off large objects, rather than REST's fixed (and often heavy) payloads.
- **The information isn't available, or isn't fully available, through REST.** Currently documented cases:
  - **Epics and newer work-item fields.** The Epics REST API is deprecated as of GitLab 17.0 and frozen — it receives no new fields. Anything beyond the basics on epics (assignees, health status, custom fields, custom statuses, linked items of other types) exists **only** through the Work Item GraphQL API. Epics became work items generally in GitLab 18.1. If a user asks for an epic's assignee or health status, go straight to GraphQL — don't try REST first.
  - **Vulnerabilities / security findings.** The `/vulnerabilities` and `/vulnerability_findings` REST endpoints are marked by GitLab as _"in the process of being deprecated and considered unstable — the response payload may be subject to change or breakage across GitLab releases."_ Use the GraphQL `vulnerabilities` query and its mutations instead.
  - **General pattern:** the newer, or the more analytics/Premium-Ultimate-tier a feature is, the likelier it's GraphQL-first or GraphQL-only. When unsure, check that resource's REST docs page — GitLab explicitly flags deprecated REST endpoints and names the GraphQL replacement.

**Note the GraphQL API is also evolving:** the dedicated epic GraphQL types are themselves deprecated in favor of `workItem*` queries and mutations, with removal planned for GitLab 19.0. For new epic work, prefer the work-item shape.

See `references/rest-api.md` and `references/graphql-api.md` for endpoint/query catalogs and worked examples.

## 5. Making requests

**REST** — header-based auth:

```bash
curl -s --fail-with-body \
     --header @<(printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN") \
     "https://<host>/api/v4/projects/<id-or-url-encoded-path>/issues"
```

(`Authorization: Bearer $GITLAB_TOKEN` works equally well on REST.) `--fail-with-body` matters: without it curl exits 0 on a 4xx and you can mistake an error body for a result.

**GraphQL** — POST a JSON body to the single endpoint:

```bash
curl -s --fail-with-body --request POST \
     --header @<(printf 'Authorization: Bearer %s\n' "$GITLAB_TOKEN") \
     --header "Content-Type: application/json" \
     --data '{"query": "query { currentUser { username } }"}' \
     "https://<host>/api/graphql"
```

For any query longer than one line, **don't hand-escape it into a JSON string** — that's where GraphQL calls usually break. Build the body with `jq` instead:

```bash
jq -n --arg q "$(cat <<'GQL'
query($path: ID!) {
  project(fullPath: $path) { name webUrl }
}
GQL
)" --argjson v '{"path":"group/project"}' '{query:$q, variables:$v}' \
| curl -s --fail-with-body --request POST \
       --header @<(printf 'Authorization: Bearer %s\n' "$GITLAB_TOKEN") \
       --header "Content-Type: application/json" \
       --data @- "https://<host>/api/graphql"
```

Two ID quirks worth keeping straight:

- **REST project/group IDs** can be either the numeric ID or the URL-encoded full path (`group%2Fsubgroup%2Fproject`). Encode `/` as `%2F`.
- **GraphQL uses global IDs**: `"gid://gitlab/Project/123"`, `"gid://gitlab/User/456"`. Given a numeric REST ID, construct it as `"gid://gitlab/<TypeName>/<numeric_id>"`. Most GraphQL entry points also accept `fullPath` for projects/groups and `fullPath` + `iid` for issues/MRs, which is usually easier.
- **`id` vs `iid`**: `iid` is the per-project number a user sees (`#42`); `id` is the global database ID. REST issue/MR endpoints take the **`iid`**.

## 6. Worked example — create an issue and assign it

Via REST, three calls:

1. **Resolve the project** (skip if you already have the numeric ID):
   ```bash
   curl -s --fail-with-body --header @<(printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN") \
        "https://<host>/api/v4/projects/<group%2Fproject>"
   ```
2. **Resolve the assignee's user ID from their username:**
   ```bash
   curl -s --fail-with-body --header @<(printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN") \
        "https://<host>/api/v4/users?username=<username>"
   ```
   An empty `[]` means the username doesn't exist or isn't visible to your token — don't proceed with a guessed ID.
3. **Create the issue with `assignee_ids`:**
   ```bash
   curl -s --fail-with-body --request POST \
        --header @<(printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN") \
        --data-urlencode "title=Bug: something broke" \
        --data-urlencode "description=Steps to reproduce..." \
        --data "assignee_ids[]=<user_id>" \
        "https://<host>/api/v4/projects/<id>/issues"
   ```

The assignee must be a member of the project with at least Reporter access, or GitLab silently ignores the assignment — check `assignees` in the response rather than assuming it took.

GraphQL does the same in a single `createIssue` mutation taking `projectPath` and `assigneeIds` (global IDs) — see `references/graphql-api.md`, which also covers the equivalent when the target is an epic/work item rather than a plain issue.

## 7. Good practices

- **Pagination**: REST uses `page`/`per_page` (default 20, **max 100**) and returns `X-Total`, `X-Total-Pages`, `X-Next-Page`, and a `Link` header. For large collections prefer keyset pagination (`pagination=keyset`). GraphQL uses cursors (`nodes`, `pageInfo { hasNextPage endCursor }`), also capped at **100 nodes per page**. Don't stop at page 1 and report a partial list as complete.
- **GraphQL complexity limits**: 250 for authenticated requests (200 unauthenticated). Deeply nested queries fetching many connections at once get rejected — split them rather than nesting further.
- **Report back with links**: create/update responses include `web_url` (REST) or `webUrl` (GraphQL). Surface that to the user instead of a bare ID.
- **Distinguish auth failures**: `401` = token missing/invalid/expired. `403` = valid token, insufficient scope or permission. `404` on something you expect to exist usually also means _insufficient permission_ — GitLab returns 404 rather than 403 so responses don't leak the existence of private resources. Say which one happened; don't silently retry.
- **Rate limits**: on `429`, respect the `Retry-After` header and back off. Don't hammer in a loop.
- **GraphQL errors hide in a 200**: a GraphQL response can be HTTP 200 while carrying a top-level `errors` array, and mutations return their own `errors` field. Always check both before declaring success.

## Reference files

- `references/rest-api.md` — REST endpoint catalog (issues, MRs, branches, pipelines, labels, milestones, members, notes, search), pagination and rate-limit detail, error codes, and deprecated resources.
- `references/graphql-api.md` — GraphQL request shape, global IDs, schema exploration, common queries/mutations (issues, MRs, epics/work items, vulnerabilities), pagination and limits.
