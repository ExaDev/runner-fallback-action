# Runner Fallback Action

A composite GitHub Action that decides, at run time, whether a workflow should route a downstream job to ExaDev's self-hosted runner fleet or fall back to a GitHub-hosted runner. It checks a heartbeat variable (`ARC_HEALTHY_UNTIL`) that ExaDev's self-hosted fleet maintains against the current time, and emits a `runs-on`-ready label array plus an availability flag so a bootstrap job can hand off to whichever pool is actually usable.

**Note (2026-07-06):** the algorithm below describes the *current* design. This action originally checked the organization's live self-hosted runner inventory for a single online runner carrying every label in a preferred set (documented in `docs/spec.md`'s original body). That design assumed a fixed pool of long-lived, always-registered runners. ExaDev's fleet (`exadev/github-runner`) has since moved to GitHub's Actions Runner Controller (ARC), which autoscales runner pods on demand and scales to zero when idle - there is normally no online runner to find at all, healthy or not. See `docs/spec.md`'s 2026-07-06 addendum for the full replacement algorithm; this README describes only the current behaviour.

## Design decisions

**The heartbeat, not a runner inventory, is the source of truth.** `exadev/github-runner`'s `scripts/heartbeat.sh` runs on a schedule on the M3 Mac that hosts the fleet's k3s/ARC cluster, checks the cluster and controller are healthy, and if so pushes `ARC_HEALTHY_UNTIL = now + a short window` to an ExaDev org-level Actions variable. This action reads that single variable (`GET /orgs/{org}/actions/variables/ARC_HEALTHY_UNTIL`) and compares it to the current time - it has no visibility into, and makes no assumptions about, how the cluster itself is checked.

**A missing heartbeat variable (404) means "not healthy", not "error".** An org that has never had the fleet's heartbeat configured (or a brand-new org) simply has no variable to read yet - that's the ordinary, everyday fallback path, not a failure.

**Any other non-2xx response fails the action.** A broken token, a typo'd org name, or a network/API failure surfaces as a failed action run, because silently treating those as "not healthy" would mask a broken credential behind what looks like routine, expected fallback.

**A stale timestamp means "not healthy".** If the heartbeat variable's value is in the past, the fleet stopped reporting healthy within its own freshness window - the host machine, the cluster, the ARC controller, or the network between them could be down. Whatever the cause, the fallback path is used.

**Organization scope only.** ExaDev only ever calls this action at the organization level, so the implementation has exactly one code path: reading `/orgs/{org}/actions/variables/ARC_HEALTHY_UNTIL`. There are no inputs, branches, or helper functions for repository- or enterprise-scoped checks - adding them would be speculative generality for a caller that doesn't exist.

### Why the bootstrap job stays on `ubuntu-latest`

The job that calls this action has to run *somewhere* before it can know whether the preferred self-hosted pool is available - that's the entire question it's answering. Anchoring it on the self-hosted pool itself would be circular: if the preferred pool were actually down, that bootstrap job would just queue against a pool that will never pick it up, and could never determine "fall back to hosted" - the one scenario this action exists to handle. `ubuntu-latest` is used specifically because it's meant to be the one thing you can always count on being available, independent of whatever this action is checking.

This assumption inverts if GitHub's own hosted pool becomes the unreliable one for a given account (for example, during an account billing problem that blocks hosted runners entirely) - in that situation, anchoring the bootstrap job on self-hosted directly can be a reasonable *temporary* measure to keep testing/using this action, at the cost of losing the fallback safety net for as long as that anchoring choice is in place. See `.github/workflows/conformance.yml` for a live example of this tradeoff, made deliberately and documented inline - it is not the recommended pattern for real workflows once hosted runners are working normally again.

### Built-in defaults for preferred/fallback labels

