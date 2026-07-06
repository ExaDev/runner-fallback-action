# Runner Fallback Action

A composite GitHub Action that decides, at run time, whether a workflow should route a downstream job to ExaDev's self-hosted runner fleet or fall back to a GitHub-hosted runner. It checks the organization's live self-hosted runner inventory for a single online runner carrying every label in a preferred set, and emits a `runs-on`-ready label array plus an availability flag so a bootstrap job can hand off to whichever pool is actually usable.

## Design decisions

**Full pagination is mandatory, not optional.** `GET /orgs/{org}/actions/runners` pages results at up to 100 per request, and a real organization's fleet can span well beyond a single page. The runners that satisfy the preferred label set are not guaranteed to sit on page one - they could be anywhere in the fleet. An implementation that reads only the first page would silently report the preferred pool as unavailable even when it's sitting online three pages further in, which is a correctness bug dressed up as ordinary fallback behaviour. `gh api --paginate` is used specifically because it walks every page before the script proceeds.

**A match must be one runner, not the fleet's union.** The requirement is that a single runner carries every label in the preferred set simultaneously - not that the labels are collectively present somewhere across the online fleet. Two runners each holding half the required labels don't add up to an available preferred pool; nothing can actually be scheduled onto half a runner plus half a runner. The label check in `runner_has_preferred_labels` is therefore evaluated per runner object, comparing that runner's own `labels` array against the full preferred set with a set-subtraction test in `jq`.

**Label comparison is case-insensitive.** The preferred-labels input is typed by hand into workflow YAML; a runner's labels are set by whoever registered that runner. These two things are maintained independently, so `ARM64` and `arm64` should be treated as the same label rather than as a mismatch that forces an unnecessary fallback. Both the preferred set and each runner's labels are lowercased with `ascii_downcase` before comparison.

**Busy runners still count as available.** GitHub queues a job against a busy self-hosted runner rather than rejecting it outright, so a runner's `busy` flag has no bearing on whether the preferred pool is available for this decision - only `status == online` matters. The busy field is read from the API response but deliberately never inspected.

**Organization scope only.** ExaDev only ever calls this action at the organization level, so the implementation has exactly one code path: `GET /orgs/{org}/actions/runners`. There are no inputs, branches, or helper functions for repository- or enterprise-scoped runner queries - adding them would be speculative generality for a caller that doesn't exist.

**API failures fail the action; no match does not.** A broken token, a typo'd org name, or a network failure surfaces as a failed action run, because silently treating those as preferred unavailable would mask a broken credential behind what looks like routine, expected fallback. The everyday case - the preferred label set simply has no online match right now - is not an error and completes normally with `preferred-available: false`.

## Setup

1. The actual label values live in ExaDev org-level Actions variables, not hardcoded per workflow: `vars.PREFERRED_LABELS` (`self-hosted,linux,ARM64,act-latest,m3`) and `vars.FALLBACK_LABELS` (`ubuntu-latest`). Changing which runners are preferred, or the fallback target, is a variable edit at `github.com/organizations/ExaDev/settings/variables/actions`, not a per-workflow edit.

2. Reference the action from a bootstrap job that runs on a GitHub-hosted runner (self-hosted availability isn't known yet, so this job can't itself run on the self-hosted pool). Authenticate using the same GitHub App that registers ExaDev's runners (self-hosted-runners read permission), minting a short-lived installation token rather than storing a long-lived PAT:

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
  -f preferred-labels=self-hosted,linux,ARM64,act-latest,m3 \
  -f fallback-labels=ubuntu-latest
```

The workflow's `determine-runner` job calls the action and surfaces `selected-runner` and `preferred-available` as job outputs; the `confirm` job then runs on whichever pool was selected and echoes both values, giving a visible confirmation of the routing decision.

To force the fallback path deliberately, dispatch with a `preferred-labels` value that no online runner in the target org can satisfy (e.g. a label combination that doesn't exist in the fleet) and confirm `preferred-available` reports `false` and `confirm` lands on the fallback labels instead.

## Credits / prior art

This action was built via a clean-room process (see `NOTES.md`) rather than as a fork, but it solves the same problem as, and is functionally compatible with:

- [jimmygchen/runner-fallback-action](https://github.com/jimmygchen/runner-fallback-action) (archived, MIT)
- [mikehardy/runner-fallback-action](https://github.com/mikehardy/runner-fallback-action) (maintained fork, MIT)

Both are worth knowing about if you need repository- or enterprise-scoped runner checking, or the `primaries-required`/`fallback-on-error` options this implementation deliberately omits as out of scope for ExaDev's use case.
