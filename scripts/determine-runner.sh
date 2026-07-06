#!/usr/bin/env bash
# Determines whether an organization's self-hosted infrastructure is
# currently healthy, and emits selected-runner / preferred-available
# outputs accordingly. See action.yml for inputs, and docs/spec.md's
# 2026-07-06 addendum for why this checks infrastructure health via a
# heartbeat variable rather than querying for an online runner.
set -euo pipefail

# ExaDev's own default label sets, used when preferred-labels/fallback-labels
# arrive empty -- whether because the caller omitted them (action.yml's own
# defaults already cover that case) or because they were explicitly set to
# an org variable that didn't resolve. org and token have no sensible
# universal default and remain hard-required below.
readonly DEFAULT_PREFERRED_LABELS='exadev-runners'
readonly DEFAULT_FALLBACK_LABELS='ubuntu-latest'
readonly HEALTH_VARIABLE_NAME='ARC_HEALTHY_UNTIL'

validate_inputs() {
  : "${ORG:?org input is required}"
  : "${TOKEN:?token input is required}"

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

# Reads the org-level heartbeat variable and reports whether it is still
# fresh (its value, a unix timestamp, is later than now). A missing
# variable (404 - heartbeat has never run, e.g. brand new org, or the
# fleet was never set up) is treated as "not healthy" - the ordinary
# fallback path, not an error. Any other non-2xx response (401/403/5xx -
# a real auth or API failure) fails the action outright, exactly as an API
# failure did in the previous online-runner-check design: masking a broken
# credential as ordinary fallback would hide it behind what looks like
# routine, expected behaviour.
is_infrastructure_healthy() {
  local org="$1"
  local response http_status body value now

  response=$(curl -s -w '\n%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${org}/actions/variables/${HEALTH_VARIABLE_NAME}")
  http_status=$(tail -n1 <<< "$response")
  body=$(sed '$d' <<< "$response")

  if [[ "$http_status" == "404" ]]; then
    echo "false"
    return 0
  fi

  if [[ "$http_status" != 2* ]]; then
    echo "::error::Failed to read ${HEALTH_VARIABLE_NAME} for organization '${org}' (HTTP ${http_status})" >&2
    return 1
  fi

  value=$(jq -r '.value' <<< "$body")
  now=$(date +%s)

  if [[ "$value" =~ ^[0-9]+$ ]] && (( value > now )); then
    echo "true"
  else
    echo "false"
  fi
}

main() {
  validate_inputs

  local healthy
  if ! healthy="$(is_infrastructure_healthy "$ORG")"; then
    exit 1
  fi

  local selected_runner_json preferred_available
  if [[ "$healthy" == "true" ]]; then
    selected_runner_json="$(labels_to_json_array "$PREFERRED_LABELS")"
    preferred_available="true"
  else
    selected_runner_json="$(labels_to_json_array "$FALLBACK_LABELS")"
    preferred_available="false"
  fi

  echo "selected-runner=${selected_runner_json}" >> "$GITHUB_OUTPUT"
  echo "preferred-available=${preferred_available}" >> "$GITHUB_OUTPUT"
}

main "$@"
