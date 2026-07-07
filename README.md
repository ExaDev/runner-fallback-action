# Runner Fallback Action

A composite GitHub Action that decides, at run time, whether a workflow should route a downstream job to ExaDev's self-hosted runner fleet or fall back to a GitHub-hosted runner. It reads a freshness timestamp that ExaDev's fleet publishes to a **secret gist** and compares it to the current time, then emits a `runs-on`-ready label array plus an availability flag so a bootstrap job can hand off to whichever pool is actually usable.

It needs **no secret and no organisation-scoped token** — the gist is unlisted but readable by anyone who has its ID (which lives only in this private repo and the fleet's Mac-local config). A consuming `determine-runner` job is just a bare `uses:` of this action with no `with:` in the common case.

**History:** this action originally checked the org's live self-hosted runner inventory (documented in `docs/spec.md`'s original body), then read an org-level `ARC_HEALTHY_UNTIL` variable via a minted App token (2026-07-06 addendum). The org-variable design forced every consumer to hold a copy of the App credential, which on the GitHub Free plan can't be shared from org level — so the signal moved to a single secret gist (2026-07-07 addendum), removing the credential from CI entirely. This README describes the current (gist) design.

## Design decisions

**A secret gist is the source of truth.** `exadev/github-runner`'s heartbeat (a docker-compose service on the M3 Mac) checks the k3s cluster and ARC controller are healthy and, if so, refreshes a single secret gist with `now + a short window`. This action reads that gist and compares it to the current time. It has no visibility into, and makes no assumptions about, how the cluster itself is checked.

**No credential is required.** The gist is read **unauthenticated** over the public GitHub API (`GET /gists/{id}`). A secret gist is "unlisted" — readable by anyone with its ID over plain HTTPS, but only via an anonymous request: authenticating as anyone other than the gist's owner returns 404, so the per-run `GITHUB_TOKEN` (the github-actions bot) can't read it. There is no App token to mint and no per-repo secret to provision — adding a new consumer is just `uses: ExaDev/runner-fallback-action@<sha>`. The unauthenticated rate limit (60/hr/IP) is ample for one read per workflow run.

**The Dependabot / fork-PR guard lives in the action.** If `github.actor == 'dependabot[bot]'` or the run is a fork PR, the action emits the fallback labels without reading the gist — untrusted code must never run on the self-hosted fleet. Centralising this guard means consumers can't get it wrong (previously each consumer implemented the `if:` itself).

**Anything other than a fresh timestamp means "not healthy" (gracefully).** A missing gist file, a stale value, a non-numeric value, or a failed read all select the fallback labels — never a hard failure. There's no credential left to fail loud on, and the safe direction is "don't route to a fleet whose health we couldn't confirm".

**The API view, not the raw URL.** The gist's raw `gist.githubusercontent.com` URL is CDN-cached for ~5 min and cachebusters don't bypass it; the API view is authoritative and fresh, so the action reads via the API.

### Why the bootstrap job stays on `ubuntu-latest`

The job that calls this action has to run *somewhere* before it can know whether the preferred self-hosted pool is available - that's the entire question it's answering. Anchoring it on the self-hosted pool itself would be circular: if the preferred pool were actually down, that bootstrap job would just queue against a pool that will never pick it up, and could never determine "fall back to hosted" - the one scenario this action exists to handle. `ubuntu-latest` is used specifically because it's meant to be the one thing you can always count on being available, independent of whatever this action is checking.

This assumption inverts if GitHub's own hosted pool becomes the unreliable one for a given account (for example, during an account billing problem that blocks hosted runners entirely) - in that situation, anchoring the bootstrap job on self-hosted directly can be a reasonable *temporary* measure to keep testing/using this action, at the cost of losing the fallback safety net for as long as that anchoring choice is in place. See `.github/workflows/conformance.yml` for a live example of this tradeoff, made deliberately and documented inline - it is not the recommended pattern for real workflows once hosted runners are working normally again.

### Built-in defaults for preferred/fallback labels

`preferred-labels` and `fallback-labels` are optional, defaulting to `exadev-runners` (the ARC runner scale set name) and `ubuntu-latest`. Omit them entirely in the common case. `gist-id` is also optional, defaulting to ExaDev's own heartbeat gist.

## Setup

1. Reference the action from a bootstrap job (ideally on `ubuntu-latest`; see above). No token, no secret, no `with:` needed:

   ```yaml
   jobs:
     determine-runner:
       runs-on: ubuntu-latest
       outputs:
         selected-runner: ${{ steps.fallback.outputs.selected-runner }}
         preferred-available: ${{ steps.fallback.outputs.preferred-available }}
       steps:
         - uses: ExaDev/runner-fallback-action@<pinned-sha>
           id: fallback
   ```

2. Wire the output into the downstream job:

   ```yaml
     build:
       needs: determine-runner
       runs-on: ${{ fromJson(needs.determine-runner.outputs.selected-runner) }}
       steps:
         - run: echo "Running on: ${{ needs.determine-runner.outputs.selected-runner }}"
   ```

That's the whole setup — the heartbeat (in `exadev/github-runner`) keeps the gist fresh; nothing per-repo is required.

## Verification

Run `.github/workflows/conformance.yml` via `workflow_dispatch`:

```bash
gh workflow run conformance.yml \
  -f gist-id=6d3da191f6fa5ed67282d528c3977e75 \
  -f preferred-labels=exadev-runners \
  -f fallback-labels=ubuntu-latest
```

The `determine-runner` job calls the action and surfaces `selected-runner` / `preferred-available`; the `confirm` job runs on whichever pool was selected and echoes both, giving a visible confirmation of the routing decision.

To force the fallback path, dispatch with a `gist-id` whose content is stale or missing (e.g. a freshly-created empty gist), or stop the M3 Mac's heartbeat so the timestamp goes stale, and confirm `preferred-available` reports `false` and `confirm` lands on the fallback labels.

**Note:** as of 2026-07-06, `conformance.yml`'s own `determine-runner` job is temporarily anchored on the ARC scale set directly rather than `ubuntu-latest`, because ExaDev's GitHub-hosted runners are currently blocked by an account billing issue - see "Why the bootstrap job stays on `ubuntu-latest`" above and the comment at the top of that workflow file. Revert it to `ubuntu-latest` once billing is resolved, so the conformance test itself exercises the same pattern real workflows should use.

## Credits / prior art

This action was built via a clean-room process (see `NOTES.md`) rather than as a fork, but it solves the same problem as, and is functionally compatible with:

- [jimmygchen/runner-fallback-action](https://github.com/jimmygchen/runner-fallback-action) (archived, MIT)
- [mikehardy/runner-fallback-action](https://github.com/mikehardy/runner-fallback-action) (maintained fork, MIT)

Both are worth knowing about if you need repository- or enterprise-scoped runner checking, or the `primaries-required`/`fallback-on-error` options this implementation deliberately omits as out of scope for ExaDev's use case.
