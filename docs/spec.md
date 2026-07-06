# Functional Specification: Self-Hosted Runner Availability Fallback Action

## Purpose

A bootstrap job in a GitHub Actions workflow must decide, at run time, whether to route a downstream job to a self-hosted runner fleet or fall back to a GitHub-hosted runner, based on live fleet availability.

## Scope (explicit non-goals)

This action checks **organization-level** self-hosted runners only. The consuming organization (ExaDev) only ever invokes this action at organization scope, so repository-level and enterprise-level runner checking are explicitly out of scope for this implementation. An implementer should not add branches, inputs, or code paths for repository-scoped or enterprise-scoped runner queries — there is exactly one supported scope.

## Inputs

| Name | Type | Required | Description |
|---|---|---|---|
| `org` | string | yes | The GitHub organization whose self-hosted runner fleet should be queried. |
| `preferred-labels` | string | yes | Comma-separated list of labels identifying the preferred self-hosted pool, e.g. `self-hosted,linux,ARM64,act-latest,m3`. All of these labels must be present together on one runner for the preferred pool to count as available. |
| `fallback-labels` | string | yes | Comma-separated list of labels to use when the preferred pool is unavailable, e.g. `ubuntu-latest`. |
| `token` | string (secret) | yes | Must carry read access to the organization's self-hosted runner inventory. The action consumes this token as given — it does not mint, refresh, cache, or validate its provenance or scope beyond what the API call itself reveals. |

## Outputs

| Name | Description |
|---|---|
| `selected-runner` | A JSON-encoded array of label strings, intended for a downstream job's `runs-on` via `fromJson(...)`. Always an array, even when it contains a single label (e.g. `["ubuntu-latest"]`), so the calling workflow never has to branch on whether the value is a scalar or a list. |
| `preferred-available` | The string `"true"` or `"false"`, reported for observability regardless of which pool ended up in `selected-runner`. |

## Algorithm

1. Parse `preferred-labels` into a set of individual label strings (split on comma).
2. Query the organization's registered self-hosted runners, retrieving **every page** of the result set. This listing endpoint paginates, and a real organization's fleet can span many pages (hundreds of runners across roughly half a dozen or more pages of 100), with the runners that actually matter not necessarily appearing on the first page. An implementation that stops after one page will silently fail to find a perfectly available preferred pool and route to fallback for no legitimate reason — this is a correctness requirement, not defensive extra work.
3. Restrict attention to runners whose status is `"online"`.
4. Among those online runners, determine whether **any single runner** carries the **entire** preferred label set simultaneously — i.e. one runner object whose own labels are a superset of the requested set. This must be evaluated per runner. It is not sufficient for the union of labels across the whole online fleet to cover the set while no individual runner does; two different online runners each holding half the required labels do not together constitute an available preferred pool.
5. Label comparison must be case-insensitive. The preferred-labels input (as typed by a human into workflow configuration) and a runner's actual registered labels (as set by whoever registered the runner) are maintained independently and can differ in letter case without any intent for them to mean different things (e.g. `ARM64` vs `arm64` should be treated as the same label).
6. A runner that is online but currently marked busy still counts as available: GitHub queues a queued job against a busy self-hosted runner rather than rejecting it, so busy-ness is not a disqualifying condition for this decision.
7. If a matching online runner is found: set `selected-runner` to the preferred-labels (encoded as a JSON array) and `preferred-available` to `"true"`.
8. Otherwise: set `selected-runner` to the fallback-labels (encoded as a JSON array) and `preferred-available` to `"false"`.

## Error handling

- A failure to reach the runner-listing API (network failure, non-success HTTP status, or a token that lacks permission to read the organization's runners) must **fail the action** (non-zero exit / action failure) rather than being treated as "preferred unavailable, use fallback." Silently falling back on an API or auth failure would mask a broken credential or a broken integration behind what looks like ordinary, expected fallback behaviour.
- The expected case where the preferred label set simply has no matching online runner right now must **not** fail — that is the normal, everyday fallback path described in steps 7-8 above.
- Required inputs that are missing or empty must cause the action to fail before any API call is attempted.

## API contract (interoperability facts)

- Runner data is retrieved from `GET /orgs/{org}/actions/runners`, which is a paginated endpoint; requests should use the maximum page size (`per_page` up to 100) and continue fetching subsequent pages until the full runner list has been retrieved.
- Each runner object returned by this endpoint has at minimum: a `status` field (string, `"online"` or `"offline"`), a `busy` field (boolean), and a `labels` field. `labels` is an **array of objects**, each with a `.name` string property — it is not an array of plain strings, and any implementation must read `label.name` per entry rather than treating array entries as strings directly.
- Authentication is via a bearer/token header carrying read access to organization-level self-hosted runners. The calling workflow is responsible for producing a token with adequate scope; this action only consumes whatever token it is given and reports failure if that token proves inadequate when the API is called.

## Test vectors

| Scenario | Expected `selected-runner` | Expected `preferred-available` |
|---|---|---|
| (a) Preferred label set fully present on one online runner | preferred labels | `true` |
| (b) Preferred labels are only satisfied when scattered across multiple online runners, no single runner has them all | fallback labels | `false` |
| (c) A runner with the preferred label set exists but is offline | fallback labels | `false` |
| (d) A runner with the preferred label set is online but currently busy | preferred labels | `true` |
| (e) The organization has zero registered runners | fallback labels | `false` |
| (f) Preferred-labels input differs in letter case from the registered runner's labels but is otherwise identical | preferred labels | `true` |
| (g) The runner-listing API call fails or the token is rejected | action fails (non-zero exit); no outputs are set | — |
| (h) The specified organization does not exist (API returns not-found) | action fails (non-zero exit); no outputs are set | — |
