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

---

## Addendum 2026-07-06: default values for preferred-labels and fallback-labels

Real-world discovery during conformance testing: ExaDev's organization is
currently on the GitHub Free plan, which does not propagate organization-level
Actions variables to private repositories regardless of the variable's
configured visibility. Any consuming workflow that writes
`preferred-labels: ${{ vars.PREFERRED_LABELS }}` (rather than a literal
string) would therefore receive an empty value in that situation - not because
the caller did anything wrong, but because of this platform/plan constraint.

This amends the original spec's inputs as follows: `preferred-labels` and
`fallback-labels` are no longer strictly required. Each has a sensible,
ExaDev-specific default (`self-hosted,linux,ARM64,act-latest,m3` and
`ubuntu-latest` respectively) that applies both when the caller omits the
input entirely (via `action.yml`'s own `default:`) and when the caller
supplies it but the resolved value is empty (handled inside the script itself,
since `action.yml` defaults do not apply to an explicitly-passed empty
string). `org` and `token` are unaffected - there is no sensible universal
default for either, and both remain required, failing fast if missing or
empty exactly as originally specified.

This is a new, ExaDev-specific operational decision with no connection to any
prior art's expression or design - it did not go through the clean-room
examine/wall-review/blind-implement pipeline used for the original algorithm,
since there is nothing to wall off here.

---

## Addendum 2026-07-06: algorithm replaced with an infrastructure-health
## heartbeat, following ExaDev/github-runner's migration to ARC

`exadev/github-runner` (the consuming organization's self-hosted fleet) was
rebuilt on GitHub's Actions Runner Controller (ARC), which autoscales
runner pods on demand rather than keeping a fixed number of long-lived
runners registered at all times. With `minRunners: 0`, there is normally
**no pre-existing "online runner"** for the original algorithm (Sections
"Algorithm" and "API contract" above) to find via `GET
/orgs/{org}/actions/runners` — pods exist only for the duration of an
actual job, so that endpoint would report zero online runners essentially
all the time, whether or not the underlying infrastructure is actually
healthy. The original algorithm's central premise no longer holds for this
consumer, and needed to be replaced, not merely amended.

**Revised algorithm:**

1. Read the organization-level Actions variable `ARC_HEALTHY_UNTIL` (a unix
   timestamp) via `GET /orgs/{org}/actions/variables/ARC_HEALTHY_UNTIL`.
   This variable is maintained externally to this action, by a heartbeat
   script (`exadev/github-runner`'s `scripts/heartbeat.sh`, run on a
   schedule) that checks the underlying Kubernetes cluster and ARC
   controller are healthy and, if so, writes `now + a short window` into
   this variable. This action has no visibility into *how* that variable
   is produced — it only reads and interprets it.
2. If the variable does not exist (HTTP 404) — the heartbeat has never run
   for this org, e.g. a brand new org with no fleet set up yet — treat this
   as **not healthy** and use the fallback labels. This is the ordinary,
   expected fallback path, not an error.
3. If the read fails for any other reason (401/403/5xx — a genuine
   auth or API failure), **fail the action** (non-zero exit), unchanged
   from the original error-handling philosophy: masking a broken
   credential as ordinary fallback would hide it behind what looks like
   routine behaviour.
4. Otherwise, compare the variable's value to the current time. If it is
   still in the future, the infrastructure was confirmed healthy within
   the heartbeat's own freshness window — use the preferred labels. If it
   is in the past (the heartbeat stopped running: the host machine, the
   cluster, or the controller broke, or the network between them is down),
   use the fallback labels.

**Inputs/outputs unaffected in shape**: `org`, `preferred-labels`,
`fallback-labels`, `token`, `selected-runner`, `preferred-available` all
keep the same names and meaning at the interface level — only what
"preferred" resolves to changes (an ARC runner scale set name,
`exadev-runners`, rather than a literal self-hosted label set) and how
availability is determined internally. `preferred-labels`'s default value
changes accordingly, from `self-hosted,linux,ARM64,act-latest,m3` to
`exadev-runners`.

**Retired from the algorithm** (still true facts about the GitHub API, but
no longer relevant to this consumer's decision): pagination handling for
the runners-listing endpoint, per-runner label-superset matching,
case-insensitive label comparison, and the busy-runner-still-counts rule.
These would still apply to a consumer that genuinely wants to check for a
specific always-registered self-hosted runner (e.g. the previous
myoung34-based design, or a future non-ARC consumer) — they are simply not
what `exadev/github-runner` needs anymore, since it has no long-lived
registered runners to check for at all.

This is, again, a wholly new ExaDev-specific mechanism with no connection
to the original jimmygchen/mikehardy prior art — no clean-room process
applies to this change; it replaces ExaDev's own prior original design
(the online-runner check), not the clean-room-derived one, since the
thing being replaced was itself already outside the clean-room boundary
(see the previous addendum above).

---

## Addendum 2026-07-07: heartbeat signal moved to a secret gist; the App
## credential leaves CI entirely

The 2026-07-06 design read an **org-level** Actions variable
(`ARC_HEALTHY_UNTIL`) via an authenticated API call, which required every
consuming repo to hold a copy of the GitHub App credential (`token`/`org`
inputs) so it could mint an org-scoped installation token. On the GitHub Free
plan org secrets/variables don't reach private repos, so that credential had
to be duplicated per repo — exactly the cost this action was meant to remove.

A reusable-workflow centralisation was attempted and rejected: a called
workflow cannot read secrets from its own repo (GitHub Roadmap
[#636](https://github.com/github/roadmap/issues/636) is "Closed as not
planned"), so the mint could not be centralised that way.

**Revised mechanism:** the heartbeat now publishes the freshness timestamp to
a single **secret gist** (refreshed by `exadev/github-runner`'s heartbeat).
This action reads that gist and decides — no org-scope token, no per-repo
credential at all. A secret gist is *unlisted* (not in search/profile) but
readable by anyone with its ID, which is the property that makes this work:
the ID lives only in this (private) repo as the action's `gist-id` default and
in the Mac-local config, so the only readers are ExaDev members who already
know their own infra status — no meaningful external disclosure, yet the
signal is single-write / many-read with no per-repo auth.

**Revised algorithm:**

1. **Dependabot / fork-PR guard (now in-action):** if `github.actor ==
   'dependabot[bot]'` or `github.event.pull_request.head.repo.fork` is true,
   emit the fallback labels without reading the gist. Untrusted code must
   never run on the self-hosted fleet; centralising this guard means consumers
   can't get it wrong (previously each consumer implemented the `if:` itself).
2. Otherwise read the gist via `GET /gists/{gist_id}` (the GitHub API view is
   authoritative and fresh, unlike the CDN-cached raw URL which lags ~5 min).
   `GITHUB_TOKEN` (the automatic per-run token) is attached purely for
   rate-limit headroom; the gist is readable without it.
3. If the gist's file content is a unix timestamp still greater than `now` →
   preferred labels. Anything else (missing file, stale, non-numeric, or the
   read failed) → fallback labels. There is no longer a "fail loud on auth
   error" path: with no credential involved, every non-healthy outcome is the
   ordinary, graceful fallback.

**Inputs changed:** `token` and `org` are removed. Added `gist-id` (default =
the ExaDev heartbeat gist). `preferred-labels`/`fallback-labels` and both
outputs are unchanged. A consuming `determine-runner` job is now a bare
`uses:` of this action with no `with:` at all in the common case.

This is a wholly ExaDev-specific mechanism (no connection to the original
clean-room prior art), so no clean-room process applies; it is documented
here as a dated addendum, with the prior sections retained as history.
