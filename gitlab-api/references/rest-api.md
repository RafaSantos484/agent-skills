# GitLab REST API — Reference

Base URL: `https://<host>/api/v4` (prefix with the relative URL root if the instance uses one, e.g. `https://intranet.example.com/gitlab/api/v4`)
Full docs: https://docs.gitlab.com/api/rest/ — browse per-resource pages from there, e.g. `.../api/issues/`, `.../api/merge_requests/`

Auth header: `PRIVATE-TOKEN: <token>` (or `Authorization: Bearer <token>` — both are supported), always supplied as `--header @<(printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN")` so the value stays out of curl's argument list (see `SKILL.md` → "1. Authentication"). `$GITLAB_TOKEN` here is a placeholder for whichever environment variable name was resolved per `SKILL.md` → "1. Authentication" (candidate discovery, ask-if-ambiguous) — substitute the real variable name in every command below.

Always pass `--fail-with-body` to curl so 4xx/5xx responses don't get mistaken for results.

## Sanity checks

```bash
# Who am I? Confirms host + token in one call.
curl -sf --header @<(printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN") "https://<host>/api/v4/user"

# Instance version — matters when a feature is version-gated.
curl -sf --header @<(printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN") "https://<host>/api/v4/version"
```

## Identifying projects and groups

Most endpoints take `:id` as either:

- the numeric project/group ID, or
- the URL-encoded full path, e.g. `group%2Fsubgroup%2Fproject` (`/` → `%2F`)

Look up a project by path when you don't have the numeric ID:

```bash
curl -s --fail-with-body --header @<(printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN") \
     "https://<host>/api/v4/projects/<group%2Fproject>"
```

`id` vs `iid`: `iid` is the number users see (`#42`, scoped to the project); `id` is the global database ID. Issue and MR endpoints below take the **`iid`**.

## Issues

| Action                                      | Method & endpoint                        |
| ------------------------------------------- | ---------------------------------------- |
| List issues                                 | `GET /projects/:id/issues`               |
| Get one issue                               | `GET /projects/:id/issues/:issue_iid`    |
| Create issue                                | `POST /projects/:id/issues`              |
| Update issue (edit, assign, close, relabel) | `PUT /projects/:id/issues/:issue_iid`    |
| Delete issue                                | `DELETE /projects/:id/issues/:issue_iid` |

Useful params on create/update: `title`, `description`, `assignee_ids` (array), `labels` (comma-separated string), `milestone_id`, `due_date`, `confidential`, `state_event` (`close`/`reopen`).

Common list filters: `state=opened|closed`, `labels=`, `assignee_username=`, `author_username=`, `milestone=`, `search=`, `created_after=`, `updated_after=`, `scope=all`.

```bash
curl -s --fail-with-body --request POST \
     --header @<(printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN") \
     --data-urlencode "title=Something is broken" \
     --data "assignee_ids[]=42" \
     --data "labels=bug,needs-triage" \
     "https://<host>/api/v4/projects/123/issues"
```

Assignment silently no-ops if the user isn't a project member with at least Reporter access — verify `assignees` in the response rather than assuming success.

## Merge requests

| Action                                  | Method & endpoint                                                                     |
| --------------------------------------- | ------------------------------------------------------------------------------------- |
| List merge requests                     | `GET /projects/:id/merge_requests`                                                    |
| Get one MR                              | `GET /projects/:id/merge_requests/:merge_request_iid`                                 |
| Create MR                               | `POST /projects/:id/merge_requests` (needs `source_branch`, `target_branch`, `title`) |
| Update MR (edit, assign, add reviewers) | `PUT /projects/:id/merge_requests/:merge_request_iid`                                 |
| Merge MR                                | `PUT /projects/:id/merge_requests/:merge_request_iid/merge`                           |
| List changes/diff                       | `GET /projects/:id/merge_requests/:merge_request_iid/changes`                         |
| Approvals                               | `GET/POST /projects/:id/merge_requests/:merge_request_iid/approvals`                  |

Merging is hard to reverse — confirm with the user before calling the merge endpoint.

## Branches & commits

| Action               | Method & endpoint                                                           |
| -------------------- | --------------------------------------------------------------------------- |
| List branches        | `GET /projects/:id/repository/branches`                                     |
| Create branch        | `POST /projects/:id/repository/branches`                                    |
| Delete branch        | `DELETE /projects/:id/repository/branches/:branch`                          |
| List commits         | `GET /projects/:id/repository/commits`                                      |
| Get a commit         | `GET /projects/:id/repository/commits/:sha`                                 |
| Cherry-pick / revert | `POST .../commits/:sha/cherry_pick` or `/revert`                            |
| Read a file          | `GET /projects/:id/repository/files/:file_path?ref=main` (path URL-encoded) |

## Pipelines & jobs

| Action                  | Method & endpoint                                                             |
| ----------------------- | ----------------------------------------------------------------------------- |
| List pipelines          | `GET /projects/:id/pipelines`                                                 |
| Get a pipeline          | `GET /projects/:id/pipelines/:pipeline_id`                                    |
| Trigger a pipeline      | `POST /projects/:id/pipeline` (singular; needs `ref`, optional `variables[]`) |
| Retry/cancel a pipeline | `POST .../pipelines/:pipeline_id/retry` or `/cancel`                          |
| List jobs in a pipeline | `GET /projects/:id/pipelines/:pipeline_id/jobs`                               |
| Get job log/trace       | `GET /projects/:id/jobs/:job_id/trace`                                        |