`preferred-labels` and `fallback-labels` are optional. If omitted, they default to `exadev-runners` (the ARC runner scale set name) and `ubuntu-latest` respectively — and the same defaults apply if a caller explicitly passes them but the value resolves empty (e.g. `${{ vars.PREFERRED_LABELS }}` when that org variable isn't reachable). This matters because **ExaDev's org is currently on the GitHub Free plan, which does not propagate organization-level Actions variables to private repositories at all**, regardless of the variable's visibility setting — so referencing `vars.PREFERRED_LABELS`/`vars.FALLBACK_LABELS` from a private repo may silently resolve to nothing until the plan/billing situation changes. The action's own defaults mean it still does the right thing either way. `org` and `token` have no sensible universal default and remain required. (The `ARC_HEALTHY_UNTIL` heartbeat variable this action actually reads is written by `exadev/github-runner`'s heartbeat script directly via `gh variable set`, not via a workflow's `vars.` context, so it isn't subject to this Free-plan propagation limitation the same way `PREFERRED_LABELS`/`FALLBACK_LABELS` are.)

## Setup

1. The label values live in ExaDev org-level Actions variables, not hardcoded per workflow: `vars.PREFERRED_LABELS` (`exadev-runners`) and `vars.FALLBACK_LABELS` (`ubuntu-latest`). Changing which pool is preferred, or the fallback target, is a variable edit at `github.com/organizations/ExaDev/settings/variables/actions`, not a per-workflow edit. On the current Free plan these two variables won't actually reach private repos (see above) — omit the inputs entirely to rely on the action's built-in defaults until that's resolved, or set repo-level overrides for repos that need this now. The heartbeat variable itself (`ARC_HEALTHY_UNTIL`) needs no such setup on the caller's side - the action reads it directly.

2. Reference the action from a bootstrap job that runs on a GitHub-hosted runner (self-hosted availability isn't known yet, so this job can't itself run on the self-hosted pool). Authenticate using a token with read access to the organization's Actions variables (the same GitHub App used elsewhere in ExaDev's fleet tooling is sufficient), minting a short-lived installation token rather than storing a long-lived PAT:

   ```yaml
   jobs:
     determine-runner:
       runs-on: ubuntu-latest
       outputs:
         selected-runner: ${{ steps.fallback.outputs.selected-runner }}
         preferred-available: ${{ steps.fallback.outputs.preferred-available }}
       steps:
         - name: Mint installation token
           id: app-token
           uses: actions/create-github-app-token@v1
           with:
             app-id: ${{ vars.RUNNER_FALLBACK_APP_ID }}
             private-key: ${{ secrets.RUNNER_FALLBACK_APP_PRIVATE_KEY }}
             owner: ${{ github.repository_owner }}
         - uses: ExaDev/runner-fallback-action@main
           id: fallback
           with:
             org: ${{ github.repository_owner }}
             preferred-labels: ${{ vars.PREFERRED_LABELS }}
             fallback-labels: ${{ vars.FALLBACK_LABELS }}
             token: ${{ steps.app-token.outputs.token }}
   ```

3. Wire the output into the downstream job:

   ```yaml
     build:
       needs: determine-runner
       runs-on: ${{ fromJson(needs.determine-runner.outputs.selected-runner) }}
       steps:
         - run: echo "Running on: ${{ needs.determine-runner.outputs.selected-runner }}"
   ```

## Verification

Run `.github/workflows/conformance.yml` via `workflow_dispatch` against a real organization to exercise the action end to end:

```bash
gh workflow run conformance.yml \
  -f org=my-org \
  -f preferred-labels=exadev-runners \
  -f fallback-labels=ubuntu-latest
```

The workflow's `determine-runner` job calls the action and surfaces `selected-runner` and `preferred-available` as job outputs; the `confirm` job then runs on whichever pool was selected and echoes both values, giving a visible confirmation of the routing decision.

To force the fallback path deliberately, dispatch against an org whose `ARC_HEALTHY_UNTIL` variable is missing or stale - for example, an org where the fleet's heartbeat has never run, or by temporarily stopping the M3 Mac's heartbeat launchd job (`launchctl unload ~/Library/LaunchAgents/com.exadev.github-runner.heartbeat.plist` on the M3 Mac) and waiting past the heartbeat's freshness window - and confirm `preferred-available` reports `false` and `confirm` lands on the fallback labels instead.

**Note:** as of 2026-07-06, `conformance.yml`'s own `determine-runner` job is temporarily anchored on the ARC scale set directly rather than `ubuntu-latest`, because ExaDev's GitHub-hosted runners are currently blocked by an account billing issue - see "Why the bootstrap job stays on `ubuntu-latest`" above and the comment at the top of that workflow file. Revert it to `ubuntu-latest` once billing is resolved, so the conformance test itself exercises the same pattern real workflows should use.

## Credits / prior art

This action was built via a clean-room process (see `NOTES.md`) rather than as a fork, but it solves the same problem as, and is functionally compatible with:

- [jimmygchen/runner-fallback-action](https://github.com/jimmygchen/runner-fallback-action) (archived, MIT)
- [mikehardy/runner-fallback-action](https://github.com/mikehardy/runner-fallback-action) (maintained fork, MIT)

Both are worth knowing about if you need repository- or enterprise-scoped runner checking, or the `primaries-required`/`fallback-on-error` options this implementation deliberately omits as out of scope for ExaDev's use case.
