# GitLab GraphQL API — Reference

Endpoint: `https://<host>/api/graphql` — a single endpoint; every call is a POST.
Full docs: https://docs.gitlab.com/api/graphql/
Schema reference (every type, field, and mutation): https://docs.gitlab.com/api/graphql/reference/
Interactive explorer: `https://<host>/-/graphql-explorer`

Auth header: `Authorization: Bearer <token>`, always supplied as `--header @<(printf 'Authorization: Bearer %s\n' "$GITLAB_TOKEN")` so the value stays out of curl's argument list (see `SKILL.md` → "1. Authentication"). Personal, project, and group access tokens and OAuth 2.0 tokens all work. Queries need the `read_api` scope; **all mutations need `api`**. `$GITLAB_TOKEN` here is a placeholder for whichever environment variable name was resolved per `SKILL.md` → "1. Authentication" (candidate discovery, ask-if-ambiguous) — substitute the real variable name in every command below.

The schema is versionless — individual fields get deprecated with notice (kept for at least six releases, removed only at a major version) rather than the whole API being versioned. If an expected field is missing, check whether it was renamed or deprecated before assuming it never existed. You can preview the post-removal schema by appending `?remove_deprecated=true` to the endpoint.

## Request shape

A POST with a JSON body containing `query` and optionally `variables`:

```bash
curl -s --fail-with-body --request POST \
     --header @<(printf 'Authorization: Bearer %s\n' "$GITLAB_TOKEN") \
     --header "Content-Type: application/json" \
     --data '{
       "query": "query($path: ID!) { project(fullPath: $path) { name } }",
       "variables": { "path": "group/project" }
     }' \
     "https://<host>/api/graphql"
```

For anything longer than one line, build the JSON with `jq` instead of hand-escaping the query — embedded quotes and newlines are the most common cause of a mysterious `400`:

```bash
jq -n --arg q "$(cat <<'GQL'
query($path: ID!) {
  project(fullPath: $path) {
    name
    webUrl
  }
}
GQL
)" --argjson v '{"path":"group/project"}' '{query:$q, variables:$v}' \
| curl -s --fail-with-body --request POST \
       --header @<(printf 'Authorization: Bearer %s\n' "$GITLAB_TOKEN") \
       --header "Content-Type: application/json" \
       --data @- "https://<host>/api/graphql"
```

Prefer variables over string-interpolating user values into the query text — it avoids quoting bugs and keeps types checked.

## Global IDs

GraphQL identifies objects with global IDs rather than plain numeric REST IDs:

```
gid://gitlab/Project/123
gid://gitlab/User/456
gid://gitlab/Issue/789
gid://gitlab/WorkItem/1011
```

Given a numeric REST ID, construct the global ID as `"gid://gitlab/<TypeName>/<numeric_id>"`. Going the other way, `iid` and often the numeric id are still exposed as fields on the type.

You can frequently skip global IDs entirely: most entry points take `fullPath` for projects/groups, and `fullPath` + `iid` for issues and merge requests.

## Common queries

**Current user** (also the cheapest connectivity check):

```graphql
query {
  currentUser {
    id
    username
  }
}
```

**Project with issues, in one round trip** — the main reason to prefer GraphQL over REST:

```graphql
query {
  project(fullPath: "group/project") {
    name
    issues(state: opened, first: 20) {
      nodes {
        iid
        title
        webUrl
        assignees {
          nodes {
            username
          }
        }
        labels {
          nodes {
            title
          }
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
}
```

**Resolve a username to a global ID** (for `assigneeIds`):

```graphql
query {
  users(usernames: ["jdoe"]) {
    nodes {
      id
      username
    }
  }
}
```

## Common mutations

**Create an issue and assign it, in one call** (vs. the three-step REST flow):

```graphql
mutation {
  createIssue(
    input: {
      projectPath: "group/project"
      title: "Something is broken"
      description: "Steps to reproduce..."
      assigneeIds: ["gid://gitlab/User/42"]
      labels: ["bug"]
    }
  ) {
    issue {
      iid
      webUrl
    }
    errors
  }
}
```

**Update / assign an existing issue:**

```graphql
mutation {
  updateIssue(
    input: {
      projectPath: "group/project"
      iid: "17"
      assigneeIds: ["gid://gitlab/User/42"]
    }
  ) {
    issue {
      iid
      assignees {
        nodes {
          username
        }
      }
    }
    errors
  }
}
```

