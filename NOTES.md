# Clean-room process notes

This action was built as an independent implementation, not a fork, of the
same idea already solved by [jimmygchen/runner-fallback-action](https://github.com/jimmygchen/runner-fallback-action)
(archived) and its maintained fork [mikehardy/runner-fallback-action](https://github.com/mikehardy/runner-fallback-action)
(both MIT-licensed).

**Note on necessity:** the prior art's MIT licence already permits direct reuse
with attribution — this process was followed by explicit request, for an
independently-derived, ExaDev-controlled implementation, not because the
licence required it.

## Process (2026-07-06)

1. **Examine.** An isolated agent read both prior-art repos in full (action.yml,
   main implementation script, README, tests) and produced a code-free
   functional specification: purpose, explicit scope (organization-level only),
   inputs/outputs, algorithm described behaviourally, error handling, the real
   GitHub REST API contract, and test vectors. Committed as `docs/spec.md`.

2. **Wall review.** A second agent, also permitted to have seen the prior art
   (the wall sits before the implementer, not before the reviewer), scrutinised
   the spec against an identifier-scrubbing checklist: no copied
   variable/function names, no verbatim comments or README prose, no control
   flow presented as structure. Verdict: approved, with one finding — the
   spec's input/output names (`primary-runner`, `fallback-runner`,
   `github-token`, `use-runner`) matched the prior art's `action.yml` keys
   verbatim. Traced to the orchestrating session's own earlier research having
   read the original's `action.yml` before this process began, which then
   seeded the spec-contract template. Scrubbed by renaming to
   independently-derived alternatives (`preferred-labels`, `fallback-labels`,
   `token`, `selected-runner`, plus `preferred-available` — an output that
   doesn't exist in the original at all).

3. **Human sign-off.** The scrubbed spec was presented to the repository owner
   for explicit approval before crossing to implementation.

4. **Implement (blind).** A fresh agent, in a new isolated context, was given
   *only* the reviewed spec text plus ExaDev's own `github-runner` repo
   conventions (bash-only, one script per concern, a specific README shape) —
   never the prior art's name, URL, or any of its code. It wrote
   `action.yml`, `scripts/determine-runner.sh`, `README.md`, and
   `.github/workflows/conformance.yml` from the spec alone, and explicitly
   confirmed it did not search for or reference any external prior art.
   Committed separately as `feat: implement action per docs/spec.md`.

5. **Attribution.** This file and the README's "Credits / prior art" section
   were added afterwards, by the informed party, in a separate commit —
   crediting the functionally-equivalent prior art by name and licence, which
   is good practice regardless of clean-room status and distinct from having
   copied its code.

Git history preserves this separation: the spec, the blind implementation, and
this attribution note are three separate, non-squashed commits.
