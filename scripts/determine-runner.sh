#!/usr/bin/env bash
# Decides whether to route a downstream job to ExaDev's self-hosted CI fleet
# or fall back to a GitHub-hosted label set, and emits selected-runner /
# preferred-available outputs. See action.yml for inputs, and docs/spec.md's
# 2026-07-07 addendum for why this reads a secret gist (not an org variable).
set -euo pipefail

readonly GIST_FILE='arc-healthy-until'
readonly DEFAULT_PREFERRED_LABELS='exadev-runners'
readonly DEFAULT_FALLBACK_LABELS='ubuntu-latest'

validate_inputs() {
  : "${GIST_ID:?gist-id input is required}"

  if [[ -z "${PREFERRED_LABELS:-}" ]]; then
    PREFERRED_LABELS="$DEFAULT_PREFERRED_LABELS"
  fi
  if [[ -z "${FALLBACK_LABELS:-}" ]]; then
    FALLBACK_LABELS="$DEFAULT_FALLBACK_LABELS"
  fi
}

# Converts a comma-separated label string into a JSON array of trimmed
# strings, preserving whatever letter case the caller supplied.
labels_to_json_array() {
  local raw="$1"
  printf '%s' "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | jq -R . | jq -sc .
}

emit() {
  # $1 = which label set to select ("preferred" | "fallback")
  local which="$1" selected_runner_json preferred_available
  if [[ "$which" == "preferred" ]]; then
    selected_runner_json="$(labels_to_json_array "$PREFERRED_LABELS")"
    preferred_available="true"
  else
    selected_runner_json="$(labels_to_json_array "$FALLBACK_LABELS")"
    preferred_available="false"
  fi
  echo "selected-runner=${selected_runner_json}" >> "$GITHUB_OUTPUT"
  echo "preferred-available=${preferred_available}" >> "$GITHUB_OUTPUT"
}

# Reads the heartbeat timestamp from the secret gist via the GitHub API.
# Deliberately UNAUTHENTICATED: a secret gist is "unlisted" - readable by
# anyone with its ID over plain HTTPS, but only via an anonymous request.
# Authenticating as anyone other than the gist's owner returns 404 (so the
# per-run GITHUB_TOKEN, which belongs to the github-actions bot, can't read
# it). The unauthenticated rate limit (60/hr/IP) is ample for one read per
# workflow run. The API view is authoritative and fresh, unlike the
# CDN-cached raw URL (~5 min lag).
read_healthy_until() {
  local response
  response="$(curl -fsS -H "Accept: application/vnd.github+json" \
    "https://api.github.com/gists/${GIST_ID}" 2>/dev/null || true)"
  [[ -n "$response" ]] || return 0
  jq -r --arg file "$GIST_FILE" '.files[$file].content // empty' <<<"$response" 2>/dev/null \
    | tr -d '[:space:]'
}

main() {
  validate_inputs

  # Dependabot runs and fork PRs must never execute untrusted code on the
  # self-hosted fleet. Force the fallback labels without even reading the gist.
  # (PR_IS_FORK is empty for non-PR events; only the literal string "true"
  # counts as a fork.)
  if [[ "${GITHUB_ACTOR:-}" == "dependabot[bot]" ]] || [[ "${PR_IS_FORK:-}" == "true" ]]; then
    emit fallback
    return 0
  fi

  local value now
  value="$(read_healthy_until)"
  now="$(date +%s)"

  # Fresh = numeric and still in the future. Anything else (missing, stale,
  # non-numeric, or the read failed) is the ordinary fallback path - there is
  # no credential left to fail loud on, and the safe direction is "don't route
  # to a fleet whose health we couldn't confirm".
  if [[ "$value" =~ ^[0-9]+$ ]] && (( value > now )); then
    emit preferred
  else
    emit fallback
  fi
}

main "$@"