**Always read the mutation's own `errors` array.** A mutation can return HTTP 200 with a `null` payload and a populated `errors` list — for example when the assignee isn't a project member. Unlike queries, mutations also surface authorization failures as real errors in the top-level `errors` array rather than silently returning `null`.

## Epics / Work Items (GraphQL territory)

Epics are unified into the Work Item model, generally available since GitLab 18.1. New capabilities (assignees, health status, custom fields/statuses, cross-type linked items) exist only here — the REST Epics API is deprecated and frozen, and even the dedicated **epic GraphQL types are themselves deprecated**, with removal planned for GitLab 19.0. Write new integrations against `workItem*`.

```graphql
query {
  group(fullPath: "group") {
    workItems(types: [EPIC], first: 20) {
      nodes {
        id
        iid
        title
        webUrl
        widgets {
          ... on WorkItemWidgetAssignees {
            assignees {
              nodes {
                username
              }
            }
          }
          ... on WorkItemWidgetHealthStatus {
            healthStatus
          }
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
}
```

Work item fields are exposed through typed **widgets** (`WorkItemWidgetAssignees`, `WorkItemWidgetHealthStatus`, `WorkItemWidgetHierarchy`, `WorkItemWidgetLabels`, `WorkItemWidgetDescription`, …) rather than flat fields — pull each out with an inline fragment (`... on WidgetType`). Which widgets exist depends on the work item type and the instance's tier.

Creating a work item uses `workItemCreate` (needs `namespacePath` and a `workItemTypeId`); updating uses `workItemUpdate`, whose input is also widget-shaped. Query `workItemTypes` on the namespace to get valid type IDs — don't hardcode them, they differ per instance.

Gotcha when migrating from REST: a legacy epic's `id` is **not** the corresponding work item ID. Only `iid` matches; the epic REST response carries a `work_item_id` to bridge the two.

## Vulnerabilities (GraphQL territory)

The REST `/vulnerabilities` and `/vulnerability_findings` endpoints are deprecated and explicitly documented as unstable. Use GraphQL:

```graphql
query {
  project(fullPath: "group/project") {
    vulnerabilities(state: [DETECTED, CONFIRMED], first: 20) {
      nodes {
        title
        severity
        state
        identifiers {
          name
        }
        location {
          ... on VulnerabilityLocationSast {
            file
            startLine
          }
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
}
```

State transitions have dedicated mutations: `vulnerabilityConfirm`, `vulnerabilityResolve`, `vulnerabilityDismiss`, `vulnerabilityRevertToDetected`.

## Pagination and limits

Connections use cursor-based pagination, capped at **100 nodes per page**:

```graphql
query {
  project(fullPath: "group/project") {
    issues(first: 100, after: "<endCursor from previous page>") {
      nodes {
        iid
        title
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
}
```

Loop while `hasNextPage` is true, feeding `endCursor` into `after`. Don't report a first page as a complete list.

**Query complexity limits**: 250 for authenticated requests, 200 for unauthenticated. Each field and nesting level adds cost, so a query that fans out across several connections at once can be rejected outright. If you hit the limit, split into multiple queries rather than nesting deeper. There is also a depth limit — very deeply nested queries fail regardless of complexity.

## Permission errors: queries return `null`, mutations error

Behavior differs by operation type, and conflating the two wastes debugging time:

- **Queries** resolve unauthorized or absent fields to `null` with no error message. This is deliberate — the response must not distinguish "doesn't exist" from "exists but hidden from you". (REST does the same thing with a `404`.)
- **Mutations** return a real message in the top-level `errors` array when authorization fails.

So an unexpected `null` from a query is a permission/scope problem at least as often as a missing resource. Check the token's scope and the user's role on that project before concluding the resource isn't there.

## Schema exploration

When you need to confirm a field exists or check a mutation's exact input shape before writing a query blind:

- Use the GraphiQL explorer at `https://<host>/-/graphql-explorer` — autocomplete plus inline docs, and it runs against _that_ instance, so it reflects its version and tier.
- Or introspect directly:
  ```graphql
  query {
    __type(name: "Issue") {
      fields {
        name
        type {
          name
          kind
        }
      }
    }
  }
  ```
  For a mutation's input: `__type(name: "CreateIssueInput") { inputFields { name type { name kind ofType { name } } } }`.
- Or consult the published schema reference: https://docs.gitlab.com/api/graphql/reference/

Introspecting the target instance beats trusting the public docs when the instance is self-hosted — it may run an older version or a different tier, and tier-gated fields simply won't exist there.