Note the create endpoint is `/pipeline` (singular) while listing is `/pipelines` (plural) — an easy 404.

## Labels & milestones

| Action                 | Method & endpoint                     |
| ---------------------- | ------------------------------------- |
| List/create labels     | `GET`/`POST /projects/:id/labels`     |
| List/create milestones | `GET`/`POST /projects/:id/milestones` |

Group-level equivalents exist at `/groups/:id/labels` and `/groups/:id/milestones`.

## Members

| Action                       | Method & endpoint                                              |
| ---------------------------- | -------------------------------------------------------------- |
| List members                 | `GET /projects/:id/members` (or `/groups/:id/members`)         |
| List members incl. inherited | `GET /projects/:id/members/all`                                |
| Add member                   | `POST /projects/:id/members` (needs `user_id`, `access_level`) |
| Remove member                | `DELETE /projects/:id/members/:user_id`                        |

Access levels: 10 Guest, 20 Reporter, 30 Developer, 40 Maintainer, 50 Owner.

`/members` returns only direct members — a user with inherited group access won't appear there. Use `/members/all` when checking whether someone can be assigned.

## Users

Resolve a username to a numeric user ID (needed for `assignee_ids`, `reviewer_ids`, etc):

```bash
curl -s --fail-with-body --header @<(printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN") \
     "https://<host>/api/v4/users?username=<username>"
```

Returns an array — empty means no such user, or the token can't see them. Don't guess an ID from an empty result.

## Notes / comments

| Action                 | Method & endpoint                                                                |
| ---------------------- | -------------------------------------------------------------------------------- |
| List notes on an issue | `GET /projects/:id/issues/:issue_iid/notes`                                      |
| Add a note/comment     | `POST /projects/:id/issues/:issue_iid/notes` (same pattern for `merge_requests`) |

## Search

Project-scoped search across issues, MRs, commits, code:

```bash
curl -s --fail-with-body --header @<(printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN") \
     "https://<host>/api/v4/projects/:id/search?scope=issues&search=<query>"
```

Also available instance-wide at `/search` and group-scoped at `/groups/:id/search`.

## Pagination

**Offset-based** (default): `page` and `per_page` — default 20, **max 100**.

```bash
curl -s --fail-with-body --header @<(printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN") \
     "https://<host>/api/v4/projects/:id/issues?page=2&per_page=100"
```

Response headers: `X-Total`, `X-Total-Pages`, `X-Per-Page`, `X-Page`, `X-Next-Page`, `X-Prev-Page`, plus a `Link` header with `rel="next"`.

**Keyset-based**: more efficient on large collections, and required past deep offsets on some endpoints. Pass `pagination=keyset` with `order_by` and `sort`, then follow the `rel="next"` URL from the `Link` header rather than incrementing a page number.

Some endpoints omit `X-Total` on very large collections for performance — absence of that header is not an error.

## Errors and rate limits

| Code  | Meaning                                                                                                                                   |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `400` | Malformed request / missing required attribute                                                                                            |
| `401` | Token missing, invalid, or expired                                                                                                        |
| `403` | Valid token, but insufficient scope or permission                                                                                         |
| `404` | Not found **or** not visible to this token — GitLab returns 404 instead of 403 so responses don't leak the existence of private resources |
| `409` | Conflict (e.g. branch already exists)                                                                                                     |
| `422` | Understood but unprocessable (validation failure)                                                                                         |
| `429` | Rate limited — honor the `Retry-After` header and back off                                                                                |

A 404 on something the user insists exists is most often a permission or wrong-host problem, not a missing resource. Re-check the host and the token's scope before telling the user it doesn't exist.

## Known-deprecated REST resources (use GraphQL instead)

- **Epics API** (`/groups/:id/epics/...`), plus **Epic Issues**, **Epic Links**, and **Linked Epics** — deprecated since GitLab 17.0, frozen feature set, slated for removal in API v5. New epic capabilities (assignees, health status, custom fields/statuses, cross-type linked items) exist only via the Work Item GraphQL API. Epics became work items generally in GitLab 18.1. See the [epic → work item migration guide](https://docs.gitlab.com/api/graphql/epic_work_items_api_migration_guide/).
  - Gotcha: the legacy epic `id` is **not** the same as the corresponding work item ID — only `iid` matches. The epic REST response includes a `work_item_id` field to bridge them.
- **Vulnerabilities API** (`/vulnerabilities`) and **Vulnerability Findings API** (`/vulnerability_findings`) — GitLab marks these as _"in the process of being deprecated and considered unstable. The response payload may be subject to change or breakage across GitLab releases."_ Use the GraphQL `vulnerabilities` query and mutations.

If a REST docs page carries a deprecation warning, treat it as a strong signal to check `graphql-api.md` or the GraphQL docs for the replacement rather than depending on the REST response shape.
